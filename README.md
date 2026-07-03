# ding-if-unfocused

A [Claude Code](https://claude.com/claude-code) hook for macOS + iTerm2 that **speaks a one-line summary of what Claude just finished — but only when you're not looking at it.**

Stay focused on the pane where Claude is working and it stays silent. Switch to another window, tab, or split pane, and when Claude finishes you'll hear something like:

> *"Your ayni health session about fixing the stream unread divider is done and ready."*

Built for running several Claude Code sessions at once: the announcement leads with **which session** finished — project, branch, and what that session has been about — so you know where to switch, without a lecture on what was done. It's written by a small LLM from the session transcript and spoken with an ElevenLabs voice. Every stage degrades gracefully: no OpenRouter key → mechanical text trim; no ElevenLabs key → macOS `say`; no audio at all → a plain Glass ding.

## How it works

On every [`Stop` hook](https://docs.claude.com/en/docs/claude-code/hooks) event (Claude finished responding), the script:

1. **Checks focus** — with pane-level precision, from outside the tty:
   - Is iTerm2 the frontmost macOS app? (`lsappinfo`, no permissions needed)
   - If so, does the active iTerm2 session's tty (AppleScript) match *this* Claude Code's tty (found by walking up the process tree)?
   - Both true → you're watching → exit silently. A Claude Code in a background tab or unfocused split pane still announces.
2. **Builds the announcement** — gathers session identity (project directory, git branch, the last few user requests from the session transcript, plus Claude's final message) and asks a small model via OpenRouter (default `anthropic/claude-haiku-4.5`) to write one spoken sentence, max 18 words, that names the session and its topic first and keeps the outcome to a few words. Anything that looks like an API key is redacted before the context is sent, and `<system-reminder>` blocks are filtered out.
3. **Speaks it** — via ElevenLabs TTS (default model `eleven_flash_v2_5`), played with `afplay`.

Why not the xterm focus-tracking escape sequence (`CSI ?1004h`)? That's the right tool *inside* a TUI — but a hook is a subprocess that doesn't own the terminal's input stream (Claude Code does). So the hook detects focus from the outside instead. `focus_demo.py` in this repo demonstrates the in-band approach for the curious.

## Requirements

- macOS (uses `lsappinfo`, `osascript`, `afplay`, `say`)
- iTerm2 (pane-level focus detection is iTerm2-specific; on other terminals it would need adapting)
- `jq`, `curl`
- Optional: an [ElevenLabs](https://elevenlabs.io) API key with the *Text to Speech* permission
- Optional: an [OpenRouter](https://openrouter.ai) API key

## Install

```bash
mkdir -p ~/.claude/hooks
cp ding-if-unfocused.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/ding-if-unfocused.sh
```

Add the hook to `~/.claude/settings.json` (merge with any existing `hooks` key):

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/ding-if-unfocused.sh",
            "async": true,
            "timeout": 45
          }
        ]
      }
    ]
  }
}
```

Drop in your keys (both optional):

```bash
echo 'sk_your_elevenlabs_key' > ~/.claude/hooks/elevenlabs.key
echo 'sk-or-your_openrouter_key' > ~/.claude/hooks/openrouter.key
chmod 600 ~/.claude/hooks/*.key
```

Environment variables `ELEVENLABS_API_KEY` / `OPENROUTER_API_KEY` take precedence over the key files if set.

Open `/hooks` in Claude Code (or restart it) so the new hook is picked up, then test:

```bash
echo '{}' | DING_FORCE=1 DING_DEBUG=1 ~/.claude/hooks/ding-if-unfocused.sh
```

`DING_FORCE=1` skips the focus check; `DING_DEBUG=1` prints every decision to stderr.

## Configuration

| What | Where | Default |
|---|---|---|
| Volume (0.0–1.0, all tiers) | `echo 0.3 > ~/.claude/hooks/ding-volume`, or `DING_VOLUME` env var | `0.4` |
| ElevenLabs voice | `ELEVEN_VOICE` variable in the script | Rachel (`21m00Tcm4TlvDq8ikWAM`) |
| ElevenLabs TTS model | `ELEVEN_MODEL` in the script | `eleven_flash_v2_5` |
| Summary LLM | `OR_MODEL` in the script | `anthropic/claude-haiku-4.5` |
| macOS `say` voice (fallback) | `SAY_VOICE` in the script | `Samantha` |
| Fallback ding sound | `SOUND` in the script | `Glass.aiff` |

## Fallback chain

Nothing here is load-bearing; every failure just steps down a tier:

```
focus unknown ──────────────► stay silent (never annoy a focused user)
OpenRouter down / no key ───► "<project> session on branch <branch> finished."
ElevenLabs down / no key ───► macOS `say`
`say` fails ────────────────► Glass ding
```

## Bonus: focus_demo.py

A small stdlib-only Python TUI demonstrating the *in-band* way to detect terminal focus — xterm focus-tracking mode (`ESC[?1004h`), where the terminal itself reports `ESC[I` / `ESC[O` on focus change, with pane-level precision and no OS permissions. Run it, click around, watch the badge flip:

```bash
python3 focus_demo.py
```

## License

MIT
