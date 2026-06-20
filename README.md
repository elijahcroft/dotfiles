# dotfiles

Personal `~/.config` for an Arch + Hyprland setup. The repo lives directly in
`~/.config`; a deny-all `.gitignore` whitelists only the configs below, so app
caches, browser profiles, and credentials are never tracked.

## What's here

| Dir | What |
| --- | --- |
| `hypr/` | Hyprland — window manager, lock, idle, wallpaper, scripts, videowall |
| `waybar/` | Status bar config, style, and scripts |
| `ghostty/` | Ghostty terminal |
| `kitty/` | Kitty terminal |
| `dunst/` | Notification daemon |
| `wofi/` | App launcher |
| `wlogout/` | Logout menu |
| `fastfetch/` | System fetch |
| `btop/` | System monitor |
| `eww/` | Widgets |
| `git/` | Git config |

## Install

```sh
git clone https://github.com/elijahcroft/dotfiles ~/.config
```

Then reload Hyprland (`hyprctl reload`) and restart Waybar.
