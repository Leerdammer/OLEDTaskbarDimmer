# OLED Taskbar Dimmer

A tiny AutoHotkey v2 tool that dims the Windows taskbar to help protect OLED displays from burn-in.

The taskbar stays dark while you are not using it, smoothly returns to normal when you hover over it, and fades back to dark when the cursor leaves.


## Features

- **Smooth fade animation** – the taskbar becomes normal in ~120 ms when hovered and darkens in ~300 ms when the cursor leaves (configurable).
- **Click-through overlay** – a black overlay is placed over the taskbar, so clicks and hovering keep working normally.
- **Multi-monitor support** – works on the primary taskbar and on secondary-monitor taskbars.
- **Opacity popup** – left-click the tray icon to open a small dark popup with a slider (drag it or use the mouse wheel). No buttons: it applies live, saves on release and closes when you click elsewhere or press `Esc`.
- **Quick hotkeys** – toggle the dimmer or change the opacity without opening anything.
- **Start menu / Search aware** – the taskbar stays normal while the Start menu or Search is open.
- **Fullscreen aware** – the overlay hides automatically when a fullscreen or borderless-fullscreen game or video covers the monitor, and comes back afterwards.
- **Start with Windows** – optional, toggled from the tray menu.
- **Persistent settings** – the opacity is saved to `settings.ini`.

## Prerequisites

| Requirement | Details |
|---|---|
| **Operating system** | Windows 10 or Windows 11 (Windows 11 recommended: rounded popup corners and border use Windows 11 DWM features; on Windows 10 the popup is simply square). |
| **AutoHotkey** | **AutoHotkey v2.0 or newer** (64-bit recommended). Download from <https://www.autohotkey.com/>. The script will **not** run on AutoHotkey v1. |
| **Permissions** | Normal user rights are enough. No administrator rights needed. |
| **Write access** | The script folder must be writable: the script creates `settings.ini` (saved opacity) and `OLEDTaskbarDimmer.ico` (tray icon) next to itself. |

No other dependencies, libraries or installers are needed.

## Installation

1. Install **AutoHotkey v2** (see above).
2. Download `OLEDTaskbarDimmer.ahk` from this repository.
3. Put it in a folder of your choice (for example `C:\Tools\OLEDTaskbarDimmer\`).
4. Double-click `OLEDTaskbarDimmer.ahk` to run it. A yellow sun icon appears in the system tray.
5. *(Optional)* Right-click the tray icon and enable **Start with Windows**.

> If you later move or rename the script, toggle **Start with Windows** off and on again so the startup shortcut points to the new location.

## Usage

### Tray icon

| Action | Result |
|---|---|
| **Left-click** | Opens the opacity popup |
| **Right-click** | Menu with **Enable / Disable**, **Start with Windows** and **Exit** |

### Hotkeys

| Hotkey | Action |
|---|---|
| `Ctrl` + `Alt` + `D` | Enable / disable the dimmer (animated) |
| `Ctrl` + `Alt` + `↑` | Opacity +5% |
| `Ctrl` + `Alt` + `↓` | Opacity −5% |
| `Ctrl` + `Alt` + `O` | Cycle presets: 25% → 50% → 75% → 95% |

### What "opacity" means

The value shown in the popup is the **visibility of the taskbar**, not of the overlay:

- **95%** → taskbar almost fully visible (very light dimming)
- **20%** → taskbar heavily dimmed (strong burn-in protection)

## Configuration

### `settings.ini`

Created automatically in the script folder on the first run (default value shown):

```ini
[Settings]
Alpha=13
```

`Alpha` is the opacity of the black overlay (`0` = no dimming, `255` = fully black). `13` is roughly 95% taskbar visibility; for example `196` is roughly 23%. You normally never edit this by hand: use the popup or the hotkeys. If you delete the file, it is recreated with the default value.

### Animation speed

At the top of `OLEDTaskbarDimmer.ahk`:

```autohotkey
global FADE_UNDIM_MS  := 120   ; hover: taskbar returns to normal
global FADE_DIM_MS    := 300   ; leave: taskbar darkens again
global FADE_TOGGLE_MS := 250   ; Ctrl+Alt+D toggle
```

Lower values make the transition snappier.

## How it works

- A borderless, click-through, topmost window is placed over each taskbar and its opacity is animated with a time-based ease-out curve.
- Hover is detected by comparing the cursor position with the taskbar rectangles.
- The overlay is kept above the taskbar (Windows raises the taskbar itself when you interact with it).
- A window event hook reacts to foreground-window changes to detect fullscreen apps and the Start menu.

## Notes and limitations

- **Burn-in protection is reduced, not eliminated.** Other static elements (title bars, desktop icons, app sidebars, game HUDs) are not covered. Using dark themes, a taskbar that hides automatically, and the pixel-shift / panel-refresh features of your monitor helps further.
- **Online games with anti-cheat.** The script does not read game memory, inject into processes or send input, and it hides itself in fullscreen. Still, kernel-level anti-cheat systems (for example Riot Vanguard) are strict about third-party software and no guarantee can be given. If in doubt, close the script (tray → **Exit**) before launching such games. Use it at your own risk.
- If the taskbar is set to auto-hide, the overlay is positioned off-screen with it.

## Troubleshooting

| Problem | Fix |
|---|---|
| Script does nothing / error on start | Make sure **AutoHotkey v2** is installed (not v1). |
| Tray icon is the default AutoHotkey icon | The script folder is probably read-only; move the script to a writable folder. |
| Taskbar does not dim after clicking some program | Wait a moment or hover the taskbar once; if it persists, please open an issue with your Windows version and the program name. |
| Startup does not work after moving the script | Toggle **Start with Windows** off and on again. |

## Uninstall

1. Right-click the tray icon → disable **Start with Windows** (if enabled).
2. Right-click the tray icon → **Exit**.
3. Delete the script folder (`OLEDTaskbarDimmer.ahk`, `settings.ini`, `OLEDTaskbarDimmer.ico`).

