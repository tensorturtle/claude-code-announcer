#!/usr/bin/env python3
"""Demo: detect whether this terminal session has focus, via xterm
focus-tracking mode (CSI ? 1004 h), supported by iTerm2.

Run it, then click away to another window (or another iTerm2 tab/pane)
and back. Press q or Ctrl-C to quit.

If inside tmux, you need `set -g focus-events on` for events to pass through.
"""

import atexit
import os
import select
import signal
import sys
import termios
import time
import tty

ENABLE_FOCUS = "\x1b[?1004h"
DISABLE_FOCUS = "\x1b[?1004l"
FOCUS_IN = "\x1b[I"
FOCUS_OUT = "\x1b[O"

def main() -> None:
    if not sys.stdin.isatty():
        sys.exit("stdin is not a tty — run this directly in a terminal")

    fd = sys.stdin.fileno()
    saved_attrs = termios.tcgetattr(fd)

    def restore() -> None:
        sys.stdout.write(DISABLE_FOCUS)
        sys.stdout.flush()
        termios.tcsetattr(fd, termios.TCSADRAIN, saved_attrs)

    atexit.register(restore)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    tty.setcbreak(fd)  # raw-ish: no line buffering, no echo; Ctrl-C still works
    sys.stdout.write(ENABLE_FOCUS)
    sys.stdout.flush()

    focused = True  # assumption until the first event; iTerm2 sends one on enable
    events = 0
    buf = ""

    def draw() -> None:
        state = "\x1b[42;30m FOCUSED \x1b[0m" if focused else "\x1b[41;97m UNFOCUSED \x1b[0m"
        sys.stdout.write(f"\r\x1b[2K{state}  events: {events}  ({time.strftime('%H:%M:%S')})  [q to quit] ")
        sys.stdout.flush()

    print("Focus-tracking demo — click away from this window/tab and back.\n")
    draw()

    while True:
        readable, _, _ = select.select([fd], [], [], 0.5)
        if not readable:
            continue
        # Read straight from the fd: sys.stdin.read() would buffer bytes
        # internally where select() can't see them, delaying events.
        buf += os.read(fd, 1024).decode("utf-8", errors="ignore")

        # Match complete focus sequences; anything else falls through as keypresses.
        while True:
            if buf.startswith(FOCUS_IN):
                focused, events, buf = True, events + 1, buf[len(FOCUS_IN):]
            elif buf.startswith(FOCUS_OUT):
                focused, events, buf = False, events + 1, buf[len(FOCUS_OUT):]
            elif buf.startswith("\x1b") and len(buf) < 3:
                break  # partial escape sequence — wait for more bytes
            elif buf:
                ch, buf = buf[0], buf[1:]
                if ch in ("q", "Q"):
                    print("\nbye")
                    return
            else:
                break
        draw()

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nbye")
