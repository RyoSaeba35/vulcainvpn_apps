#define WIN32_LEAN_AND_MEAN
#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shellapi.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {

  // Check if running as admin — if not, relaunch via scheduled task
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
    // Relaunch via scheduled task which has elevation — no UAC prompt
    ShellExecuteW(NULL, NULL, L"schtasks",
      L"/Run /TN \"VulcainVPN\\Launch\"", NULL, SW_HIDE);
    return 0;
  }

  // Always write the show flag on startup
  CreateDirectoryW(L"C:\\ProgramData\\VulcainVPN", NULL);
  HANDLE hFile = CreateFileW(
    L"C:\\ProgramData\\VulcainVPN\\show.flag",
    GENERIC_WRITE, 0, NULL,
    CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL
  );
  if (hFile != INVALID_HANDLE_VALUE) CloseHandle(hFile);

  // Check if another instance is already running
  HANDLE mutex = CreateMutex(NULL, TRUE, L"Global\\VulcainVPNMutex");
  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    // Another instance is running — flag already written, just exit
    return 0;
  }

  // First instance — delete the flag we just wrote (it was for us)
  // and start the app normally
  DeleteFileW(L"C:\\ProgramData\\VulcainVPN\\show.flag");

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
