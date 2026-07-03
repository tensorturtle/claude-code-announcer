#!/bin/bash
# Claude Code Stop hook: when the terminal session Claude Code runs in is NOT
# focused, announce via text-to-speech which session finished and a one-line
# gist of what it did. If everything else fails, fall back to a simple ding.
#
# "Focused" means: iTerm2 is the frontmost macOS app AND the active iTerm2
# session's tty matches this Claude Code process's tty — so a Claude Code
# sitting in a background tab or unfocused split pane still announces.
#
# Announcement text: the final assistant message is summarised into one spoken
# sentence by a small LLM via OpenRouter (falls back to a mechanical trim).
# Speech chain: ElevenLabs TTS -> macOS `say` -> plain ding.
#
# API keys (both optional — the hook degrades gracefully without them):
#   ElevenLabs: $ELEVENLABS_API_KEY or ~/.claude/hooks/elevenlabs.key
#   OpenRouter: $OPENROUTER_API_KEY or ~/.claude/hooks/openrouter.key
#   (key files: just the key, one line)
#
# Debug: echo '{}' | DING_DEBUG=1 DING_FORCE=1 ./ding-if-unfocused.sh
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
ELEVEN_MODEL="eleven_flash_v2_5"      # low-latency TTS model
SAY_VOICE="Samantha"
KEY_FILE="$HOME/.claude/hooks/elevenlabs.key"
OR_KEY_FILE="$HOME/.claude/hooks/openrouter.key"
OR_MODEL="anthropic/claude-haiku-4.5" # small fast model for writing the announcement

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

# Raw final assistant message from the transcript (input for the LLM writer)
last_msg=""
if [[ -n "$transcript" && -r "$transcript" ]]; then
  last_msg=$(tail -n 100 "$transcript" 2>/dev/null | jq -r '
      select(.type == "assistant")
      | (.message.content // [])
      | map(select(.type == "text") | .text)
      | join(" ")
      | gsub("[[:space:]]+"; " ")
      | select(length > 0)' 2>/dev/null | tail -n 1)
  last_msg=${last_msg:0:4000}
fi

# Ask a small LLM via OpenRouter to write the spoken announcement.
or_key=${OPENROUTER_API_KEY:-}
[[ -z "$or_key" && -r "$OR_KEY_FILE" ]] && or_key=$(tr -d '[:space:]' < "$OR_KEY_FILE")

summary=""
if [[ -n "$last_msg" && -n "$or_key" ]]; then
  or_body=$(jq -n --arg model "$OR_MODEL" --arg msg "$last_msg" '{
    model: $model,
    max_tokens: 80,
    messages: [
      { role: "system",
        content: "You turn a coding assistant'\''s final message into a short spoken notification. One sentence, max 22 words, first person past tense (e.g. \"I fixed the login bug and the tests pass.\"). Plain speech only: no markdown, no code symbols, no file paths. Lead with the concrete outcome. If the assistant asked a question or is blocked, say what it needs instead." },
      { role: "user", content: $msg }
    ]
  }')
  summary=$(curl -sf --max-time 12 https://openrouter.ai/api/v1/chat/completions \
      -H "Authorization: Bearer $or_key" -H "Content-Type: application/json" \
      -d "$or_body" 2>/dev/null | jq -r '.choices[0].message.content // empty' \
      | tr '\n' ' ' | sed -E 's/^[" ]+|[" ]+$//g')
  [[ -n "$summary" ]] && debug "summary via OpenRouter ($OR_MODEL)"
fi

# Fallback: mechanical trim of the raw message
if [[ -z "$summary" && -n "$last_msg" ]]; then
  debug "OpenRouter unavailable, using mechanical trim"
  summary=$(sed -E 's/[*_`#|>]//g; s/\[([^]]*)\]\([^)]*\)/\1/g' <<<"$last_msg")
  summary=$(sed -E 's/^((([^.!?]+)[.!?]){1,2}).*$/\1/' <<<"$summary")
  if [[ ${#summary} -gt 280 ]]; then
    summary="${summary:0:280}"
    summary="${summary% *}"  # drop the trailing partial word
  fi
fi
[[ -z "$summary" ]] && summary="finished its task."

text="${project//[-_]/ } session: $summary"
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
  debug "ElevenLabs failed, falling back to say"
fi

if say -v "$SAY_VOICE" "[[volm $VOLUME]] $text" 2>/dev/null; then
  debug "spoken via macOS say"
  exit 0
fi

debug "say failed, falling back to ding"
afplay -v "$VOLUME" "$SOUND" >/dev/null 2>&1
exit 0
