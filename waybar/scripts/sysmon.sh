#!/usr/bin/env bash
# Combined CPU + RAM readout for a single waybar module.
# Icons recolor with load (gray -> amber -> red) and the tooltip shows
# sparkline graphs built from a rolling history of recent samples.

HIST_LEN=30
CPU_HIST=/tmp/waybar-sysmon-cpu.hist
RAM_HIST=/tmp/waybar-sysmon-ram.hist

cpu_usage() {
  read -ra a < /proc/stat
  local idle1=${a[4]} total1=0 v
  for v in "${a[@]:1}"; do total1=$((total1 + v)); done
  sleep 0.4
  read -ra b < /proc/stat
  local idle2=${b[4]} total2=0
  for v in "${b[@]:1}"; do total2=$((total2 + v)); done
  local dt=$((total2 - total1)) di=$((idle2 - idle1))
  (( dt == 0 )) && { echo 0; return; }
  echo $(( (100 * (dt - di) + dt / 2) / dt ))
}

mem_usage() {
  awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "%d", (t-a)*100/t}' /proc/meminfo
}

# Append a value and keep only the last HIST_LEN samples.
push_hist() {
  local file=$1 val=$2
  echo "$val" >> "$file"
  tail -n "$HIST_LEN" "$file" > "$file.tmp" 2>/dev/null && mv "$file.tmp" "$file"
}

# Pick a color for a load percentage.
load_color() {
  local v=$1
  if   (( v >= 85 )); then echo '#ff5f56'   # red
  elif (( v >= 60 )); then echo '#ffbd2e'   # amber
  else                     echo '#cfcfcf'    # neutral
  fi
}

# Build a unicode sparkline from a history file.
spark() {
  local file=$1 out='' v idx
  local chars=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
  while read -r v; do
    [[ -z $v ]] && continue
    idx=$(( v * 7 / 100 ))
    (( idx > 7 )) && idx=7
    out+="${chars[idx]}"
  done < "$file"
  printf '%s' "$out"
}

cpu=$(cpu_usage)
mem=$(mem_usage)

push_hist "$CPU_HIST" "$cpu"
push_hist "$RAM_HIST" "$mem"

cpu_col=$(load_color "$cpu")
mem_col=$(load_color "$mem")

# Single icon colored by whichever resource is busier.
peak=$(( cpu > mem ? cpu : mem ))
icon_col=$(load_color "$peak")

# 󰓅 speedometer (U+F04C5) — one glyph, color carries the load signal.
text="<span color='${icon_col}'>󰓅</span>"

# Tooltip: label + sparkline graph for each, colored to match the icons.
tooltip="<b>CPU</b> ${cpu}%\\n<span color='${cpu_col}'>$(spark "$CPU_HIST")</span>\\n<b>RAM</b> ${mem}%\\n<span color='${mem_col}'>$(spark "$RAM_HIST")</span>"

# Module class: glow when either resource is under heavy load.
class=""
if (( cpu >= 85 || mem >= 85 )); then class="high"; fi

printf '{"text":"%s","tooltip":"%s","class":"%s"}\n' "$text" "$tooltip" "$class"
