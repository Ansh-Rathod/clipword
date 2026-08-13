# Clipword

Native macOS clipboard manager with analytics. Built with SwiftUI (macOS 15+), SwiftData, and local-only storage.

## Features

- Menu bar clipboard history (⇧⌘C default hotkey)
- Search (exact, fuzzy, regex, mixed)
- Pin, delete, clear history
- Auto-paste with Accessibility permission
- Paste stack for sequential pasting
- Image OCR via Vision framework
- **Analytics dashboard**: word/line/char counts, top words, per-app usage, activity charts, paste stats
- Configurable time ranges (Today, 7d, 30d, 90d, All, Custom)
- Full Settings window with 7 panes (General, Appearance, Storage, Ignore, Pins, Advanced, Analytics)
- App Intents for Shortcuts integration

## Requirements

- macOS 15 (Sequoia) or later
- Xcode 16+

## Build

```bash
cd clipword
python3 generate_project.py
open Clipword.xcodeproj
```

Or from the command line:

```bash
xcodebuild -project Clipword.xcodeproj -scheme Clipword -configuration Debug build
```

## Usage

1. Launch Clipword — it appears in the menu bar
2. Copy text/images/files; history is saved automatically
3. Press **⇧⌘C** or click the menu bar icon → **Open Clipword**
4. Search, select with Enter, paste with **⌥Enter**
5. Open **Analytics** from the menu bar or Settings → Analytics tab
6. Configure preferences via **Clipword → Settings** (⌘,)

## Data storage

- History: `~/Library/Application Support/Clipword/Storage.sqlite`
- Preferences: `~/Library/Preferences/com.clipword.app.plist`

All data stays on your Mac. No network calls.

## Permissions

- **Accessibility** — required for auto-paste (simulated ⌘V)

## License

MIT
