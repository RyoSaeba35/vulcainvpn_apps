#define WIN32_LEAN_AND_MEAN
#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {

  // Warn if not running as admin
  BOOL isAdmin = FALSE;
  HANDLE token = NULL;
  if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
    TOKEN_ELEVATION elevation;
    DWORD size;
    if (GetTokenInformation(token, TokenElevation, &elevation,
                            sizeof(elevation), &size)) {
      isAdmin = elevation.TokenIsElevated;
    }
    CloseHandle(token);
  }

  if (!isAdmin) {
    MessageBoxW(NULL,
      L"Please launch Vulcain VPN from the desktop shortcut.",
      L"Vulcain VPN", MB_OK | MB_ICONINFORMATION);
    return 0;
  }

  // Single instance check via mutex
  HANDLE mutex = CreateMutex(NULL, TRUE, L"Global\\VulcainVPNMutex");
  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    // Write flag to C:\ProgramData\VulcainVPN\show.flag
    WCHAR flagPath[MAX_PATH];
    swprintf_s(flagPath, MAX_PATH, L"C:\\ProgramData\\VulcainVPN\\show.flag");

    // Ensure directory exists
    CreateDirectoryW(L"C:\\ProgramData\\VulcainVPN", NULL);

    HANDLE hFile = CreateFileW(flagPath, GENERIC_WRITE, 0, NULL,
                               CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hFile != INVALID_HANDLE_VALUE) CloseHandle(hFile);
    return 0;
  }

  // Ensure flag directory exists for the running instance too
  CreateDirectoryW(L"C:\\ProgramData\\VulcainVPN", NULL);

  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(400, 650);
  if (!window.Create(L"Vulcain VPN", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(false);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ReleaseMutex(mutex);
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
