#define WIN32_LEAN_AND_MEAN
#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shellapi.h>
#include <tlhelp32.h>

#include "flutter_window.h"
#include "utils.h"

bool IsAppAlreadyRunning() {
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return false;

  PROCESSENTRY32W pe = {};
  pe.dwSize = sizeof(pe);
  DWORD currentPid = GetCurrentProcessId();
  int count = 0;

  if (Process32FirstW(snapshot, &pe)) {
    do {
      if (_wcsicmp(pe.szExeFile, L"vulcain_vpn.exe") == 0) {
        if (pe.th32ProcessID != currentPid) count++;
      }
    } while (Process32NextW(snapshot, &pe));
  }
  CloseHandle(snapshot);
  return count > 0;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {

  // Check if running as admin
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
    // Delegate to show_app.vbs which handles everything silently
    ShellExecuteW(NULL, L"open",
      L"C:\\Program Files\\Vulcain VPN\\show_app.vbs",
      NULL, NULL, SW_HIDE);
    return 0;
  }

  // Running as admin — check if another elevated instance exists
  if (IsAppAlreadyRunning()) {
    // Write flag to show existing instance
    CreateDirectoryW(L"C:\\ProgramData\\VulcainVPN", NULL);
    HANDLE hFile = CreateFileW(
      L"C:\\ProgramData\\VulcainVPN\\show.flag",
      GENERIC_WRITE, 0, NULL,
      CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL
    );
    if (hFile != INVALID_HANDLE_VALUE) CloseHandle(hFile);
    return 0;
  }

  // No other instance — start normally
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
  Win32Window::Point origin(25, 25);
  Win32Window::Size size(400, 700);
  if (!window.Create(L"Vulcain VPN", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(false);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
