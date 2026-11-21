# Clipword

Clipboard manager for macOS and Windows. Flutter UI; macOS uses a native SwiftData host, Windows a Dart backend plus a thin C++ helper. History stays local on this machine.

## Features

- Menu bar / system-tray clipboard history (⇧⌘C on macOS, Ctrl+Alt+Shift+V on Windows)
- Search, pin, bookmark, delete
- Auto-paste (Accessibility permission on macOS; SendInput on Windows)
- Paste stack, image OCR, link previews
- Settings for general, storage, ignore rules, and advanced options

## Requirements

- macOS 15 (Sequoia) or later, **or** Windows 10/11 with Visual Studio Build Tools
- Flutter — pinned via FVM (`.fvmrc`); Windows uses a pinned **master** revision because the multi-window API (`WindowController`/`Window`) is still experimental and master-only
- Windows builds also need `flutter config --enable-windowing` once per install (`run.sh` does it automatically)

## Build

```bash
flutter run -d macos        # macOS
fvm flutter run -d windows  # Windows (FVM)
```

Or `./run.sh` (macOS) / `./run.sh` in Git Bash (Windows).

## Usage

1. Launch Clipword — it lives in the menu bar (macOS) / system tray (Windows)
2. Copy text/images/files; history is saved automatically
3. Press **⇧⌘C** (macOS) / **Ctrl+Alt+Shift+V** (Windows) or click the tray icon
4. Search, select with Enter to paste
5. Open Settings with **⌘,** (macOS) / the tray menu (Windows)

## Data storage

- macOS — History: `~/Library/Application Support/Clipword/Storage.sqlite`; Preferences: `~/Library/Preferences/com.clipword.app.plist`
- Windows — History: `%LOCALAPPDATA%\Clipword\Storage.sqlite`; Preferences: `%LOCALAPPDATA%\Clipword\prefs.json`

History stays on this machine and is not deleted when you remove the app. Viewing a copied link can fetch its title and thumbnail (cached locally); this can be turned off in Settings → Storage.

## Windows architecture

`lib/native/windows/` ports the macOS `ClipwordHost` to Dart: clipboard capture/monitoring (Win32 FFI), SQLite history store, classifier, search, paste stack, prefs, windowing, menus, tray. `windows/runner/clipword_host.{h,cpp}` owns only what needs C++: the `WH_KEYBOARD_LL` hook (global open-hotkey + paste-stack Ctrl+V interception), WinRT OCR, exe-icon extraction (GDI+), and the tray icon (Shell_NotifyIcon). Two windows: the palette is the frameless runner HWND (hidden from taskbar/Alt+Tab via an invisible owner), while settings lives in a dedicated engine window (`FLUTTER_HOST_WINDOW`) created lazily through Flutter's `WindowController`/`Window` multi-window API and mounted under `ViewAnchor` — so each gets its own chrome, taskbar presence, and backdrop styling.

On Windows 11 the HWND gets `DWMWA_WINDOW_CORNER_PREFERENCE` (round) + a backdrop in `flutter_window.cpp`/`clipword_host.cpp` — the Flutter surface is transparent where Dart paints nothing, so the material fills the whole window (frameless palette gets material + DWM shadow; framed settings gets a material titlebar). Settings → Window → Backdrop picks **Mica** (default, `DWMWA_SYSTEMBACKDROP_TYPE` + `DwmExtendFrameIntoClientArea(-1)`) or **Acrylic** (`SetWindowCompositionAttribute`, dark-tinted blur that covers the caption too — the frame extension is collapsed because `-1` + accent + focused composites black). The window is also an owned window (invisible `Static` owner) with `WS_EX_APPWINDOW` removed — taskbar/Alt+Tab skip owned windows while the full caption buttons stay. On Windows 10 the attributes are ignored — plain dark window.

Popup menus (`TrackPopupMenu` — tray menu, item/filter/choice menus) get matching treatment: `SetPreferredAppMode(AllowDark)` + `FlushMenuThemes` (uxtheme ordinals 135/136) gives classic Win32 popups the dark theme, and a thread `WH_CBT` hook catches `#32768` menu windows to apply the active material — Mica via `DWMWA_SYSTEMBACKDROP_TYPE`, Acrylic via the accent policy — plus `DWMWA_USE_IMMERSIVE_DARK_MODE` and rounded corners. The attrs are applied from a posted message inside the menu's nested loop because the menu manager overwrites anything set at `HCBT_CREATEWND`.

## Permissions

- **Accessibility** (macOS) — required for auto-paste (simulated ⌘V)
- Windows needs no special permission; the global hotkey uses a low-level keyboard hook

## License

MIT
