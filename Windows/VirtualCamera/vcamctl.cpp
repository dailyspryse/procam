// procam_vcamctl.exe install | remove | run <parentPid>
//
// Media Foundation virtual camera "ProCam iPhone" (Windows 11).
//   install  system-wide, persists across reboots (needs admin)
//   remove   removes the system-wide camera
//   run      camera for the current user that lives exactly as long as the
//            given parent process (ProCam Studio). No admin needed — this is
//            the mode the reference sample uses and Studio relies on.

#include <windows.h>
#include <mfapi.h>
#include <mfvirtualcamera.h>
#include <cstdio>
#include <cwchar>
#include <cstdlib>

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfsensorgroup.lib")
#pragma comment(lib, "ole32.lib")

// Must match CLSID_VCam in Source/dllmain.cpp.
static const wchar_t* SourceClsid = L"{7C1E4F2A-3B5D-4E8F-A6C2-9D0B1E2F3A4B}";
static const wchar_t* FriendlyName = L"ProCam iPhone";

static HRESULT Create(bool system, IMFVirtualCamera** cam)
{
    HRESULT hr = MFCreateVirtualCamera(
        MFVirtualCameraType_SoftwareCameraSource,
        system ? MFVirtualCameraLifetime_System : MFVirtualCameraLifetime_Session,
        system ? MFVirtualCameraAccess_AllUsers : MFVirtualCameraAccess_CurrentUser,
        FriendlyName, SourceClsid, nullptr, 0, cam);
    wprintf(L"MFCreateVirtualCamera(%s): 0x%08X\n", system ? L"system" : L"session", (unsigned)hr);
    return hr;
}

int wmain(int argc, wchar_t** argv)
{
    if (argc < 2)
    {
        fwprintf(stderr, L"usage: procam_vcamctl install|remove|run <parentPid>\n");
        return 2;
    }
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    MFStartup(MF_VERSION);

    IMFVirtualCamera* cam = nullptr;
    HRESULT hr = E_INVALIDARG;
    if (wcscmp(argv[1], L"install") == 0)
    {
        if (SUCCEEDED(hr = Create(true, &cam)))
        {
            hr = cam->Start(nullptr);
            wprintf(L"Start: 0x%08X\n", (unsigned)hr);
        }
    }
    else if (wcscmp(argv[1], L"remove") == 0)
    {
        if (SUCCEEDED(hr = Create(true, &cam)))
        {
            hr = cam->Remove();
            wprintf(L"Remove: 0x%08X\n", (unsigned)hr);
        }
    }
    else if (wcscmp(argv[1], L"run") == 0 && argc >= 3)
    {
        DWORD pid = (DWORD)_wtoi(argv[2]);
        HANDLE parent = OpenProcess(SYNCHRONIZE, FALSE, pid);
        if (SUCCEEDED(hr = Create(false, &cam)))
        {
            hr = cam->Start(nullptr);
            wprintf(L"Start: 0x%08X\n", (unsigned)hr);
            fflush(stdout);
            if (SUCCEEDED(hr))
            {
                // Live as long as Studio does; the camera goes with us.
                if (parent) WaitForSingleObject(parent, INFINITE);
                else Sleep(INFINITE);
                // No Shutdown(): it would shut the media source down twice
                // and keep Remove from working (see the reference sample).
                cam->Remove();
            }
        }
        if (parent) CloseHandle(parent);
    }

    if (cam) cam->Release();
    MFShutdown();
    CoUninitialize();
    return SUCCEEDED(hr) ? 0 : (int)(hr & 0xFFFF) | 0x1000;
}
