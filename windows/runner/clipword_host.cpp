#include "clipword_host.h"

#include <dwmapi.h>
#include <gdiplus.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <servprov.h>

#include "resource.h"

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Globalization.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/base.h>

#include <algorithm>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <optional>
#include <string>
#include <vector>

namespace {

ULONG_PTR g_gdiplus_token = 0;

// Undocumented user32 API used for Acrylic (the only public-ish way to get a
// blurred transparent material; DWMWA_SYSTEMBACKDROP_TYPE has no acrylic).
struct ACCENT_POLICY {
  DWORD accent_state;
  DWORD accent_flags;
  DWORD gradient_color;
  DWORD animation_id;
};
struct WINDOWCOMPOSITIONATTRIBDATA {
  DWORD attrib;
  PVOID data;
  SIZE_T cb_data;
};
constexpr DWORD kWcaAccentPolicy = 19;
constexpr DWORD kAccentDisabled = 0;
constexpr DWORD kAccentAcrylic = 4;
using SetWindowCompositionAttributeFn =
    BOOL(WINAPI*)(HWND, WINDOWCOMPOSITIONATTRIBDATA*);

void SetAccent(HWND hwnd, DWORD state, DWORD gradient = 0) {
  static const auto fn =
      reinterpret_cast<SetWindowCompositionAttributeFn>(GetProcAddress(
          GetModuleHandleW(L"user32.dll"), "SetWindowCompositionAttribute"));
  if (!fn) return;
  ACCENT_POLICY policy{state, 0, gradient, 0};
  WINDOWCOMPOSITIONATTRIBDATA data{kWcaAccentPolicy, &policy, sizeof(policy)};
  fn(hwnd, &data);
}

// Tray callback message id (WM_APP range).
constexpr UINT kTrayCallbackMessage = WM_APP + 100;
constexpr UINT kTrayIconId = 1;
// Posted by the CBT hook with wparam = #32768 menu HWND. Applying DWM attrs
// at HCBT_CREATEWND is too early — the menu manager overwrites them during
// initialization. The posted message is dispatched inside TrackPopupMenu's
// nested loop, after the menu finished setting itself up.
constexpr UINT kMenuCreatedMessage = WM_APP + 101;

// Undocumented uxtheme exports: process-wide dark theme for classic Win32
// popups (TrackPopupMenu #32768 windows). SetPreferredAppMode=135,
// FlushMenuThemes=136 — the standard recipe for dark context menus.
void ApplyDarkMenus() {
  const HMODULE ux = GetModuleHandleW(L"uxtheme.dll");
  if (!ux) return;
  using SetPreferredAppModeFn = int(WINAPI*)(int);
  using FlushMenuThemesFn = void(WINAPI*)();
  if (const auto set_mode = reinterpret_cast<SetPreferredAppModeFn>(
          GetProcAddress(ux, MAKEINTRESOURCEA(135)))) {
    set_mode(1 /* AllowDark — menus track the OS theme, like the app */);
  }
  if (const auto flush = reinterpret_cast<FlushMenuThemesFn>(
          GetProcAddress(ux, MAKEINTRESOURCEA(136)))) {
    flush();
  }
}

// Mirrors Flutter's platformBrightness: 0 = apps prefer dark.
bool OsAppsDark() {
  DWORD v = 1, size = sizeof(v);
  RegGetValueW(HKEY_CURRENT_USER,
               L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\"
               L"Personalize",
               L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &v, &size);
  return v == 0;
}

// Windows 11 = build 22000+. Mica/DWMSBT_* are Win11-only materials —
// Windows 10 supports only the classic acrylic accent.
bool IsWin11OrLater() {
  static const bool result = [] {
    // Matches RTL_OSVERSIONINFOW without dragging in winternl.h.
    struct OsVersionInfoW {
      DWORD size, major, minor, build, platform;
      wchar_t csd[128];
    };
    const HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    if (!ntdll) return true;
    const auto fn = reinterpret_cast<LONG(WINAPI*)(OsVersionInfoW*)>(
        GetProcAddress(ntdll, "RtlGetVersion"));
    if (!fn) return true;
    OsVersionInfoW v{sizeof(v)};
    return fn(&v) != 0 || v.build >= 22000;
  }();
  return result;
}

// Windows 10 silently ignores every Mica attribute — force acrylic there
// so the persisted pref from a Win11 machine still yields a real material.
std::string NormalizeBackdropMode(const std::string& mode) {
  return IsWin11OrLater() ? mode : "acrylic";
}

void EnsureGdiPlus() {
  if (g_gdiplus_token != 0) return;
  Gdiplus::GdiplusStartupInput input;
  Gdiplus::GdiplusStartup(&g_gdiplus_token, &input, nullptr);
}

// Bitmap encoder CLSID lookup (image/png).
int GetEncoderClsid(const WCHAR* format, CLSID* clsid) {
  UINT count = 0, size = 0;
  Gdiplus::GetImageEncodersSize(&count, &size);
  if (size == 0) return -1;
  std::vector<BYTE> buffer(size);
  auto* info = reinterpret_cast<Gdiplus::ImageCodecInfo*>(buffer.data());
  Gdiplus::GetImageEncoders(count, size, info);
  for (UINT i = 0; i < count; ++i) {
    if (wcscmp(info[i].MimeType, format) == 0) {
      *clsid = info[i].Clsid;
      return static_cast<int>(i);
    }
  }
  return -1;
}

// Exe path → PNG bytes of its large icon.
std::vector<uint8_t> IconToPng(const std::wstring& path, int size) {
  EnsureGdiPlus();
  SHFILEINFOW info = {};
  if (!SHGetFileInfoW(path.c_str(), FILE_ATTRIBUTE_NORMAL, &info, sizeof(info),
                      SHGFI_ICON | SHGFI_LARGEICON) ||
      info.hIcon == nullptr) {
    return {};
  }
  struct IconGuard {
    HICON icon;
    ~IconGuard() { DestroyIcon(icon); }
  } guard{info.hIcon};

  Gdiplus::Bitmap source(info.hIcon);
  if (size <= 0) size = static_cast<int>(source.GetWidth());
  Gdiplus::Bitmap target(size, size, PixelFormat32bppARGB);
  {
    Gdiplus::Graphics g(&target);
    g.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
    g.Clear(Gdiplus::Color(0, 0, 0, 0));
    g.DrawImage(&source, 0, 0, size, size);
  }

  CLSID png_clsid;
  if (GetEncoderClsid(L"image/png", &png_clsid) < 0) return {};
  IStream* stream = nullptr;
  if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream))) return {};
  std::vector<uint8_t> out;
  if (target.Save(stream, &png_clsid, nullptr) == Gdiplus::Ok) {
    STATSTG stat;
    if (SUCCEEDED(stream->Stat(&stat, STATFLAG_NONAME))) {
      out.resize(static_cast<size_t>(stat.cbSize.QuadPart));
      LARGE_INTEGER zero = {};
      stream->Seek(zero, STREAM_SEEK_SET, nullptr);
      ULONG read = 0;
      stream->Read(out.data(), static_cast<ULONG>(out.size()), &read);
      out.resize(read);
    }
  }
  stream->Release();
  return out;
}

// PNG bytes → OCR text via Windows.Media.Ocr (WinRT projection headers ship
// with the Windows SDK; no extra packages needed).
std::optional<std::wstring> OcrPng(const std::vector<uint8_t>& png) {
  try {
    winrt::init_apartment(winrt::apartment_type::single_threaded);

    namespace WSS = winrt::Windows::Storage::Streams;
    namespace WGI = winrt::Windows::Graphics::Imaging;
    namespace WMO = winrt::Windows::Media::Ocr;

    WSS::InMemoryRandomAccessStream stream;
    WSS::DataWriter writer(stream);
    writer.WriteBytes(winrt::array_view<const uint8_t>(png));
    writer.StoreAsync().get();
    stream.Seek(0);

    auto decoder = WGI::BitmapDecoder::CreateAsync(stream).get();
    auto bitmap = decoder.GetSoftwareBitmapAsync().get();

    auto engine = WMO::OcrEngine::TryCreateFromUserProfileLanguages();
    if (!engine) {
      engine = WMO::OcrEngine::TryCreateFromLanguage(
          winrt::Windows::Globalization::Language(L"en-US"));
    }
    if (!engine) return std::nullopt;

    // Downscale when the image exceeds the engine's limits.
    const auto max_dim = static_cast<int32_t>(engine.MaxImageDimension());
    if (bitmap.PixelWidth() > max_dim || bitmap.PixelHeight() > max_dim) {
      bitmap = decoder
                   .GetSoftwareBitmapAsync(
                       WGI::BitmapPixelFormat::Bgra8,
                       WGI::BitmapAlphaMode::Premultiplied)
                   .get();
    }

    auto result = engine.RecognizeAsync(bitmap).get();
    return std::wstring(result.Text().c_str());
  } catch (...) {
    return std::nullopt;
  }
}

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return {};
  int len = MultiByteToWideChar(CP_UTF8, 0, s.data(), -1, nullptr, 0);
  std::wstring out(len - 1, 0);
  MultiByteToWideChar(CP_UTF8, 0, s.data(), -1, out.data(), len);
  return out;
}

std::string WideToUtf8(const std::wstring& s) {
  if (s.empty()) return {};
  int len =
      WideCharToMultiByte(CP_UTF8, 0, s.data(), -1, nullptr, 0, nullptr, nullptr);
  std::string out(len - 1, 0);
  WideCharToMultiByte(CP_UTF8, 0, s.data(), -1, out.data(), len, nullptr,
                      nullptr);
  return out;
}

}  // namespace

ClipwordHost* ClipwordHost::instance_ = nullptr;

void ClipwordHost::RemoveTrayForExit() {
  if (instance_) instance_->RemoveTray();
}

static LONG WINAPI ClipwordCrashFilter(EXCEPTION_POINTERS*) {
  // The cleanup call itself rides SEH so a fault during it can't recurse.
  __try {
    ClipwordHost::RemoveTrayForExit();
  } __except (EXCEPTION_EXECUTE_HANDLER) {
  }
  return EXCEPTION_CONTINUE_SEARCH;  // WER/dump still handles the crash
}

static void ClipwordCrashSignal(int sig) {
  __try {
    ClipwordHost::RemoveTrayForExit();
  } __except (EXCEPTION_EXECUTE_HANDLER) {
  }
  std::signal(sig, SIG_DFL);
  raise(sig);  // resume the real crash
}

void ClipwordHost::InstallExitCleanup() {
  std::atexit(RemoveTrayForExit);
  SetUnhandledExceptionFilter(&ClipwordCrashFilter);
  std::signal(SIGABRT, &ClipwordCrashSignal);
  std::signal(SIGSEGV, &ClipwordCrashSignal);
  std::signal(SIGFPE, &ClipwordCrashSignal);
  std::signal(SIGILL, &ClipwordCrashSignal);
}

ClipwordHost::ClipwordHost(flutter::BinaryMessenger* messenger, HWND hwnd)
    : hwnd_(hwnd) {
  instance_ = this;
  InstallExitCleanup();
  const auto* codec = &flutter::StandardMethodCodec::GetInstance();
  channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "clipword_win", codec);
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });

  hook_ = SetWindowsHookExW(WH_KEYBOARD_LL, &ClipwordHost::KeyboardProc,
                            GetModuleHandle(nullptr), 0);
  if (!hook_) {
    fprintf(stderr, "clipword: LL hook install FAILED (err=%lu)\n",
            GetLastError());
  }

  // Dark popup menus process-wide, then a thread-local CBT hook that applies
  // the active backdrop material to each #32768 menu window as it is created.
  ApplyDarkMenus();
  menu_hook_ = SetWindowsHookExW(WH_CBT, &ClipwordHost::MenuHookProc, nullptr,
                               GetCurrentThreadId());

  // Out-of-context WinEvent hook — desktop-switch notification lands on this
  // thread's message queue.
  desktop_hook_ = SetWinEventHook(
      EVENT_SYSTEM_DESKTOPSWITCH, EVENT_SYSTEM_DESKTOPSWITCH, nullptr,
      &ClipwordHost::DesktopSwitchProc, 0, 0, WINEVENT_OUTOFCONTEXT);
  if (!desktop_hook_) {
    fprintf(stderr, "clipword: desktop-switch hook install FAILED (err=%lu)\n",
            GetLastError());
  }
}

ClipwordHost::~ClipwordHost() {
  RemoveTray();
  if (desktop_hook_) {
    UnhookWinEvent(desktop_hook_);
    desktop_hook_ = nullptr;
  }
  if (menu_hook_) {
    UnhookWindowsHookEx(menu_hook_);
    menu_hook_ = nullptr;
  }
  if (hook_) {
    UnhookWindowsHookEx(hook_);
    hook_ = nullptr;
  }
  if (instance_ == this) instance_ = nullptr;
}

LRESULT CALLBACK ClipwordHost::MenuHookProc(int code, WPARAM wparam,
                                            LPARAM lparam) {
  auto* self = instance_;
  if (self && code == HCBT_CREATEWND) {
    wchar_t cls[32] = {};
    const HWND menu = reinterpret_cast<HWND>(wparam);
    if (GetClassNameW(menu, cls, 32) && wcscmp(cls, L"#32768") == 0) {
      PostMessage(self->hwnd_, kMenuCreatedMessage,
                  reinterpret_cast<WPARAM>(menu), 0);
    }
  }
  return CallNextHookEx(self ? self->menu_hook_ : nullptr, code, wparam,
                        lparam);
}

void ClipwordHost::ApplyMenuMaterial(HWND menu) {
  const DWORD dark = OsAppsDark() ? 1 : 0;
  DwmSetWindowAttribute(menu, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, &dark,
                        sizeof(dark));
  const DWORD corner = 2;  // DWMWCP_ROUND
  DwmSetWindowAttribute(menu, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, &corner,
                        sizeof(corner));
  constexpr DWORD kSystemBackdropAttr = 38;
  if (backdrop_mode_ == "acrylic") {
    const DWORD off = 1;
    DwmSetWindowAttribute(menu, kSystemBackdropAttr, &off, sizeof(off));
    // Light tint on light menus, dark on dark — tracks the app surface.
    SetAccent(menu, kAccentAcrylic, dark ? 0xB32E2E2E : 0xB3F3F3F3);
  } else {
    SetAccent(menu, kAccentDisabled);
    const DWORD type = backdrop_mode_ == "mica" ? 2 : 1;
    DwmSetWindowAttribute(menu, kSystemBackdropAttr, &type, sizeof(type));
  }
}

LRESULT CALLBACK ClipwordHost::KeyboardProc(int code, WPARAM wparam,
                                            LPARAM lparam) {
  auto* self = instance_;
  if (self && code == HC_ACTION && wparam == WM_KEYDOWN) {
    auto* k = reinterpret_cast<KBDLLHOOKSTRUCT*>(lparam);
    const bool injected = (k->flags & LLKHF_INJECTED) != 0;
    const bool ctrl = (GetKeyState(VK_CONTROL) & 0x8000) != 0;

    // Global open-hotkey combo (default Ctrl+Alt+Shift+V). Injected keys
    // count here — the loop-prevention guard only matters for Ctrl+V pop.
    if (!self->open_shortcut_paused_ && k->vkCode == self->open_vk_) {
      const bool shift = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
      const bool alt = (GetKeyState(VK_MENU) & 0x8000) != 0;
      const bool win = ((GetKeyState(VK_LWIN) & 0x8000) != 0) ||
                       ((GetKeyState(VK_RWIN) & 0x8000) != 0);
      if (ctrl == self->open_ctrl_ && shift == self->open_shift_ &&
          alt == self->open_alt_ && win == self->open_win_) {
        self->channel_->InvokeMethod("openHotkey", nullptr);
        return 1;
      }
    }

    if (!injected && self->stack_armed_ && ctrl && k->vkCode == 'V') {
      // Swallow the keystroke; Dart pops the stack, writes the clipboard,
      // then re-injects a synthetic Ctrl+V (marked LLKHF_INJECTED).
      self->channel_->InvokeMethod("paletteKey", nullptr);
      return 1;
    }
  }
  return CallNextHookEx(self ? self->hook_ : nullptr, code, wparam, lparam);
}

bool ClipwordHost::HandleMessage(HWND hwnd, UINT message, WPARAM wparam,
                                 LPARAM lparam) {
  if (message == kMenuCreatedMessage) {
    if (IsWindow(reinterpret_cast<HWND>(wparam))) {
      ApplyMenuMaterial(reinterpret_cast<HWND>(wparam));
    }
    return true;
  }
  if (message == kTrayCallbackMessage) {
    switch (LOWORD(lparam)) {
      case WM_LBUTTONUP:
        channel_->InvokeMethod(
            "trayEvent", std::make_unique<flutter::EncodableValue>("click"));
        return true;
      case WM_RBUTTONUP:
        ShowTrayMenu();
        return true;
      default:
        return false;
    }
  }
  if (message == WM_ACTIVATE && LOWORD(wparam) == WA_INACTIVE) {
    channel_->InvokeMethod(
        "windowEvent",
        std::make_unique<flutter::EncodableValue>("deactivated"));
  }
  if (message == WM_CLOSE) {
    channel_->InvokeMethod(
        "windowEvent", std::make_unique<flutter::EncodableValue>("closed"));
  }
  return false;
}

void ClipwordHost::InstallTray(const std::wstring& icon_path,
                               const std::wstring& tooltip) {
  NOTIFYICONDATAW nid = {};
  nid.cbSize = sizeof(nid);
  nid.hWnd = hwnd_;
  nid.uID = kTrayIconId;
  nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  nid.uCallbackMessage = kTrayCallbackMessage;
  nid.hIcon =
      static_cast<HICON>(LoadImageW(nullptr, icon_path.c_str(), IMAGE_ICON, 0,
                                    0, LR_LOADFROMFILE | LR_DEFAULTSIZE));
  if (nid.hIcon == nullptr) {
    nid.hIcon = LoadIconW(GetModuleHandle(nullptr),
                          MAKEINTRESOURCEW(IDI_APP_ICON));
  }
  wcsncpy_s(nid.szTip, tooltip.c_str(), _TRUNCATE);
  if (tray_installed_) {
    Shell_NotifyIconW(NIM_MODIFY, &nid);
  } else {
    tray_installed_ = Shell_NotifyIconW(NIM_ADD, &nid) != FALSE;
    if (tray_installed_) {
      nid.uVersion = NOTIFYICON_VERSION_4;
      Shell_NotifyIconW(NIM_SETVERSION, &nid);
    }
  }
}

void ClipwordHost::SetBackdrop(const std::string& mode) {
  backdrop_mode_ = NormalizeBackdropMode(mode);
  ApplyBackdrop(hwnd_, backdrop_mode_);
}

// ---- virtual-desktop pinning ----
// No documented API pins a window to all desktops — these shell-internal
// interfaces are undocumented, but their IIDs and vtables have been
// identical from Windows 10 through 11 24H2 (cross-checked: MScholtes/
// VirtualDesktop per-version sources, Ciantic/VirtualDesktopAccessor).
// Only IVirtualDesktopManagerInternal shifts per build — unused here.
namespace {
constexpr GUID kImmersiveShellClsid = {
    0xc2f03a33, 0x21f5, 0x47fa,
    {0xb4, 0xbb, 0x15, 0x63, 0x62, 0xa2, 0xf2, 0x39}};
constexpr GUID kAppViewCollectionIid = {
    0x1841c6d7, 0x4f9d, 0x42c0,
    {0xaf, 0x41, 0x87, 0x47, 0x53, 0x8f, 0x10, 0xe5}};
constexpr GUID kPinnedAppsService = {
    0xb5a399e7, 0x1c87, 0x46b8,
    {0x88, 0xe9, 0xfc, 0x57, 0x47, 0xb1, 0x71, 0xbd}};
constexpr GUID kPinnedAppsIid = {
    0x4ce81583, 0x1e4c, 0x4632,
    {0xa6, 0x21, 0x07, 0xa5, 0x35, 0x43, 0x14, 0x8f}};

struct IAppViewCollection : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE GetViews(void**) = 0;
  virtual HRESULT STDMETHODCALLTYPE GetViewsByZOrder(void**) = 0;
  virtual HRESULT STDMETHODCALLTYPE GetViewsByAppUserModelId(PCWSTR,
                                                             void**) = 0;
  virtual HRESULT STDMETHODCALLTYPE GetViewForHwnd(HWND, IUnknown**) = 0;
};

struct IVirtualDesktopPinnedApps : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE IsAppIdPinned(PCWSTR, BOOL*) = 0;
  virtual HRESULT STDMETHODCALLTYPE PinAppID(PCWSTR) = 0;
  virtual HRESULT STDMETHODCALLTYPE UnpinAppID(PCWSTR) = 0;
  virtual HRESULT STDMETHODCALLTYPE IsViewPinned(IUnknown*, BOOL*) = 0;
  virtual HRESULT STDMETHODCALLTYPE PinView(IUnknown*) = 0;
  virtual HRESULT STDMETHODCALLTYPE UnpinView(IUnknown*) = 0;
};

}  // namespace

void ClipwordHost::PinOnAllDesktops(HWND hwnd) {
  if (!hwnd || !IsWindow(hwnd)) return;
  // The pin persists for the window's lifetime — once set, skip the COM
  // chain on every show/switch/timer retry.
  if (std::find(pinned_windows_.begin(), pinned_windows_.end(), hwnd) !=
      pinned_windows_.end()) {
    return;
  }
  const HRESULT init_hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  IServiceProvider* shell = nullptr;
  if (SUCCEEDED(CoCreateInstance(kImmersiveShellClsid, nullptr, CLSCTX_ALL,
                                 IID_IServiceProvider,
                                 reinterpret_cast<void**>(&shell))) &&
      shell) {
    IAppViewCollection* views = nullptr;
    shell->QueryService(kAppViewCollectionIid, kAppViewCollectionIid,
                        reinterpret_cast<void**>(&views));
    IVirtualDesktopPinnedApps* pinned = nullptr;
    shell->QueryService(kPinnedAppsService, kPinnedAppsIid,
                        reinterpret_cast<void**>(&pinned));
    IUnknown* view = nullptr;
    if (views) views->GetViewForHwnd(hwnd, &view);
    if (view && pinned) {
      BOOL is_pinned = FALSE;
      const bool known = SUCCEEDED(pinned->IsViewPinned(view, &is_pinned));
      if ((known && is_pinned) || SUCCEEDED(pinned->PinView(view))) {
        // Cache only on confirmed/successful state — a failed PinView
        // leaves it uncached so later calls retry.
        pinned_windows_.push_back(hwnd);
      }
    }
    if (view) view->Release();
    if (views) views->Release();
    if (pinned) pinned->Release();
    shell->Release();
  }
  if (SUCCEEDED(init_hr)) CoUninitialize();
}

void ClipwordHost::MoveToCurrentDesktop(HWND hwnd) {
  if (!hwnd || !IsWindow(hwnd)) return;
  const HRESULT init_hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  // MoveWindowToDesktop needs the *target* desktop's GUID, but the manager
  // only reports the desktop a window is already on — so a throwaway probe
  // (new windows always land on the active desktop) supplies it.
  IVirtualDesktopManager* vdm = nullptr;
  if (SUCCEEDED(CoCreateInstance(CLSID_VirtualDesktopManager, nullptr,
                               CLSCTX_ALL, IID_PPV_ARGS(&vdm))) &&
      vdm) {
    // The all-desktops pin is the primary mechanism; the per-desktop move
    // below is only a fallback for shells where it fails. Owner is skipped
    // — it never gets a shell view to pin.
    PinOnAllDesktops(hwnd);
    // Owned windows are pulled onto their owner's desktop — the invisible
    // Static owner travels with the palette or drags it right back.
    const HWND targets[] = {GetWindow(hwnd, GW_OWNER), hwnd};
    for (HWND target : targets) {
      if (!target || !IsWindow(target)) continue;
      BOOL on_current = TRUE;
      if (SUCCEEDED(vdm->IsWindowOnCurrentVirtualDesktop(target,
                                                         &on_current)) &&
          !on_current) {
        HWND probe = CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, L"Static", L"", WS_POPUP, 0,
            0, 0, 0, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
        GUID desktop{};
        if (probe && SUCCEEDED(vdm->GetWindowDesktopId(probe, &desktop))) {
          vdm->MoveWindowToDesktop(target, desktop);
        }
        if (probe) DestroyWindow(probe);
      }
    }
    vdm->Release();
  }
  if (SUCCEEDED(init_hr)) CoUninitialize();
}

void ClipwordHost::TrackWindow(HWND hwnd) {
  if (!hwnd || !IsWindow(hwnd)) return;
  PinOnAllDesktops(hwnd);
  if (std::find(tracked_windows_.begin(), tracked_windows_.end(), hwnd) ==
      tracked_windows_.end()) {
    tracked_windows_.push_back(hwnd);
  }
}

void CALLBACK ClipwordHost::DesktopSwitchProc(HWINEVENTHOOK, DWORD event,
                                              HWND, LONG, LONG, DWORD,
                                              DWORD) {
  if (event == EVENT_SYSTEM_DESKTOPSWITCH && instance_) {
    instance_->OnDesktopSwitch();
  }
}

void ClipwordHost::OnDesktopSwitch() {
  MoveToCurrentDesktop(hwnd_);
  for (HWND h : tracked_windows_) {
    if (IsWindow(h)) MoveToCurrentDesktop(h);
  }
}

void ClipwordHost::ApplyBackdrop(HWND hwnd, const std::string& mode_in) {
  if (!hwnd || !IsWindow(hwnd)) return;
  const std::string mode = NormalizeBackdropMode(mode_in);
  // System-backdrop attribute: DWMSBT_DISABLE=1, DWMSBT_MAINWINDOW=2.
  constexpr DWORD kSystemBackdropAttr = 38;
  constexpr DWORD kCaptionColorAttr = 35;  // DWMWA_CAPTION_COLOR (Win11)
  constexpr DWORD kCaptionTextAttr = 36;   // DWMWA_TEXT_COLOR
  constexpr DWORD kDarkModeAttr = 20;      // DWMWA_USE_IMMERSIVE_DARK_MODE
  constexpr COLORREF kColorDefault = 0xFFFFFFFF;  // DWMWA_COLOR_DEFAULT
  // Secondary engine windows don't pass through Win32Window::UpdateTheme /
  // ApplyChromeEffects — keep immersive-dark + corner rounding in sync here.
  const DWORD dark = OsAppsDark() ? 1 : 0;
  DwmSetWindowAttribute(hwnd, kDarkModeAttr, &dark, sizeof(dark));
  const DWORD corner = 2;  // DWMWCP_ROUND
  DwmSetWindowAttribute(hwnd, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */,
                        &corner, sizeof(corner));
  if (mode == "acrylic") {
    const DWORD off = 1;
    DwmSetWindowAttribute(hwnd, kSystemBackdropAttr, &off, sizeof(off));
    // ABGR — dark translucent tint, clearly blurrier than flat mica.
    SetAccent(hwnd, kAccentAcrylic, 0xB32E2E2E);
    // The accent policy only covers the CLIENT area on a focused window —
    // with the frame extended into the client (margins -1) DWM composites
    // black over everything. Collapse the extension and tint the caption to
    // the same dark tone so the titlebar visually follows the acrylic.
    const MARGINS none = {0, 0, 0, 0};
    DwmExtendFrameIntoClientArea(hwnd, &none);
    const COLORREF cap = 0x002E2E2E, txt = 0x00FFFFFF;
    DwmSetWindowAttribute(hwnd, kCaptionColorAttr, &cap, sizeof(cap));
    DwmSetWindowAttribute(hwnd, kCaptionTextAttr, &txt, sizeof(txt));
  } else {
    SetAccent(hwnd, kAccentDisabled);
    const COLORREF def = kColorDefault;
    DwmSetWindowAttribute(hwnd, kCaptionColorAttr, &def, sizeof(def));
    DwmSetWindowAttribute(hwnd, kCaptionTextAttr, &def, sizeof(def));
    // DWMSBT_MAINWINDOW (2) — the opaque flat mica material. NOT
    // DWMSBT_TRANSIENTWINDOW (3, "Mica Alt"): that variant samples the
    // wallpaper translucently (reads as acrylic) and is only stable for
    // short-lived flyouts, not a persistent window.
    const DWORD type = mode == "none" ? 1 : 2;
    DwmSetWindowAttribute(hwnd, kSystemBackdropAttr, &type, sizeof(type));
    const MARGINS all = {-1, -1, -1, -1};
    DwmExtendFrameIntoClientArea(hwnd, &all);
  }
  // Composition attributes don't repaint by themselves — without this the old
  // material stays on screen until some unrelated redraw, which reads as the
  // switch being applied one selection late (mica/acrylic appearing swapped).
  RedrawWindow(hwnd, nullptr, nullptr,
               RDW_INVALIDATE | RDW_ERASE | RDW_FRAME | RDW_ALLCHILDREN);
}

void ClipwordHost::RemoveTray() {
  if (!tray_installed_) return;
  NOTIFYICONDATAW nid = {};
  nid.cbSize = sizeof(nid);
  nid.hWnd = hwnd_;
  nid.uID = kTrayIconId;
  Shell_NotifyIconW(NIM_DELETE, &nid);
  tray_installed_ = false;
}

void ClipwordHost::ShowTrayMenu() {
  HMENU menu = CreatePopupMenu();
  if (!menu) return;
  AppendMenuW(menu, MF_STRING, 1, L"Open Clipword");
  AppendMenuW(menu, MF_STRING, 2, L"Settings");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, 3, L"Quit Clipword");

  POINT pt;
  GetCursorPos(&pt);
  // Required for TrackPopupMenu to dismiss on outside click.
  SetForegroundWindow(hwnd_);
  UINT cmd = TrackPopupMenu(
      menu, TPM_LEFTALIGN | TPM_BOTTOMALIGN | TPM_RETURNCMD | TPM_NONOTIFY,
      pt.x, pt.y, 0, hwnd_, nullptr);
  DestroyMenu(menu);
  if (cmd == 0) return;
  const char* id = cmd == 1 ? "show" : cmd == 2 ? "settings" : "quit";
  channel_->InvokeMethod(
      "trayMenu", std::make_unique<flutter::EncodableValue>(id));
}

void ClipwordHost::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto& name = call.method_name();

  if (name == "setPasteStackArmed") {
    const auto* args =
        std::get_if<flutter::EncodableMap>(call.arguments());
    if (args) {
      auto it = args->find(flutter::EncodableValue("armed"));
      if (it != args->end()) {
        if (const auto* v = std::get_if<bool>(&it->second)) {
          stack_armed_ = *v;
        }
      }
    }
    result->Success();
    return;
  }

  if (name == "pauseOpenShortcut") {
    const auto* args =
        std::get_if<flutter::EncodableMap>(call.arguments());
    if (args) {
      auto it = args->find(flutter::EncodableValue("paused"));
      if (it != args->end()) {
        if (const auto* v = std::get_if<bool>(&it->second)) {
          open_shortcut_paused_ = *v;
        }
      }
    }
    result->Success();
    return;
  }

  if (name == "setOpenShortcut") {
    const auto* args =
        std::get_if<flutter::EncodableMap>(call.arguments());
    auto bool_arg = [&](const char* key, bool fallback) {
      if (!args) return fallback;
      auto it = args->find(flutter::EncodableValue(key));
      if (it == args->end()) return fallback;
      const auto* v = std::get_if<bool>(&it->second);
      return v ? *v : fallback;
    };
    if (args) {
      auto vk = args->find(flutter::EncodableValue("vk"));
      if (vk != args->end()) {
        if (const auto* v = std::get_if<int>(&vk->second)) {
          open_vk_ = static_cast<UINT>(*v);
        }
      }
    }
    open_ctrl_ = bool_arg("ctrl", true);
    open_shift_ = bool_arg("shift", true);
    open_alt_ = bool_arg("alt", true);
    open_win_ = bool_arg("win", false);
    result->Success();
    return;
  }

  if (name == "installTray") {
    const auto* args =
        std::get_if<flutter::EncodableMap>(call.arguments());
    std::wstring icon_path, tooltip = L"Clipword";
    if (args) {
      auto p = args->find(flutter::EncodableValue("iconPath"));
      if (p != args->end()) {
        if (const auto* v = std::get_if<std::string>(&p->second)) {
          icon_path = Utf8ToWide(*v);
        }
      }
      auto t = args->find(flutter::EncodableValue("tooltip"));
      if (t != args->end()) {
        if (const auto* v = std::get_if<std::string>(&t->second)) {
          tooltip = Utf8ToWide(*v);
        }
      }
    }
    InstallTray(icon_path, tooltip);
    result->Success();
    return;
  }

  if (name == "removeTray") {
    RemoveTray();
    result->Success();
    return;
  }

  if (name == "setWindowBackdrop") {
    std::string mode = "mica";
    HWND target = hwnd_;
    if (const auto* args =
            std::get_if<flutter::EncodableMap>(call.arguments())) {
      auto m = args->find(flutter::EncodableValue("mode"));
      if (m != args->end()) {
        if (const auto* v = std::get_if<std::string>(&m->second)) mode = *v;
      }
      // Optional target HWND — secondary windows (settings) pass their own.
      auto h = args->find(flutter::EncodableValue("hwnd"));
      if (h != args->end()) {
        if (const auto* hw64 = std::get_if<int64_t>(&h->second)) {
          target = reinterpret_cast<HWND>(static_cast<intptr_t>(*hw64));
        } else if (const auto* hw32 = std::get_if<int32_t>(&h->second)) {
          target = reinterpret_cast<HWND>(static_cast<intptr_t>(*hw32));
        }
      }
    }
    backdrop_mode_ = NormalizeBackdropMode(mode);
    ApplyBackdrop(target, backdrop_mode_);
    result->Success();
    return;
  }

  if (name == "moveToCurrentDesktop") {
    HWND target = hwnd_;
    if (const auto* args =
            std::get_if<flutter::EncodableMap>(call.arguments())) {
      auto h = args->find(flutter::EncodableValue("hwnd"));
      if (h != args->end()) {
        if (const auto* hw64 = std::get_if<int64_t>(&h->second)) {
          target = reinterpret_cast<HWND>(static_cast<intptr_t>(*hw64));
        } else if (const auto* hw32 = std::get_if<int32_t>(&h->second)) {
          target = reinterpret_cast<HWND>(static_cast<intptr_t>(*hw32));
        }
      }
    }
    MoveToCurrentDesktop(target);
    result->Success();
    return;
  }

  if (name == "registerTrackedWindow") {
    if (const auto* args =
            std::get_if<flutter::EncodableMap>(call.arguments())) {
      auto h = args->find(flutter::EncodableValue("hwnd"));
      if (h != args->end()) {
        HWND target = nullptr;
        if (const auto* hw64 = std::get_if<int64_t>(&h->second)) {
          target = reinterpret_cast<HWND>(static_cast<intptr_t>(*hw64));
        } else if (const auto* hw32 = std::get_if<int32_t>(&h->second)) {
          target = reinterpret_cast<HWND>(static_cast<intptr_t>(*hw32));
        }
        if (target) {
          TrackWindow(target);
          MoveToCurrentDesktop(target);
        }
      }
    }
    result->Success();
    return;
  }

  if (name == "appIcon") {
    const auto* args =
        std::get_if<flutter::EncodableMap>(call.arguments());
    std::wstring path;
    int size = 32;
    if (args) {
      auto p = args->find(flutter::EncodableValue("path"));
      if (p != args->end()) {
        if (const auto* v = std::get_if<std::string>(&p->second)) {
          path = Utf8ToWide(*v);
        }
      }
      auto s = args->find(flutter::EncodableValue("size"));
      if (s != args->end()) {
        if (const auto* v = std::get_if<int>(&s->second)) size = *v;
      }
    }
    if (path.empty()) {
      result->Success();
      return;
    }
    auto png = IconToPng(path, size);
    if (png.empty()) {
      result->Success();
    } else {
      result->Success(flutter::EncodableValue(png));
    }
    return;
  }

  if (name == "ocr") {
    const auto* args =
        std::get_if<flutter::EncodableMap>(call.arguments());
    std::vector<uint8_t> png;
    if (args) {
      auto p = args->find(flutter::EncodableValue("png"));
      if (p != args->end()) {
        if (const auto* v = std::get_if<std::vector<uint8_t>>(&p->second)) {
          png = *v;
        }
      }
    }
    if (png.empty()) {
      result->Success();
      return;
    }
    auto text = OcrPng(png);
    if (text) {
      result->Success(flutter::EncodableValue(WideToUtf8(*text)));
    } else {
      result->Success();
    }
    return;
  }

  result->NotImplemented();
}
