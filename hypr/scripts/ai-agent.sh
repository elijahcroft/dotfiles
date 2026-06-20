#!/usr/bin/env bash
# Launch Claude or Codex in a kitty window whose title/class/colors show the
# agent and model. The runtime wrapper also makes a best-effort attempt to
# update the kitty title/background if the model changes while the TUI is open.

set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") <claude|codex> [model]" >&2
  echo "Examples: $(basename "$0") claude sonnet | claude opus | codex gpt-5.5" >&2
  exit 1
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

upper() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-'
}

canonical_model() {
  local model
  model="$(lower "${1:-}")"

  case "$model" in
    ""|default)
      printf 'default\n' ;;
    sonnet|claude-sonnet*)
      printf 'sonnet\n' ;;
    opus|claude-opus*)
      printf 'opus\n' ;;
    gpt5.5|gpt-5.5)
      printf 'gpt-5.5\n' ;;
    gpt5|gpt-5)
      printf 'gpt-5\n' ;;
    *)
      printf '%s\n' "$model" ;;
  esac
}

model_label() {
  local model
  model="$(canonical_model "$1")"

  case "$model" in
    default) printf 'DEFAULT\n' ;;
    sonnet) printf 'SONNET\n' ;;
    opus) printf 'OPUS\n' ;;
    *) upper "$model" ;;
  esac
}

style_for() {
  local agent="$1"
  local model
  model="$(canonical_model "$2")"

  case "$agent:$model" in
    claude:sonnet) printf '#24160f #f59e0b\n' ;;
    claude:opus) printf '#24101d #ec4899\n' ;;
    claude:*) printf '#2a1c14 #d97757\n' ;;
    codex:gpt-5.5) printf '#0b1d17 #10a37f\n' ;;
    codex:gpt-5) printf '#0d1a22 #38bdf8\n' ;;
    codex:*) printf '#0e1f1a #10a37f\n' ;;
  esac
}

resolve_cmd() {
  local name="$1"
  local path

  if path="$(command -v "$name" 2>/dev/null)"; then
    printf '%s\n' "$path"
    return 0
  fi

  for path in \
    "$HOME/.local/bin/$name" \
    "$HOME/.npm-global/bin/$name" \
    "/usr/local/bin/$name" \
    "/usr/bin/$name"; do
    if [[ -x "$path" ]]; then
      printf '%s\n' "$path"
      return 0
    fi
  done

  echo "Could not find '$name'. Add it to PATH or install it in ~/.local/bin." >&2
  exit 127
}

codex_default_model() {
  local config="${CODEX_HOME:-$HOME/.codex}/config.toml"
  [[ -r "$config" ]] || return 0

  awk -F= '
    /^[[:space:]]*model[[:space:]]*=/ {
      val=$2
      sub(/^[[:space:]]*/, "", val)
      sub(/[[:space:]]*$/, "", val)
      gsub(/^"|"$/, "", val)
      print val
      exit
    }
  ' "$config"
}

agent="${1:-}"
requested_model="${2:-}"

[[ -n "$agent" ]] || usage
agent="$(lower "$agent")"

case "$agent" in
  claude)
    agent_label="CLAUDE"
    cli_path="$(resolve_cmd claude)"
    ;;
  codex)
    agent_label="CODEX"
    cli_path="$(resolve_cmd codex)"
    ;;
  *)
    usage
    ;;
esac

model_key="$(canonical_model "$requested_model")"
launch_model="$model_key"

if [[ "$model_key" == "default" ]]; then
  launch_model=""
fi

if [[ "$agent" == "codex" && "$model_key" == "default" ]]; then
  display_model="$(codex_default_model)"
  if [[ -n "${display_model:-}" ]]; then
    model_key="$(canonical_model "$display_model")"
  fi
fi

read -r bg tab < <(style_for "$agent" "$model_key")
title="$agent_label / $(model_label "$model_key")"
model_slug="$(slug "$model_key")"
model_slug="${model_slug#-}"
model_slug="${model_slug%-}"
class="ai-${agent}-${model_slug:-default}"

case "$agent" in
  claude)
    cmd=("$cli_path" --name "$title")
    [[ -z "$launch_model" ]] || cmd+=(--model "$launch_model")
    ;;
  codex)
    cmd=("$cli_path")
    [[ -z "$launch_model" ]] || cmd+=(--model "$launch_model")
    ;;
esac

runtime='
set -u

agent=$1
initial_model=$2
shift 2

lower() {
  printf "%s" "$1" | tr "[:upper:]" "[:lower:]"
}

upper() {
  printf "%s" "$1" | tr "[:lower:]" "[:upper:]"
}

canonical_model() {
  local model
  model="$(lower "${1:-}")"

  case "$model" in
    ""|default) printf "default\n" ;;
    sonnet|claude-sonnet*) printf "sonnet\n" ;;
    opus|claude-opus*) printf "opus\n" ;;
    gpt5.5|gpt-5.5) printf "gpt-5.5\n" ;;
    gpt5|gpt-5) printf "gpt-5\n" ;;
    *) printf "%s\n" "$model" ;;
  esac
}

model_label() {
  local model
  model="$(canonical_model "$1")"

  case "$model" in
    default) printf "DEFAULT\n" ;;
    sonnet) printf "SONNET\n" ;;
    opus) printf "OPUS\n" ;;
    *) upper "$model" ;;
  esac
}

style_for() {
  local agent_name="$1"
  local model
  model="$(canonical_model "$2")"

  case "$agent_name:$model" in
    claude:sonnet) printf "#24160f #f59e0b\n" ;;
    claude:opus) printf "#24101d #ec4899\n" ;;
    claude:*) printf "#2a1c14 #d97757\n" ;;
    codex:gpt-5.5) printf "#0b1d17 #10a37f\n" ;;
    codex:gpt-5) printf "#0d1a22 #38bdf8\n" ;;
    codex:*) printf "#0e1f1a #10a37f\n" ;;
  esac
}

apply_visuals() {
  local model="$1"
  local label bg tab agent_label

  case "$agent" in
    claude) agent_label="CLAUDE" ;;
    codex) agent_label="CODEX" ;;
    *) agent_label="$(upper "$agent")" ;;
  esac

  label="$(model_label "$model")"
  read -r bg tab < <(style_for "$agent" "$model")

  printf "\033]0;%s / %s\007" "$agent_label" "$label"
  printf "\033]11;%s\007" "$bg"
}

read_claude_model() {
  local settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
  [[ -r "$settings" ]] || return 0

  if command -v jq >/dev/null 2>&1; then
    jq -r ".model // empty" "$settings" 2>/dev/null
  else
    awk -F: "/\"model\"[[:space:]]*:/ { gsub(/[\", ]/, \"\", \$2); print \$2; exit }" "$settings"
  fi
}

read_codex_config_model() {
  local config="${CODEX_HOME:-$HOME/.codex}/config.toml"
  [[ -r "$config" ]] || return 0

  awk -F= "
    /^[[:space:]]*model[[:space:]]*=/ {
      val=\$2
      sub(/^[[:space:]]*/, \"\", val)
      sub(/[[:space:]]*$/, \"\", val)
      gsub(/^\"|\"$/, \"\", val)
      print val
      exit
    }
  " "$config"
}

read_codex_thread_model() {
  local db="${CODEX_HOME:-$HOME/.codex}/state_5.sqlite"
  [[ -r "$db" ]] || return 0
  command -v sqlite3 >/dev/null 2>&1 || return 0

  sqlite3 "$db" "
    select model
    from threads
    where model is not null and model != \"\"
      and updated_at_ms >= ${start_ms:-0}
    order by updated_at_ms desc
    limit 1;
  " 2>/dev/null
}

start_ms="$(date +%s%3N 2>/dev/null || printf 0)"
"$@" &
child=$!
current_model="$(canonical_model "$initial_model")"
apply_visuals "$current_model"

claude_settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
claude_seen_mtime="$(stat -c %Y "$claude_settings" 2>/dev/null || printf 0)"
codex_config="${CODEX_HOME:-$HOME/.codex}/config.toml"
codex_seen_mtime="$(stat -c %Y "$codex_config" 2>/dev/null || printf 0)"

while kill -0 "$child" 2>/dev/null; do
  new_model=""

  case "$agent" in
    claude)
      mtime="$(stat -c %Y "$claude_settings" 2>/dev/null || printf 0)"
      if [[ "$mtime" != "$claude_seen_mtime" ]]; then
        claude_seen_mtime="$mtime"
        new_model="$(read_claude_model)"
      fi
      ;;
    codex)
      new_model="$(read_codex_thread_model)"
      if [[ -z "$new_model" ]]; then
        mtime="$(stat -c %Y "$codex_config" 2>/dev/null || printf 0)"
        if [[ "$mtime" != "$codex_seen_mtime" ]]; then
          codex_seen_mtime="$mtime"
          new_model="$(read_codex_config_model)"
        fi
      fi
      ;;
  esac

  if [[ -n "$new_model" ]]; then
    new_model="$(canonical_model "$new_model")"
    if [[ "$new_model" != "$current_model" ]]; then
      current_model="$new_model"
      apply_visuals "$current_model"
    fi
  fi

  sleep 2
done

wait "$child"
status=$?
exit "$status"
'

kitty_path="$(resolve_cmd kitty)"

exec "$kitty_path" \
  --class "$class" \
  -o "background=$bg" \
  -o "tab_bar_edge=top" \
  -o "tab_bar_min_tabs=1" \
  -o "active_tab_background=$tab" \
  -o "active_tab_foreground=#000000" \
  -o "tab_title_template={title}" \
  -o "active_tab_title_template={title}" \
  -o "background_opacity=1.0" \
  -o "window_padding_width=6" \
  --hold \
  -- \
  env AI_AGENT="$agent" AI_MODEL="$model_key" AI_AGENT_TITLE="$title" \
  bash -c "$runtime" ai-agent-runtime "$agent" "$model_key" "${cmd[@]}"
