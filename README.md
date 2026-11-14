<p align="center"><img src="icon/preview.png" width="128" alt="Nook icon"></p>

# Nook

**Your little corner of utilities.**

Nook is a lightweight macOS app that brings everyday utilities together in one convenient place. From managing breaks to scheduling shutdowns and cleaning up your system, Nook helps you take care of small tasks without interrupting your workflow.

## ✨ Features

Nook lives in your menu bar. Click the grid icon to open it.

- **Power-off Timer** — Schedule your Mac to shut down after a set time.
  - Pick a preset (30m, 40m or 1h) or step to any number of minutes, then press Start.
  - A live countdown in the popup, and a power icon in the menu bar while a shutdown is scheduled.
  - Cancel with one click. You get a notification when a shutdown is scheduled or cancelled.
- **Break Timer** — Remind yourself to take regular breaks and step away from your screen.
  - A reminder every N minutes (20 by default), with breaks of 2m, 5m, 10m or 20m.
  - Two styles: a **Notification** with Start break / Snooze / Skip actions, or a **Full screen** blurred overlay with a countdown (press Esc to skip; the screen is never locked).
  - A ☕ countdown in the menu bar during a break.
  - Pauses while your Mac is locked or asleep. Settings are remembered between launches.
- **Screen Recording** — Record your screens with audio (macOS 15 or later).
  - **Source**: one **Screen** (pick which when you have several), **All screens** side by side in one video, or an **Area** you drag out after pressing Record (Esc cancels).
  - Include **System** audio (what your Mac plays), your **Microphone**, or both. Your choices are remembered.
  - **Stop** pauses the recording. Then **Resume** to keep recording into the same video, **Save** to finish it, or **Discard** to delete it.
  - **Save** opens a dialog to name the `.mov` and pick a folder (Desktop by default), then shows it in Finder. Cancelling asks before deleting the recording. Quitting Nook with an unsaved recording asks where to save it first.
  - A record icon in the menu bar while recording (a pause icon while stopped) and a running timer in the popup; Nook's own popup is left out of the video.
  - Very wide videos (for example two Retina screens) are saved as HEVC and scaled down to what the encoder supports.
  - The first time, macOS asks you to allow Nook under **Screen & System Audio Recording** (and **Microphone** if you include it).
- **Cleanup** — Command-line tools that keep your system tidy (not in the menu bar app yet):
  - `clean-zsh` removes duplicate commands from `~/.zsh_history`, keeping the latest of each.
  - The bookmark updater follows redirects in your Microsoft Edge bookmarks and rewrites links that have moved.
- **More Utilities** — A growing collection of handy tools for everyday tasks.

> Features are planned to evolve as Nook grows.

## 🎯 Philosophy

Nook is built around a few simple principles:

- **Simple** — Do one thing well, without unnecessary complexity.
- **Lightweight** — Stay out of your way and use resources responsibly.
- **Convenient** — Keep useful tools within easy reach.
- **Native** — Feel at home on macOS, with an interface that is clean and familiar.
- **Extensible** — Make it easy to add new utilities as needs evolve.

## 🖥️ Platform

- macOS

## 🚀 Getting Started

### Requirements

- macOS 13 (Ventura) or later
- Swift compiler (comes with Xcode or the Command Line Tools)
- Go, for the command-line tools

### Build and run the app

```bash
./build.sh
open Nook.app
```

To install it, or to update an installed copy, run:

```bash
./install.sh
```

It builds Nook, quits any running copy (an unsaved recording still gets its save prompt), replaces `/Applications/Nook.app` and launches it. `./install.sh --uninstall` quits and removes Nook.

On first use, macOS asks for two permissions:

- **Automation** — to shut down your Mac at the scheduled time.
- **Notifications** — for shutdown alerts and break reminders.

### Command-line tools

```bash
# Remove duplicate commands from ~/.zsh_history (a backup is saved as .zsh_history.bak)
go run ./clean-zsh [path/to/history]

# Preview which Edge bookmark URLs have moved, then save them with -apply
go run . [-apply] [-wait 3] [-bookmarks path] [-edge path]
```

Close Edge completely before running the bookmark updater with `-apply`, because Edge can overwrite its bookmarks file when it quits.

### Project layout

| Path | What it is |
|---|---|
| `Nook.swift` | The menu bar app (SwiftUI + AppKit) |
| `Info.plist` | App bundle settings |
| `build.sh` | Compiles, bundles and signs `Nook.app` |
| `install.sh` | Builds and reinstalls Nook in `/Applications` (`--uninstall` removes it) |
| `icon/` | App icon and the script that draws it (`swift icon/make-icon.swift`) |
| `clean-zsh/` | Zsh history cleaner |
| `main.go` | Edge bookmark updater |

## 🛣️ Roadmap

- [x] Build the core app interface
- [x] Implement the break timer
- [x] Add scheduled power-off functionality
- [ ] Bring the cleanup utilities into the app
- [x] Add a menu bar interface for quick access
- [ ] Support configurable preferences
- [ ] Expand the collection of utilities over time

## 🤝 Contributing

Nook is a work in progress. Ideas, suggestions, and contributions are welcome.

## 📄 License

The license has not been decided yet.

---

Made for the little things that make your day easier.

**Nook** — Your little corner of utilities.
