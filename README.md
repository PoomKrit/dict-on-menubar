# Dict on Menubar

A minimal native macOS menubar app for instant Thai↔English translation. Click
the menubar icon, type a word in Thai or English, and its translation appears
immediately — powered entirely by the dictionary built into macOS. No network,
no API key, no Xcode.

## Features

- Lives in the menubar — no Dock icon, no window
- Click the icon to open a search popover (search field is auto-focused)
- Type Thai **or** English — bidirectional lookup
- Live results with a 300 ms debounce as you type
- Uses the built-in Oxford Thai-English dictionary (`com.apple.dictionary.th-en.oup`)
- Fully offline

## Requirements

- macOS 12 or later
- Xcode Command Line Tools (`xcode-select --install`)
- The **Thai - English** dictionary must be enabled in **Dictionary.app →
  Settings…** (checkbox next to "Thai - English"). If it is not enabled, no
  results will appear.

## Build & Run

```bash
chmod +x build.sh
./build.sh
```

This compiles `DictApp.swift`, assembles `DictApp.app` with an `Info.plist`,
ad-hoc signs it, and prints the path. Drag `DictApp.app` to `/Applications` or
double-click it from Finder.

To compile and run without a bundle:

```bash
swiftc DictApp.swift -framework AppKit -framework CoreServices -o DictApp
./DictApp
```

## Files

| File | Description |
|------|-------------|
| `DictApp.swift` | Full app source (DictionaryServices + AppKit) |
| `build.sh` | Builds `.app` bundle, writes `Info.plist`, ad-hoc signs |

## How It Works

- **DictionaryServices** (a private C API bridged via `@_silgen_name`) is used
  to enumerate active dictionaries, find the Thai-English one, and call
  `DCSCopyTextDefinition` to fetch definitions locally.
- **NSStatusItem** places the app in the menubar with an SF Symbol icon.
- **NSPopover** shows a floating panel on click — search field on top,
  scrollable results below; closes on click-outside.

## Known Limitations

- Results are the dictionary's raw text (headword, pronunciation, senses,
  phrases) shown as-is, not reformatted.
- Depends on Apple's private `DictionaryServices` symbols. These have been
  stable for many macOS releases but are not a public API.
- Only the Thai-English dictionary is queried; other enabled dictionaries are
  ignored by design.
