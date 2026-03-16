#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shellapi.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {

  // Single instance check
  HANDLE mutex = CreateMutex(NULL, TRUE, L"VulcainVPNMutex");
  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND hwnd = FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Vulcain VPN");
    if (hwnd) {
      ShowWindow(hwnd, SW_RESTORE);
      SetForegroundWindow(hwnd);
    }
    return 0;
  }

  // Auto-elevate if not running as admin
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
    wchar_t path[MAX_PATH];
    GetModuleFileNameW(NULL, path, MAX_PATH);
    ShellExecuteW(NULL, L"runas", path, command_line, NULL, show_command);
    ReleaseMutex(mutex);
    return 0;
  }

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
  window.SetQuitOnClose(false); // ← tray handles quitting now

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ReleaseMutex(mutex);
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
