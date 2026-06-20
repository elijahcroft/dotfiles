#!/bin/bash
# Pomodoro for waybar. State file holds: "<phase> <end_epoch>".
#   start  -> 25min work + 5min break (background sleeps; notifies via dunst)
#   stop   -> reset to idle and halt a running session
#   status -> waybar JSON with .work/.break class so the bar pill lights up

STATE="$HOME/.cache/pomodoro"
[ ! -f "$STATE" ] && echo "idle 0" > "$STATE"

case "$1" in
  start)
    echo "work $(( $(date +%s) + 1500 ))" > "$STATE"
    notify-send "Pomodoro" "25 minutes. Lock in."
    sleep 1500
    echo "break $(( $(date +%s) + 300 ))" > "$STATE"
    notify-send "Pomodoro" "Break time."
    sleep 300
    echo "idle 0" > "$STATE"
    notify-send "Pomodoro" "Back to work."
    ;;
  stop)
    pkill -f "pomodoro.sh start" 2>/dev/null
    echo "idle 0" > "$STATE"
    ;;
  status)
    read -r phase end < "$STATE"
    if [ "$phase" = "idle" ]; then
      printf '{"text":"󰔟","class":"idle","tooltip":"Pomodoro — click to start"}\n'
    else
      now=$(date +%s)
      rem=$(( end - now ))
      (( rem < 0 )) && rem=0
      mm=$(( rem / 60 )); ss=$(( rem % 60 ))
      if [ "$phase" = "work" ]; then icon="󰔟"; else icon="󰅶"; fi
      printf '{"text":"%s %02d:%02d","class":"%s","tooltip":"Pomodoro: %s — right-click to stop"}\n' \
        "$icon" "$mm" "$ss" "$phase" "$phase"
    fi
    ;;
esac
