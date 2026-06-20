#!/bin/bash
# Claude subscription usage for waybar. Shows current 5h session % used + weekly.
# Pulls the same data as Claude Code's /usage screen via the OAuth usage endpoint.
# Requires: jq, curl. Reads the OAuth token Claude Code maintains in ~/.claude.

CREDS="$HOME/.claude/.credentials.json"
CACHE="$HOME/.cache/waybar-claude-usage.json"
TOKEN="$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDS" 2>/dev/null)"

# On any failure, fall back to the last good reading so a transient blip (e.g. a
# rate-limit 429) doesn't blank the icon. Only show a placeholder if no cache exists.
fallback() {
  if [ -s "$CACHE" ]; then cat "$CACHE"; else
    printf '{"text": "%s", "class": "idle", "tooltip": "Claude — %s"}\n' "$1" "$2"
  fi
}

if [ -z "$TOKEN" ]; then
  fallback "?" "not logged in (no OAuth token)"; exit 0
fi

DATA="$(curl -s --max-time 8 "https://api.anthropic.com/api/oauth/usage" \
  -H "Authorization: Bearer $TOKEN" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "anthropic-version: 2023-06-01")"

if [ -z "$DATA" ] || echo "$DATA" | jq -e '.error' >/dev/null 2>&1; then
  fallback "–" "usage temporarily unavailable"; exit 0
fi

read -r SESSION WEEKLY SRESET WRESET < <(echo "$DATA" | jq -r '
  [(.five_hour.utilization // 0),
   (.seven_day.utilization // 0),
   (.five_hour.resets_at // ""),
   (.seven_day.resets_at // "")] | @tsv')

SESSION=${SESSION%.*}
WEEKLY=${WEEKLY%.*}

# Color by whichever limit is closer to full.
PEAK=$(( SESSION > WEEKLY ? SESSION : WEEKLY ))
if   [ "$PEAK" -ge 90 ]; then CLASS="high"
elif [ "$PEAK" -ge 60 ]; then CLASS="active"
else CLASS="idle"; fi

fmt_reset() { [ -n "$1" ] && date -d "$1" +"%-I:%M%p %a" 2>/dev/null | tr 'APM' 'apm'; }
SRESET_F="$(fmt_reset "$SRESET")"
WRESET_F="$(fmt_reset "$WRESET")"

# Render a block-character progress bar like Claude Code's /usage screen.
bar() { # $1 = percent, $2 = width in cells
  local pct=$1 width=$2 filled i out=""
  filled=$(( (pct * width + 50) / 100 ))
  [ "$filled" -lt 0 ] && filled=0
  [ "$filled" -gt "$width" ] && filled=$width
  for ((i=0; i<filled; i++)); do out+="█"; done
  for ((i=filled; i<width; i++)); do out+="░"; done
  printf '%s' "$out"
}

TEXT_BAR="$(bar "$SESSION" 10)"
SESSION_BAR="$(bar "$SESSION" 16)"
WEEKLY_BAR="$(bar "$WEEKLY" 16)"

mkdir -p "$(dirname "$CACHE")"
printf '{"text": "%s %s%%", "class": "%s", "tooltip": "Claude subscription\\nSession  %s %s%% · resets %s\\nWeekly   %s %s%% · resets %s"}\n' \
  "$TEXT_BAR" "$SESSION" "$CLASS" \
  "$SESSION_BAR" "$SESSION" "$SRESET_F" \
  "$WEEKLY_BAR" "$WEEKLY" "$WRESET_F" | tee "$CACHE"
