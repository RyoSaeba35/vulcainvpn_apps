#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shellapi.h>
#pragma comment(lib, "ws2_32.lib")

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

  // Try to connect to existing instance on port 45678
  WSADATA wsaData;
  WSAStartup(MAKEWORD(2, 2), &wsaData);

  SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  sockaddr_in addr = {};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(45678);
  InetPtonW(AF_INET, L"127.0.0.1", &addr.sin_addr);

  if (connect(sock, (sockaddr*)&addr, sizeof(addr)) == 0) {
    send(sock, "show", 4, 0);
    closesocket(sock);
    WSACleanup();
    return 0;
  }
  closesocket(sock);
  WSACleanup();

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

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
