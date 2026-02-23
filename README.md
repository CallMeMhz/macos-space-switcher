# SpaceSwitcher

A lightweight macOS menu bar app for managing and switching virtual desktops (Spaces).

![macOS](https://img.shields.io/badge/macOS-12.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.0-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## Features

- 📌 **Menu Bar Display** - All desktops shown directly in menu bar
- 🖱️ **One-Click Switch** - Left click to instantly switch desktop
- ✏️ **Custom Names** - Right click to rename any desktop
- 🎯 **Current Indicator** - Active desktop highlighted with `[name]`
- ⚡ **Lightweight** - Native Swift, minimal resource usage

## Screenshot

```
 1   Work  [Code]  Music   5   6 
                     ↑
              Current Desktop
```

## Requirements

- macOS 12.0 or later
- **Accessibility permission** required (for simulating keyboard shortcuts)
- **Keyboard shortcuts enabled**: System Settings → Keyboard → Keyboard Shortcuts → Mission Control → Enable "Switch to Desktop 1-10"

## Installation

### Download Release

Download the latest `SpaceSwitcher.app` from [Releases](../../releases) and move it to `/Applications`.

### Build from Source

```bash
git clone https://github.com/user/SpaceSwitcher.git
cd SpaceSwitcher

# Build
swiftc \
    -o SpaceSwitcherApp \
    -framework Cocoa \
    -framework SwiftUI \
    -parse-as-library \
    SpaceSwitcher/SpaceSwitcherApp.swift \
    SpaceSwitcher/SpaceManager.swift

# Create app bundle
mkdir -p SpaceSwitcher.app/Contents/MacOS
mkdir -p SpaceSwitcher.app/Contents/Resources
cp SpaceSwitcherApp SpaceSwitcher.app/Contents/MacOS/SpaceSwitcher
cp SpaceSwitcher/Info.plist SpaceSwitcher.app/Contents/

# Install
cp -r SpaceSwitcher.app /Applications/
```

## Setup

1. **Enable keyboard shortcuts**:
   - Open System Settings → Keyboard → Keyboard Shortcuts → Mission Control
   - Enable "Switch to Desktop 1", "Switch to Desktop 2", etc.

2. **Grant Accessibility permission**:
   - Open System Settings → Privacy & Security → Accessibility
   - Click `+` and add SpaceSwitcher.app
   - Make sure it's checked

3. **Launch the app**:
   ```bash
   open /Applications/SpaceSwitcher.app
   ```

## Usage

| Action | Result |
|--------|--------|
| Left click | Switch to that desktop |
| Right click | Rename the desktop |

## How It Works

SpaceSwitcher uses:
- `CGEvent` API to simulate `Ctrl + Number` keyboard shortcuts
- macOS private `SkyLight.framework` to read current Space information
- `com.apple.spaces` defaults to get desktop list

## Launch at Login

1. Open System Settings → General → Login Items
2. Click `+` under "Open at Login"
3. Select SpaceSwitcher.app

## Limitations

- Supports up to 10 desktops (limited by Ctrl+1~0 shortcuts)
- Only works on the main display
- Requires keyboard shortcuts to be enabled in System Settings

## License

MIT License

## Contributing

Issues and Pull Requests are welcome!
