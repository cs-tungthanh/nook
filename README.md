# Power Off Timer for macOS

A native macOS menu bar app to schedule system shutdowns.

## Features

- **Quick Actions**: Three preset buttons - 30min, 40min, or 1 hour
- **Custom Timer**: Input any number of minutes (defaults to 20)
- **Menu bar integration**: Lightweight app that lives in your menu bar
- **Real-time countdown**: Timer updates every second in both menu bar and popup
- **Clear visual feedback**:
  - Menu bar shows countdown time (e.g., "1h30m") when scheduled
  - Red "SHUTDOWN SCHEDULED" badge with pulsing indicator
  - Icon changes to filled state
- **Notifications**: Get notified when shutdown is scheduled or cancelled
- **Easy cancellation**: Cancel scheduled shutdowns with one click
- **Break reminders**: Get reminded to relax every N minutes (default 20)
  - Choose the break length: 10m, 30m, 1h or 2h
  - Two styles: a **Notification** with Start break / Snooze / Skip actions, or a **Full screen** blurred overlay with a countdown (Esc to skip; the screen is never locked)
  - Shows a ☕ countdown in the menu bar during a break
  - Pauses while your Mac is locked or asleep, and settings are remembered between launches

## Building the App

1. Make the build script executable:
   ```bash
   chmod +x build.sh
   ```

2. Build the app:
   ```bash
   ./build.sh
   ```

3. Run the app:
   ```bash
   open PowerOffTimer.app
   ```

## Installation

Copy the app to your Applications folder:
```bash
cp -r PowerOffTimer.app /Applications/
```

Then launch it from Applications or Spotlight.

## Usage

### Scheduling a Shutdown

**Quick Actions:**
1. Click the power icon in the menu bar
2. Click one of the preset buttons: **30min**, **40min**, or **1h**
3. Done! The shutdown is scheduled

**Custom Timer:**
1. Click the power icon in the menu bar
2. Enter your desired minutes in the text field (defaults to 20)
3. Click the play button
4. Done! The shutdown is scheduled

### Monitoring & Cancellation
- The menu bar icon will show the countdown time (e.g., "1h30m")
- A red "SHUTDOWN SCHEDULED" badge appears in the popup
- The live countdown updates every second
- To cancel, click the icon and press the red "Cancel Shutdown" button

## Permissions

The app requires:
- **Automation permission**: To execute the shutdown command
- **Notifications permission**: To show alerts about scheduled shutdowns

macOS will prompt you for these permissions on first use.

## Requirements

- macOS 13.0 (Ventura) or later
- Swift compiler (comes with Xcode or Command Line Tools)

## Technical Details

- Built with Swift and SwiftUI
- Uses NSStatusBar for menu bar integration
- Uses NSAppleScript for system shutdown
- Uses UserNotifications for alerts
