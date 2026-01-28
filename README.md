# Axis

A keyboard-driven tiling window manager for macOS.

## Features

- **Tiling Layout**: Automatically arranges windows in a tiling layout
- **Keyboard Navigation**: Move focus between windows using vim-style keys (J/L/I/K)
- **Window Movement**: Reorganize windows with keyboard shortcuts
- **Gap Selection Mode**: Resize windows by selecting and moving gaps between them
- **Window Selection Mode**: Select and merge multiple windows into columns
- **Normal Mode Resize**: Resize focused window with center-fixed positioning
- **Visual Feedback**: Border highlights around the focused window

## Keyboard Shortcuts

### Basic Navigation (Normal Mode)
- `Ctrl + Option + J`: Move focus left
- `Ctrl + Option + L`: Move focus right
- `Ctrl + Option + I`: Move focus up
- `Ctrl + Option + K`: Move focus down

### Window Movement
- `Ctrl + Cmd + J`: Move window/column left
- `Ctrl + Cmd + L`: Move window/column right
- `Ctrl + Cmd + I`: Move window up (within column)
- `Ctrl + Cmd + K`: Move window down (within column)

### Window Resizing (Normal Mode)
- `Ctrl + Option + -`: Shrink focused window
- `Ctrl + Option + =`: Expand focused window

### Gap Selection Mode
- `Ctrl + Option + G`: Enter gap selection mode
- `J/L/I/K`: Navigate between gaps
- `Return`: Select gap and enter resize mode
- `J/L/I/K`: Move gap (resize windows)
- `Return`: Confirm resize
- `Escape`: Exit gap selection mode

### Window Selection Mode
- `Ctrl + Option + V`: Enter window selection mode
- `J/L/I/K`: Navigate and select windows
- `M`: Merge selected windows into a column
- `S`: Split selected windows into separate columns
- `R`: Reset all windows to single columns
- `Escape`: Exit window selection mode

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

## How It Works

Axis uses macOS Accessibility APIs to manage window positions and sizes. Windows are organized in a column-based layout, where:

- Each window or group of windows forms a column
- Windows within a column are stacked vertically
- Columns are arranged horizontally across the screen
- Gaps between windows can be adjusted using gap selection mode

## License

MIT
