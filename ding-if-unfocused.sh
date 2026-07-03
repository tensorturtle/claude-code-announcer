#!/bin/bash
# Claude Code Stop hook: when this terminal session is NOT focused, announce
# via text-to-speech which session finished and a one-line gist of what it did.
#
# "Focused" means: iTerm2 is the frontmost macOS app AND the active iTerm2
# session's tty matches this Claude Code process's tty — so a Claude Code
# sitting in a background tab or unfocused split pane still announces.
#
# Announcement: identifies WHICH session finished (project, branch, what the
# session has been about — from recent user requests) with a few-word outcome,
# written by a small LLM via OpenRouter. Speech: ElevenLabs -> `say` -> ding.
# Keys (both optional — the hook degrades gracefully without them):
# ~/.claude/hooks/{elevenlabs,openrouter}.key (one line each), or the
# ELEVENLABS_API_KEY / OPENROUTER_API_KEY env vars.
#
# Debug: echo '{}' | DING_DEBUG=1 DING_FORCE=1 ~/.claude/hooks/ding-if-unfocused.sh
#   DING_DEBUG=1  print decisions to stderr
#   DING_FORCE=1  skip the focus check (always announce)

SOUND="/System/Library/Sounds/Glass.aiff"
# Volume 0.0 (silent) .. 1.0 (full). Priority: DING_VOLUME env var, then
# ~/.claude/hooks/ding-volume (a file containing just a number), then 0.4.
VOLUME_FILE="$HOME/.claude/hooks/ding-volume"
VOLUME="${DING_VOLUME:-}"
[[ -z "$VOLUME" && -r "$VOLUME_FILE" ]] && VOLUME=$(tr -d '[:space:]' < "$VOLUME_FILE")
VOLUME="${VOLUME:-0.4}"
ELEVEN_VOICE="21m00Tcm4TlvDq8ikWAM"   # Rachel (premade) — set your own voice ID
ELEVEN_MODEL="eleven_flash_v2_5"      # low-latency model
SAY_VOICE="Samantha"
KEY_FILE="$HOME/.claude/hooks/elevenlabs.key"
OR_KEY_FILE="$HOME/.claude/hooks/openrouter.key"
OR_MODEL="anthropic/claude-haiku-4.5"  # small fast model for writing the announcement

payload=$(cat 2>/dev/null)

debug() { [[ -n "$DING_DEBUG" ]] && echo "ding-hook: $*" >&2; }

# ---------- focus detection ----------
is_focused() {
  front=$(lsappinfo info -only name "$(lsappinfo front)" 2>/dev/null)
  if [[ "$front" != *'"iTerm2"'* ]]; then
    debug "unfocused: frontmost app is not iTerm2: $front"
    return 1
  fi
  # iTerm2 is frontmost — is OUR tab/pane the active session? The hook shell
  # has no controlling tty; walk up the process tree until an ancestor has one.
  local pid=$$ t my_tty=""
  for _ in 1 2 3 4 5; do
    t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$t" && "$t" != "??" ]]; then my_tty=$t; break; fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    [[ -z "$pid" || "$pid" -le 1 ]] && break
  done
  if [[ -z "$my_tty" ]]; then
    debug "assume focused: cannot determine own tty"
    return 0  # can't tell — stay quiet
  fi
  active_tty=$(osascript -e 'tell application "iTerm2" to tell current session of current window to get tty' 2>/dev/null)
  if [[ -z "$active_tty" ]]; then
    debug "assume focused: AppleScript query failed (Automation permission?)"
    return 0  # can't tell — stay quiet
  fi
  if [[ "/dev/$my_tty" == "$active_tty" ]]; then
    debug "focused: this session (/dev/$my_tty) is active"
    return 0
  fi
  debug "unfocused: active session is $active_tty, we are /dev/$my_tty"
  return 1
}

if [[ -z "$DING_FORCE" ]] && is_focused; then
  exit 0
fi

# ---------- build the announcement ----------
cwd=$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null)
transcript=$(jq -r '.transcript_path // empty' <<<"$payload" 2>/dev/null)
project=$(basename "${cwd:-$PWD}")

branch=$(git -C "${cwd:-$PWD}" branch --show-current 2>/dev/null)

# Session context from the transcript: recent user requests (what this session
# is about) plus the final assistant message (how it ended).
last_msg=""
user_msgs=""
if [[ -n "$transcript" && -r "$transcript" ]]; then
  last_msg=$(tail -n 100 "$transcript" 2>/dev/null | jq -r '
      select(.type == "assistant")
      | (.message.content // [])
      | map(select(.type == "text") | .text)
      | join(" ")
      | gsub("[[:space:]]+"; " ")
      | select(length > 0)' 2>/dev/null | tail -n 1)
  last_msg=${last_msg:0:800}
  user_msgs=$(tail -n 300 "$transcript" 2>/dev/null | jq -r '
      select(.type == "user")
      | .message.content
      | if type == "string" then . else (map(select(.type == "text") | .text) | join(" ")) end
      | select(test("<system-reminder>|<local-command|<command-name>") | not)
      | gsub("[[:space:]]+"; " ")
      | select(length > 0)' 2>/dev/null | tail -n 4 | cut -c1-200)
fi

# Ask a small LLM via OpenRouter to write the spoken announcement.
or_key=${OPENROUTER_API_KEY:-}
[[ -z "$or_key" && -r "$OR_KEY_FILE" ]] && or_key=$(tr -d '[:space:]' < "$OR_KEY_FILE")

text=""
if [[ -n "$last_msg" && -n "$or_key" ]]; then
  context=$(printf 'Project: %s\nGit branch: %s\nRecent user requests:\n%s\nAssistant final message: %s' \
      "${project//[-_]/ }" "${branch:-unknown}" "$user_msgs" "$last_msg" \
      | sed -E 's/(sk|gh[pos]|xox[bp])[-_][A-Za-z0-9_-]{12,}/[redacted key]/g')
  or_body=$(jq -n --arg model "$OR_MODEL" --arg ctx "$context" '{
    model: $model,
    max_tokens: 60,
    messages: [
      { role: "system",
        content: "You announce to a developer running several Claude Code terminal sessions that one of them just finished. Identify the session: project name, branch if it helps, and what the session has been about, judged from the user requests. Keep the outcome to a few words at the end. One sentence, max 18 words, simple spoken language, no markdown, no code symbols, no file paths. Example: \"Your ayni health session about the voice notification hook is done and waiting for review.\"" },
      { role: "user", content: $ctx }
    ]
  }')
  text=$(curl -sf --max-time 12 https://openrouter.ai/api/v1/chat/completions \
      -H "Authorization: Bearer $or_key" -H "Content-Type: application/json" \
      -d "$or_body" 2>/dev/null | jq -r '.choices[0].message.content // empty' \
      | tr '\n' ' ' | sed -E 's/^[" ]+|[" ]+$//g')
  [[ -n "$text" ]] && debug "announcement via OpenRouter ($OR_MODEL)"
fi

# Fallback: identify the session mechanically
if [[ -z "$text" ]]; then
  debug "OpenRouter unavailable, using mechanical announcement"
  text="${project//[-_]/ } session${branch:+ on branch ${branch//[-_\/]/ }} finished."
fi
debug "announce: $text"

# ---------- speak: ElevenLabs -> say -> ding ----------
eleven_key=${ELEVENLABS_API_KEY:-}
[[ -z "$eleven_key" && -r "$KEY_FILE" ]] && eleven_key=$(tr -d '[:space:]' < "$KEY_FILE")

if [[ -n "$eleven_key" ]]; then
  tmp=$(mktemp -t claude-tts).mp3
  if curl -sf --max-time 15 \
      -X POST "https://api.elevenlabs.io/v1/text-to-speech/${ELEVEN_VOICE}?output_format=mp3_44100_128" \
      -H "xi-api-key: $eleven_key" -H "Content-Type: application/json" \
      -d "$(jq -n --arg t "$text" --arg m "$ELEVEN_MODEL" '{text: $t, model_id: $m}')" \
      -o "$tmp" && [[ -s "$tmp" ]]; then
    debug "spoken via ElevenLabs"
    afplay -v "$VOLUME" "$tmp" >/dev/null 2>&1
    rm -f "$tmp"
    exit 0
  fi
  rm -f "$tmp"
  debug "ElevenLabs failed (key lacks text_to_speech permission?), falling back to say"
fi

if say -v "$SAY_VOICE" "[[volm $VOLUME]] $text" 2>/dev/null; then
  debug "spoken via macOS say"
  exit 0
fi

debug "say failed, falling back to ding"
afplay -v "$VOLUME" "$SOUND" >/dev/null 2>&1
exit 0
