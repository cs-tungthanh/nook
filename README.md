<p align="center"><img src="icon/preview.png" width="128" alt="Nook icon"></p>

# Nook

**Your little corner of utilities.**

Nook is a lightweight macOS app that brings everyday utilities together in one convenient place. From Pomodoro focus sessions to scheduling shutdowns and cleaning up your system, Nook helps you take care of small tasks without interrupting your workflow.

## ✨ Features

Nook lives in your menu bar. Click its icon and Nook drops down from the notch at the top center of the screen, like the Dynamic Island. Click the icon again, click anywhere else or press Esc to fold it back up.

The island has two pages. **Utilities** shows four tiles side by side: Pomodoro and Power Off on the left, Screen Recording and Bluetooth on the right. **System** shows your Mac's vitals. Switch between them with the button in the island's header, next to **Quit**.

<p align="center">
  <img src="screenshots/utilities.png" width="700" alt="The Utilities page: Pomodoro, Power Off, Screen Recording and Bluetooth tiles">
</p>

<p align="center">
  <img src="screenshots/system.png" width="700" alt="The System page: CPU, GPU, Memory, Battery, Network, Available disk space and Power tiles">
</p>

- **Power-off Timer** — Schedule your Mac to shut down after a set time.
  - Click or drag along the ruler to pick 5 minutes to 2 hours in 5-minute steps, then press Start.
  - A live countdown in the island, and a power icon in the menu bar while a shutdown is scheduled.
  - Cancel with one click. You get a notification when a shutdown is scheduled or cancelled.
- **Pomodoro** — Focus in sprints and take regular breaks away from your screen.
  - A colorful card in the island: press **Start focusing**, then watch a live countdown ring — tomato red while you focus, mint green on a break, grey while paused.
  - Focus for N minutes (20 by default), then break for 2m, 5m, 10m or 20m. **Break now** starts a break early; **Back to focus** ends one.
  - Two break styles: a **Notification** with Start break / Snooze / Skip actions, or a **Full screen** blurred overlay with a countdown (press Esc to get back to focus; the screen is never locked).
  - A ☕ icon in the menu bar during a break.
  - Pauses while your Mac is locked or asleep. Settings are remembered between launches.
- **Screen Recording** — Record your screens with audio (macOS 15 or later).
  - **Source**: one **Screen** (pick which when you have several), **All screens** side by side in one video, or an **Area** you drag out after pressing Record (Esc cancels).
  - Include **System** audio (what your Mac plays), your **Microphone**, or both. Your choices are remembered.
  - **Stop** pauses the recording. Then **Resume** to keep recording into the same video, **Save** to finish it, or **Discard** to delete it.
  - **Save** opens a dialog to name the `.mov` and pick a folder (Desktop by default), then shows it in Finder. Cancelling asks before deleting the recording. Quitting Nook with an unsaved recording asks where to save it first.
  - While recording, a red **Stop** button with the elapsed time appears in the menu bar; click it to stop, and the island opens so you can resume or save.
  - A record icon in the menu bar while recording (a pause icon while stopped) and a running timer in the island; Nook's own island is left out of the video.
  - Very wide videos (for example two Retina screens) are saved as HEVC and scaled down to what the encoder supports.
  - The first time, macOS asks you to allow Nook under **Screen & System Audio Recording** (and **Microphone** if you include it).
- **Bluetooth** — Your paired devices, one tap from connecting.
  - Each device shows whether it's connected and its battery level, including left, right and case for AirPods.
  - **Connect** or **Disconnect** with one click. The first four devices are shown; **Show all** lists the rest.
  - To forget a device, use **System Settings › Bluetooth**. macOS doesn't let other apps unpair devices.
  - The first time, macOS asks you to allow Nook under **Bluetooth**.
- **System** — Press **System** in the island's header to see your Mac's vitals at a glance; press **Utilities** to go back.
  - **CPU**, **GPU** and **Memory** usage, each with a meter that turns orange above 85%.
  - **Battery** level and whether it's charging, and **Network** download and upload speed.
  - **Available** disk space, and **Power**: how many watts your Mac draws, with the adapter's rating when plugged in.
  - Updates every 1.5 seconds, and only while the page is open.
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

### Install with Homebrew

```bash
brew install --cask cs-tungthanh/tap/nook
```

Update with `brew upgrade --cask nook`; remove with `brew uninstall --cask nook`. The cask needs an Apple silicon Mac.

### Requirements for building

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

On first use, macOS asks for these permissions:

- **Automation** — to shut down your Mac at the scheduled time.
- **Notifications** — for shutdown alerts and break reminders.
- **Bluetooth** — to list, connect and disconnect your devices.
- **Screen & System Audio Recording** and **Microphone** — only when you record your screen.

### Command-line tools

```bash
# Remove duplicate commands from ~/.zsh_history (a backup is saved as .zsh_history.bak)
go run ./clean-zsh [path/to/history]

# Preview which Edge bookmark URLs have moved, then save them with -apply
go run . [-apply] [-wait 3] [-bookmarks path] [-edge path] [-proxy url]
```

Close Edge completely before running the bookmark updater with `-apply`, because Edge can overwrite its bookmarks file when it quits.

The updater checks links in a fresh, signed-out Edge profile, so it doesn't use Edge's built-in VPN (Secure Network). If your network blocks a site, the check fails with `SKIP: page failed to load: ERR_CONNECTION_REFUSED`, even though the site opens in your normal Edge. Pass `-proxy` to send the check through a proxy or VPN, for example `-proxy socks5://127.0.0.1:1080`. Supported schemes are `http`, `https`, `socks4` and `socks5`, without a username or password.

### Releasing

Push a version tag:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

The [Release workflow](.github/workflows/release.yml) builds Nook with that version, attaches `Nook-1.0.0.zip` to a GitHub release, and updates `Casks/nook.rb` in [cs-tungthanh/homebrew-tap](https://github.com/cs-tungthanh/homebrew-tap) from the template in `packaging/homebrew/nook.rb`.

It uses these repository secrets:

| Secret | Required | What it is |
|---|---|---|
| `HOMEBREW_TAP_TOKEN` | Yes | A fine-grained token with **Contents: read and write** on `homebrew-tap` |
| `MACOS_CERT_P12` | No | Your signing certificate exported as `.p12`, base64-encoded |
| `MACOS_CERT_PASSWORD` | No | The `.p12` export password |

Without a certificate, releases are signed ad-hoc and macOS forgets Nook's Screen Recording and Microphone permissions after every upgrade. Nook isn't notarized, so the cask clears the quarantine flag after install so Gatekeeper lets it open.

### Project layout

| Path | What it is |
|---|---|
| `Nook.swift` | The menu bar app (SwiftUI + AppKit) |
| `Info.plist` | App bundle settings |
| `build.sh` | Compiles, bundles and signs `Nook.app` |
| `install.sh` | Builds and reinstalls Nook in `/Applications` (`--uninstall` removes it) |
| `packaging/homebrew/` | Template for the Homebrew cask |
| `.github/workflows/release.yml` | Builds a release and updates the Homebrew tap when a `v*` tag is pushed |
| `icon/` | App icon and the script that draws it (`swift icon/make-icon.swift`) |
| `screenshots/` | Images of the island used in this README |
| `clean-zsh/` | Zsh history cleaner |
| `main.go` | Edge bookmark updater |

## 🛣️ Roadmap

- [x] Build the core app interface
- [x] Implement the break timer
- [x] Add scheduled power-off functionality
- [ ] Bring the cleanup utilities into the app
- [x] Add a menu bar interface for quick access
- [x] Add screen recording and Bluetooth devices
- [x] Show system status (CPU, GPU, memory, battery, network, disk, power)
- [ ] Support configurable preferences
- [ ] Expand the collection of utilities over time

## 🤝 Contributing

Nook is a work in progress. Ideas, suggestions, and contributions are welcome.

## 📄 License

The license has not been decided yet.

---

Made for the little things that make your day easier.

**Nook** — Your little corner of utilities.
