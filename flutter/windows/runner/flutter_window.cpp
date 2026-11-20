#include "flutter_window.h"

#include <dwmapi.h>

#include <optional>

#include "clipword_host.h"
#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

/// Rounded corners + extended frame (for material coverage and the DWM drop
/// shadow on the frameless palette) + caption/taskbar icons. The backdrop
/// itself is owned by ClipwordHost::SetBackdrop — Dart can switch it at any
/// time via `setWindowBackdrop` (mica / acrylic / none).
void ApplyChromeEffects(HWND hwnd) {
  constexpr DWORD kCornerRound = 2;  // DWMWCP_ROUND
  DwmSetWindowAttribute(hwnd, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */,
                        &kCornerRound, sizeof(kCornerRound));

  const MARGINS margins = {-1, -1, -1, -1};
  DwmExtendFrameIntoClientArea(hwnd, &margins);

  const HMODULE module = GetModuleHandle(nullptr);
  SendMessage(hwnd, WM_SETICON, ICON_BIG,
              reinterpret_cast<LPARAM>(
                  LoadIcon(module, MAKEINTRESOURCE(IDI_APP_ICON))));
  SendMessage(hwnd, WM_SETICON, ICON_SMALL,
              reinterpret_cast<LPARAM>(
                  LoadIcon(module, MAKEINTRESOURCE(IDI_APP_ICON))));
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // `clipword_win` — low-level hook, WinRT OCR, exe-icon extraction.
  clipword_host_ = std::make_unique<ClipwordHost>(
      flutter_controller_->engine()->messenger(), GetHandle());

  // Clipword is a tray app: do NOT auto-show on first frame. Dart's
  // windowing layer controls visibility; the window starts hidden.
  ApplyChromeEffects(GetHandle());
  clipword_host_->SetBackdrop("mica");
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  clipword_host_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  // Tray callback / WM_ACTIVATE / WM_CLOSE notifications for Dart.
  if (clipword_host_ &&
      clipword_host_->HandleMessage(hwnd, message, wparam, lparam)) {
    return 0;
  }

  if (clipword_host_ && flutter_controller_ &&
      message == WM_SHOWWINDOW && wparam == TRUE) {
    // DWM drops the system-backdrop attribute across hide→show (the frame
    // falls back to raw glass blur) — re-apply it and force a real present.
    // Do NOT do this on WM_ACTIVATE: re-applying the acrylic accent policy
    // mid-activation turns the whole window black.
    clipword_host_->RefreshBackdrop();
    flutter_controller_->ForceRedraw();
  } else if (flutter_controller_ && message == WM_ACTIVATE &&
             LOWORD(wparam) != WA_INACTIVE) {
    // Stale surface across deactivate→activate reads as a black window —
    // kick a present only, leave the composition attributes alone.
    flutter_controller_->ForceRedraw();
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_CLOSE:
      // Hide instead of destroying — the tray icon owns the app lifetime.
      // (window_manager's preventClose normally handles this first; this is
      // the safety net for early closes before the plugin is ready.)
      ShowWindow(hwnd, SW_HIDE);
      return 0;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
