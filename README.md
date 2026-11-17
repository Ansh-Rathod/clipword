# Clipword

macOS clipboard manager. Flutter UI with a native SwiftData host. History stays local on this Mac.

## Features

- Menu bar clipboard history (⇧⌘C default hotkey)
- Search, pin, bookmark, delete
- Auto-paste with Accessibility permission
- Paste stack, image OCR, link previews
- Settings for general, storage, ignore rules, and advanced options

## Requirements

- macOS 15 (Sequoia) or later
- Flutter (stable) with macOS desktop enabled

## Build

```bash
cd flutter
flutter run -d macos
```

Or:

```bash
./run.sh
```

## Usage

1. Launch Clipword — it appears in the menu bar
2. Copy text/images/files; history is saved automatically
3. Press **⇧⌘C** or click the menu bar icon
4. Search, select with Enter to paste
5. Open Settings with **⌘,**

## Data storage

- History: `~/Library/Application Support/Clipword/Storage.sqlite`
- Preferences: `~/Library/Preferences/com.clipword.app.plist`

History stays on this Mac and is not deleted when you remove the app. Viewing a copied link can fetch its title and thumbnail (cached locally); this can be turned off in Settings → Storage.

## Permissions

- **Accessibility** — required for auto-paste (simulated ⌘V)

## License

MIT
