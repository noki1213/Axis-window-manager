# Axis

A keyboard-driven tiling window manager for macOS.

https://note.com/elegant_hue/n/nc77a5d09e9a1

## Features

- **Tiling Layout**: Automatically arranges windows in a tiling layout.
- **Keyboard Navigation**: Move focus between windows using vim-style keys (J/K/L/I).
- **Window Movement**: Reorganize windows with keyboard shortcuts.
- **Zen Mode**: Focus on a single window by centering it and hiding others (distraction-free).
- **Gap Selection Mode**: Resize windows by selecting and moving gaps between them.
- **Window Selection Mode**: Select and merge multiple windows into columns.
- **Window Switcher**: Quickly switch between windows across all workspaces.
- **Visual Feedback**: Border highlights around the focused window.
- **Smart Workspaces**: Efficiently navigate and move windows between workspaces. Empty workspaces are automatically cleaned up.

## Keyboard Shortcuts

All shortcuts use `Ctrl + Option` as the base modifier.

### Basic Navigation (Normal Mode)
- `Ctrl + Option + J`: Move focus left
- `Ctrl + Option + L`: Move focus right
- `Ctrl + Option + I`: Move focus up
- `Ctrl + Option + K`: Move focus down

### Window Movement
- `Ctrl + Option + Shift + J`: Move window left
- `Ctrl + Option + Shift + L`: Move window right
- `Ctrl + Option + Shift + I`: Move window up
- `Ctrl + Option + Shift + K`: Move window down

### Zen Mode
- `Ctrl + Option + Z`: Toggle Zen Mode (Focus Mode)

### Window Switcher
- `Ctrl + Option + P`: Open Window Switcher
  - `J/K/L/I`: Navigate selection
  - `Return`: Switch to selected window

### Window Selection Mode
- `Ctrl + Option + W`: Enter window selection mode
  - `J/K/L/I`: Navigate focus
  - `Return`: Select/Deselect window
  - `V`: Merge selected windows vertically
  - `Shift + V`: Split selected windows
  - `Escape`: Exit mode

### Gap Selection & Resizing
**Quick Resize (Direct Entry)**
- `Ctrl + Option + S`: Select Left Gap
- `Ctrl + Option + F`: Select Right Gap
- `Ctrl + Option + E`: Select Top Gap
- `Ctrl + Option + D`: Select Bottom Gap

**Standard Entry**
- `Ctrl + Option + G`: Enter Gap Selection Mode

**In Mode:**
- `J/K/L/I`: Move gap (Resize)
- `Return`: Confirm
- `Escape`: Cancel

### Window Resizing (Normal Mode)
- `Ctrl + Option + -`: Shrink focused window
- `Ctrl + Option + =`: Expand focused window
- `Ctrl + Option + R`: Reset layout (Single column per window)

### Workspace Management
- `Ctrl + Option + O`: Switch to next workspace
- `Ctrl + Option + U`: Switch to previous workspace
- `Ctrl + Option + Shift + O`: Move focused window to next workspace
- `Ctrl + Option + Shift + U`: Move focused window to previous workspace

*Note: Empty workspaces are automatically removed and reordered.*

### Monitor Cursor
- `Ctrl + Option + M` (or `Q`): Move mouse cursor to next monitor

## Installation

1. Clone this repository
2. Open `Axis.xcodeproj` in Xcode
3. Build and run the project
4. Grant Accessibility permissions when prompted

## Requirements

- macOS 14.0 or later
- Xcode 15.0 or later (for building)
- Accessibility permissions (required for window management)

## Setup

1. Launch Axis
2. Go to System Settings > Privacy & Security > Accessibility
3. Add Axis to the list and enable it
4. Restart Axis if needed

## License

MIT