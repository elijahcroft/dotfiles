#!/usr/bin/env bash
# Clipboard history picker — cliphist + wofi (styled via ~/.config/wofi/style.css).
cliphist list | wofi --dmenu --prompt "Clipboard" | cliphist decode | wl-copy
