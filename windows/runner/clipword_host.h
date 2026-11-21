#ifndef RUNNER_CLIPWORD_HOST_H_
#define RUNNER_CLIPWORD_HOST_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>
#include <string>
#include <vector>

// Native side of the `clipword_win` MethodChannel. Everything clipboard-UI
// lives in Dart; this file only owns the pieces that need Win32/COM/WinRT:
//   * WH_KEYBOARD_LL hook — global open-hotkey combo + paste-stack Ctrl+V pop
//     (swallows the key when the stack is armed so Dart can write + re-inject)
//   * System tray icon + menu (Shell_NotifyIcon + TrackPopupMenu)
//   * `appIcon` — SHGetFileInfo + GDI+ HICON→PNG
//   * `ocr`    — Windows.Media.Ocr via C++/WinRT (SDK projection headers)
//   * `setWindowBackdrop` — Mica / Acrylic / None on the runner HWND
class ClipwordHost {
 public:
  ClipwordHost(flutter::BinaryMessenger* messenger, HWND hwnd);
  ~ClipwordHost();

  // "mica" | "acrylic" | "none" — records the mode and applies it to the
  // runner HWND. See ApplyBackdrop for the per-window variant.
  void SetBackdrop(const std::string& mode);

  // Re-applies the current backdrop. DWM drops DWMSBT_SYSTEMBACKDROP_TYPE
  // when a window goes through hide→show (the extended frame falls back to
  // raw glass blur), so the runner calls this on show/activate.
  void RefreshBackdrop() { ApplyBackdrop(hwnd_, backdrop_mode_); }

  ClipwordHost(const ClipwordHost&) = delete;
  ClipwordHost& operator=(const ClipwordHost&) = delete;

  // Runner-window messages the host cares about (tray callback, WM_ACTIVATE,
  // WM_CLOSE). Returns true when the message was consumed.
  bool HandleMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  static LRESULT CALLBACK KeyboardProc(int code, WPARAM wparam, LPARAM lparam);
  static LRESULT CALLBACK MenuHookProc(int code, WPARAM wparam, LPARAM lparam);

  // EVENT_SYSTEM_DESKTOPSWITCH fires the moment the active virtual desktop
  // changes — the fallback that keeps Clipword present everywhere when the
  // all-desktops pin (PinOnAllDesktops, the primary mechanism) is missing
  // on a given shell. Equivalent of macOS' canJoinAllSpaces.
  static void CALLBACK DesktopSwitchProc(HWINEVENTHOOK hook, DWORD event,
                                         HWND hwnd, LONG idObject,
                                         LONG idChild, DWORD idEventThread,
                                         DWORD msEventTime);
  void OnDesktopSwitch();

  // Applies the current backdrop material + dark caption attrs to a #32768
  // popup-menu window so context menus / dropdowns follow the app's material.
  void ApplyMenuMaterial(HWND menu);

  // Applies a backdrop mode to any HWND — the runner HWND or the engine's
  // secondary (settings) windows, which Dart reaches via windowHandle.
  void ApplyBackdrop(HWND hwnd, const std::string& mode);

  // Moves an HWND onto the active virtual desktop when it isn't already.
  // Owned windows stay glued to the desktop they were created on —
  // ShowWindow elsewhere reveals them where the user can't see.
  void MoveToCurrentDesktop(HWND hwnd);

  // Pins an HWND's shell view to every virtual desktop — the same flag the
  // taskbar's "Show this window on all desktops" sets, via the
  // undocumented-but-stable shell pinning service. Instant presence; the
  // desktop-switch hook + move remain as fallback.
  void PinOnAllDesktops(HWND hwnd);

  // Registers an HWND (settings window) to follow virtual-desktop switches
  // alongside the runner window — see DesktopSwitchProc. Pins it too.
  void TrackWindow(HWND hwnd);

  void InstallTray(const std::wstring& icon_path, const std::wstring& tooltip);
  void RemoveTray();
  void ShowTrayMenu();

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND hwnd_ = nullptr;
  HHOOK hook_ = nullptr;
  HHOOK menu_hook_ = nullptr;
  HWINEVENTHOOK desktop_hook_ = nullptr;
  std::vector<HWND> tracked_windows_;
  std::vector<HWND> pinned_windows_;
  bool stack_armed_ = false;
  bool open_shortcut_paused_ = false;
  bool tray_installed_ = false;
  std::string backdrop_mode_ = "mica";

  // Global open-hotkey combo (default Ctrl+Alt+Shift+V).
  UINT open_vk_ = 'V';
  bool open_ctrl_ = true;
  bool open_shift_ = true;
  bool open_alt_ = true;
  bool open_win_ = false;

  static ClipwordHost* instance_;
};

#endif  // RUNNER_CLIPWORD_HOST_H_
