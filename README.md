# Clipword

Native macOS clipboard manager. Built with SwiftUI (macOS 15+), SwiftData, and local-only storage.

## Features

- Menu bar clipboard history (⇧⌘C default hotkey)
- Search (exact, fuzzy, regex, mixed)
- Pin, bookmark, delete, and clear history
- Auto-paste with Accessibility permission
- Paste stack for sequential pasting
- Image OCR via Vision framework
- Settings for general, storage, ignore rules, and advanced options

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
3. Press **⇧⌘C** or click the menu bar icon
4. Search, select with Enter to paste
5. Configure preferences via **Clipword → Settings** (⌘,)

## Data storage

- History: `~/Library/Application Support/Clipword/Storage.sqlite`
- Preferences: `~/Library/Preferences/com.clipword.app.plist`

History stays on this Mac and is not deleted when you remove the app. Viewing a copied link can fetch its title and thumbnail (cached locally); this can be turned off in Settings → Storage.

## Permissions

- **Accessibility** — required for auto-paste (simulated ⌘V)

## License

MIT
