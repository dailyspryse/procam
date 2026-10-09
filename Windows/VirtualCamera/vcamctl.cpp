// procam_vcamctl.exe install | remove
//
// Creates or removes the system-wide Media Foundation virtual camera
// "ProCam iPhone" (Windows 11). Run elevated: AllUsers access needs admin.
// The camera persists across reboots; ProCam Studio only feeds frames.

#include <windows.h>
#include <mfapi.h>
#include <mfvirtualcamera.h>
#include <cstdio>
#include <cwchar>

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfsensorgroup.lib")
#pragma comment(lib, "ole32.lib")

// Must match CLSID_VCam in Source/dllmain.cpp.
static const wchar_t* SourceClsid = L"{7C1E4F2A-3B5D-4E8F-A6C2-9D0B1E2F3A4B}";
static const wchar_t* FriendlyName = L"ProCam iPhone";

int wmain(int argc, wchar_t** argv)
{
    if (argc < 2 || (wcscmp(argv[1], L"install") != 0 && wcscmp(argv[1], L"remove") != 0))
    {
        fwprintf(stderr, L"usage: procam_vcamctl install|remove\n");
        return 2;
    }
    bool install = wcscmp(argv[1], L"install") == 0;

    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    MFStartup(MF_VERSION);

    IMFVirtualCamera* cam = nullptr;
    HRESULT hr = MFCreateVirtualCamera(
        MFVirtualCameraType_SoftwareCameraSource,
        MFVirtualCameraLifetime_System,
        MFVirtualCameraAccess_AllUsers,
        FriendlyName, SourceClsid, nullptr, 0, &cam);
    wprintf(L"MFCreateVirtualCamera: 0x%08X\n", (unsigned)hr);

    if (SUCCEEDED(hr))
    {
        if (install)
        {
            hr = cam->Start(nullptr);
            wprintf(L"Start: 0x%08X\n", (unsigned)hr);
        }
        else
        {
            hr = cam->Remove();
            wprintf(L"Remove: 0x%08X\n", (unsigned)hr);
        }
        cam->Release();
    }

    MFShutdown();
    CoUninitialize();
    return SUCCEEDED(hr) ? 0 : (int)(hr & 0xFFFF) | 0x1000;
}
