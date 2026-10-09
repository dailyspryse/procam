#include "pch.h"
#include "Undocumented.h"
#include "Tools.h"
#include "EnumNames.h"
#include "MFTools.h"
#include "FrameGenerator.h"
#include <sddl.h>

// ─── ProCam shared memory ───────────────────────────────────────────────
// Layout must match ProCamStudio/VirtualCamera.cs (MfFrameWriter):
//   0 u32 magic 'PCAM' · 4 u32 version · 8 u32 width · 12 u32 height
//  16 i64 sequence (odd while the writer is copying) · 24 i64 GetTickCount64
//  64 BGRA pixels, top-down, width*height*4
// The media source runs inside the Frame Server service (session 0), so the
// section lives in the Global namespace. Only services may create global
// objects; Studio, running as the user, opens it once a camera app has made
// the Frame Server load this source.
static const wchar_t* ProCamSectionName = L"Global\\ProCamVirtualCamera";
static const UINT32 ProCamMagic = 0x5043414D;
static const size_t ProCamHeaderSize = 64;

struct ProCamHeader
{
	UINT32 magic;
	UINT32 version;
	UINT32 width;
	UINT32 height;
	volatile LONG64 sequence;
	volatile LONG64 tick;
};

bool FrameGenerator::ReadSharedFrame()
{
	size_t frameBytes = (size_t)_width * _height * 4;
	if (!_view)
	{
		auto now = GetTickCount64();
		if (now - _lastOpenAttempt < 1000)
			return false;
		_lastOpenAttempt = now;

		size_t size = ProCamHeaderSize + frameBytes;
		// System, services, admins and every signed-in user may read/write;
		// app containers (e.g. the Camera app) may read.
		PSECURITY_DESCRIPTOR sd = nullptr;
		ConvertStringSecurityDescriptorToSecurityDescriptorW(
			L"D:(A;;GA;;;SY)(A;;GA;;;LS)(A;;GA;;;NS)(A;;GA;;;BA)(A;;GA;;;AU)(A;;GR;;;AC)",
			SDDL_REVISION_1, &sd, nullptr);
		SECURITY_ATTRIBUTES sa{ sizeof(sa), sd, FALSE };
		_mapping = CreateFileMappingW(INVALID_HANDLE_VALUE, &sa, PAGE_READWRITE,
			(DWORD)((UINT64)size >> 32), (DWORD)size, ProCamSectionName);
		if (sd)
			LocalFree(sd);
		if (!_mapping)
			_mapping = OpenFileMappingW(FILE_MAP_READ, FALSE, ProCamSectionName);
		if (!_mapping)
		{
			WINTRACE(L"ProCam: section unavailable (%u)", GetLastError());
			return false;
		}
		_view = (BYTE*)MapViewOfFile(_mapping, FILE_MAP_READ, 0, 0, 0);
		if (!_view)
		{
			CloseHandle(_mapping);
			_mapping = nullptr;
			return false;
		}
		WINTRACE(L"ProCam: section mapped");
	}

	auto header = (const ProCamHeader*)_view;
	if (header->magic != ProCamMagic || header->width != _width || header->height != _height)
		return false;
	// Studio stopped sending (no phone, app closed): show the placeholder.
	if (GetTickCount64() - (ULONGLONG)header->tick > 1500)
		return false;

	if (_pixels.size() != frameBytes)
		_pixels.resize(frameBytes);
	for (int attempt = 0; attempt < 3; attempt++)
	{
		LONG64 before = header->sequence;
		if (before & 1)
		{
			Sleep(1);
			continue;
		}
		MemoryBarrier();
		CopyMemory(_pixels.data(), _view + ProCamHeaderSize, frameBytes);
		MemoryBarrier();
		if (header->sequence == before)
			return true;
	}
	return false;
}

HRESULT FrameGenerator::EnsureRenderTarget(UINT width, UINT height)
{
	if (!HasD3DManager())
	{
		// create a D2D1 render target from WIC bitmap
		wil::com_ptr_nothrow<ID2D1Factory> d2d1Factory;
		RETURN_IF_FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_MULTI_THREADED, IID_PPV_ARGS(&d2d1Factory)));

		wil::com_ptr_nothrow<IWICImagingFactory> wicFactory;
		RETURN_IF_FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_ALL, IID_PPV_ARGS(&wicFactory)));

		RETURN_IF_FAILED(wicFactory->CreateBitmap(width, height, GUID_WICPixelFormat32bppPBGRA, WICBitmapCacheOnDemand, &_bitmap));

		D2D1_RENDER_TARGET_PROPERTIES props{};
		props.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM;
		props.pixelFormat.alphaMode = D2D1_ALPHA_MODE_PREMULTIPLIED;
		RETURN_IF_FAILED(d2d1Factory->CreateWicBitmapRenderTarget(_bitmap.get(), props, &_renderTarget));

		RETURN_IF_FAILED(CreateRenderTargetResources(width, height));
	}

	_prevTime = MFGetSystemTime();
	_frame = 0;
	return S_OK;
}

const bool FrameGenerator::HasD3DManager() const
{
	return _texture != nullptr;
}

HRESULT FrameGenerator::SetD3DManager(IUnknown* manager, UINT width, UINT height)
{
	RETURN_HR_IF_NULL(E_POINTER, manager);
	RETURN_HR_IF(E_INVALIDARG, !width || !height);

	RETURN_IF_FAILED(manager->QueryInterface(&_dxgiManager));
	RETURN_IF_FAILED(_dxgiManager->OpenDeviceHandle(&_deviceHandle));

	wil::com_ptr_nothrow<ID3D11Device> device;
	RETURN_IF_FAILED(_dxgiManager->GetVideoService(_deviceHandle, IID_PPV_ARGS(&device)));

	// create a texture/surface to write
	CD3D11_TEXTURE2D_DESC desc
	(
		DXGI_FORMAT_B8G8R8A8_UNORM,
		width,
		height,
		1,
		1,
		D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET
	);
	RETURN_IF_FAILED(device->CreateTexture2D(&desc, nullptr, &_texture));
	wil::com_ptr_nothrow<IDXGISurface> surface;
	RETURN_IF_FAILED(_texture.copy_to(&surface));

	// create a D2D1 render target from 2D GPU surface
	wil::com_ptr_nothrow<ID2D1Factory> d2d1Factory;
	RETURN_IF_FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_MULTI_THREADED, IID_PPV_ARGS(&d2d1Factory)));

	auto props = D2D1::RenderTargetProperties
	(
		D2D1_RENDER_TARGET_TYPE_DEFAULT,
		D2D1::PixelFormat(DXGI_FORMAT_UNKNOWN, D2D1_ALPHA_MODE_PREMULTIPLIED)
	);
	RETURN_IF_FAILED(d2d1Factory->CreateDxgiSurfaceRenderTarget(surface.get(), props, &_renderTarget));

	RETURN_IF_FAILED(CreateRenderTargetResources(width, height));

	// create GPU RGB => NV12 converter
	RETURN_IF_FAILED(CoCreateInstance(CLSID_VideoProcessorMFT, nullptr, CLSCTX_ALL, IID_PPV_ARGS(&_converter)));

	wil::com_ptr_nothrow<IMFAttributes> atts;
	RETURN_IF_FAILED(_converter->GetAttributes(&atts));
	TraceMFAttributes(atts.get(), L"VideoProcessorMFT");

	MFT_OUTPUT_STREAM_INFO info{};
	RETURN_IF_FAILED(_converter->GetOutputStreamInfo(0, &info));
	WINTRACE(L"FrameGenerator::SetD3DManager CLSID_VideoProcessorMFT flags:0x%08X size:%u alignment:%u", info.dwFlags, info.cbSize, info.cbAlignment);

	wil::com_ptr_nothrow<IMFMediaType> inputType;
	RETURN_IF_FAILED(MFCreateMediaType(&inputType));
	inputType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
	inputType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
	MFSetAttributeSize(inputType.get(), MF_MT_FRAME_SIZE, width, height);
	RETURN_IF_FAILED(_converter->SetInputType(0, inputType.get(), 0));

	wil::com_ptr_nothrow<IMFMediaType> outputType;
	RETURN_IF_FAILED(MFCreateMediaType(&outputType));
	outputType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
	outputType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
	MFSetAttributeSize(outputType.get(), MF_MT_FRAME_SIZE, width, height);
	RETURN_IF_FAILED(_converter->SetOutputType(0, outputType.get(), 0));

	// make sure the video processor works on GPU
	RETURN_IF_FAILED(_converter->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, (ULONG_PTR)manager));
	return S_OK;
}

// common to CPU & GPU
HRESULT FrameGenerator::CreateRenderTargetResources(UINT width, UINT height)
{
	assert(_renderTarget);
	RETURN_IF_FAILED(_renderTarget->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1, 1), &_whiteBrush));

	RETURN_IF_FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), (IUnknown**)&_dwrite));
	RETURN_IF_FAILED(_dwrite->CreateTextFormat(L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, 40, L"", &_textFormat));
	RETURN_IF_FAILED(_textFormat->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER));
	RETURN_IF_FAILED(_textFormat->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER));
	RETURN_IF_FAILED(_renderTarget->CreateBitmap(D2D1::SizeU(width, height),
		D2D1::BitmapProperties(D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE)), &_frameBitmap));
	_width = width;
	_height = height;
	return S_OK;
}

HRESULT FrameGenerator::Generate(IMFSample* sample, REFGUID format, IMFSample** outSample)
{
	RETURN_HR_IF_NULL(E_POINTER, sample);
	RETURN_HR_IF_NULL(E_POINTER, outSample);
	*outSample = nullptr;

	// ProCam: the iPhone picture from shared memory, or a placeholder card.
	if (_renderTarget && _textFormat && _dwrite && _whiteBrush)
	{
		_renderTarget->BeginDraw();
		if (_frameBitmap && ReadSharedFrame())
		{
			_frameBitmap->CopyFromMemory(nullptr, _pixels.data(), _width * 4);
			_renderTarget->DrawBitmap(_frameBitmap.get());
		}
		else
		{
			_renderTarget->Clear(D2D1::ColorF(0.055f, 0.055f, 0.063f, 1));
			auto cx = _width / 2.0f, cy = _height / 2.0f - 60;
			wil::com_ptr_nothrow<ID2D1SolidColorBrush> ring, dot;
			_renderTarget->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1, 0.18f), &ring);
			_renderTarget->CreateSolidColorBrush(D2D1::ColorF(1, 0.27f, 0.23f, 0.9f), &dot);
			if (ring) _renderTarget->DrawEllipse(D2D1::Ellipse(D2D1::Point2F(cx, cy), 70, 70), ring.get(), 6);
			if (dot) _renderTarget->FillEllipse(D2D1::Ellipse(D2D1::Point2F(cx, cy), 14, 14), dot.get());
			const wchar_t text[] = L"ProCam\nWarte auf das iPhone \u2013 ProCam Studio \u00f6ffnen";
			wil::com_ptr_nothrow<IDWriteTextLayout> layout;
			RETURN_IF_FAILED(_dwrite->CreateTextLayout(text, (UINT32)wcslen(text), _textFormat.get(), (FLOAT)_width, 200, &layout));
			_renderTarget->DrawTextLayout(D2D1::Point2F(0, cy + 110), layout.get(), _whiteBrush.get());
		}
		_renderTarget->EndDraw();
	}

	// build a sample using either D3D/DXGI (GPU) or WIC (CPU)
	wil::com_ptr_nothrow<IMFMediaBuffer> mediaBuffer;
	if (HasD3DManager())
	{
		// remove all existing buffers
		RETURN_IF_FAILED(sample->RemoveAllBuffers());

		// create a buffer from this and add to sample
		RETURN_IF_FAILED(MFCreateDXGISurfaceBuffer(__uuidof(ID3D11Texture2D), _texture.get(), 0, 0, &mediaBuffer));
		RETURN_IF_FAILED(sample->AddBuffer(mediaBuffer.get()));

		// if we're on GPU & format is not RGB, convert using GPU
		if (format == MFVideoFormat_NV12)
		{
			assert(_converter);
			RETURN_IF_FAILED(_converter->ProcessInput(0, sample, 0));

			// let converter build the sample for us, note it works because we gave it the D3DManager
			MFT_OUTPUT_DATA_BUFFER buffer = {};
			DWORD status = 0;
			RETURN_IF_FAILED(_converter->ProcessOutput(0, 1, &buffer, &status));
			*outSample = buffer.pSample;
		}
		else
		{
			sample->AddRef();
			*outSample = sample;
		}

		_frame++;
		return S_OK;
	}

	RETURN_IF_FAILED(sample->GetBufferByIndex(0, &mediaBuffer));
	wil::com_ptr_nothrow<IMF2DBuffer2> buffer2D;
	BYTE* scanline;
	LONG pitch;
	BYTE* start;
	DWORD length;
	RETURN_IF_FAILED(mediaBuffer->QueryInterface(IID_PPV_ARGS(&buffer2D)));
	RETURN_IF_FAILED(buffer2D->Lock2DSize(MF2DBuffer_LockFlags_Write, &scanline, &pitch, &start, &length));

	wil::com_ptr_nothrow<IWICBitmapLock> lock;
	auto hr = _bitmap->Lock(nullptr, WICBitmapLockRead, &lock);
	// now we're using regular COM macros because we want to be sure to unlock (or we could use try/catch)
	if (SUCCEEDED(hr))
	{
		UINT w, h;
		hr = lock->GetSize(&w, &h);
		if (SUCCEEDED(hr))
		{
			UINT wicStride;
			hr = lock->GetStride(&wicStride);
			if (SUCCEEDED(hr))
			{
				UINT wicSize;
				WICInProcPointer wicPointer;
				hr = lock->GetDataPointer(&wicSize, &wicPointer);
				if (SUCCEEDED(hr))
				{
					WINTRACE(L"WIC stride:%u WIC size:%u MF pitch:%u MF length:%u frame:%u format:%s", wicStride, wicSize, pitch, length, _frame, GUID_ToStringW(format).c_str());
					if (format == MFVideoFormat_NV12)
					{
						// note we could use MF's converter too
						hr = RGB32ToNV12(wicPointer, wicSize, wicStride, w, h, scanline, length, pitch);
					}
					else
					{
						hr = (wicSize != length || wicStride != pitch) ? E_FAIL : S_OK;
						if (SUCCEEDED(hr))
						{
							if (assert_true(wicPointer)) // WIC annotation is currently wrong on GetDataPointer wicPointer arg
							{
								CopyMemory(scanline, wicPointer, length);
							}
						}
					}

					if (SUCCEEDED(hr))
					{
						_frame++;
						sample->AddRef();
						*outSample = sample;
					}
				}
			}
		}
		lock.reset();
	}

	buffer2D->Unlock2D();
	return hr;
}
