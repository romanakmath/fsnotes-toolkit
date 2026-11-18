# fsnotes-toolkit

Workflow tooling for [FSNotes](https://fsnot.es) and the surrounding markdown-editing process on macOS.

## ✂️ md-paste: ⌘⇧V pastes a URL as `[Title](url)` (Noteplan-style)

FSNotes has no built-in "paste link as markdown". [Noteplan](https://noteplan.co) users get instant title+URL pastes; this toolkit brings the same to FSNotes via [Hammerspoon](https://www.hammerspoon.org).

Press **⌘⇧V** in FSNotes with a URL on the clipboard → a markdown link with the real page title lands at your cursor.

## 🔗 rich-paste: Chromium web-app copies keep their links

Copying from web apps (e.g. [Recall](https://recall.wiki) transcripts with YouTube timestamps) puts the *plain text* on the clipboard while the actual link lives only in the `public.html` flavor — so FSNotes pastes a bare `00:27`. ⌘⇧V detects anchors in the HTML flavor and surgically replaces their visible text in the plain text: `[00:27](https://…&t=27s)` — fully local, instant, byte-identical to Noteplan's paste.

### How the title is resolved (fastest first)

| Path | Latency | When |
|---|---|---|
| **Pasteboard title** | ~0ms | Clipboard carries a rich link (Safari *Copy Link* → `WebURLsWithTitlesPboardType`, Chromium anchor HTML, `public.url-name`) — the trick Noteplan's binary uses |
| **Cache** | ~0ms | Same URL pasted in the last 10 min |
| **Network fetch** | ~0.5s (3s cap) | Plain-text URL only; falls back to hostname, never hangs |
| **Forward** | ~0ms | Not a URL → plain paste / direct text insert |

### How the text is delivered: AX insertion, not keystrokes

The link is written straight into the focused editor via `AXSelectedText` (Accessibility API). No synthetic ⌘V, no clipboard swap, no modifier coupling, no keyboard-layout sensitivity, immune to the user physically holding ⌘/⇧ when the paste lands. Clipboard and keystroke synthesis exist only as a logged fallback for apps where AX isn't settable.

## 📝 Hard-won pitfalls (the reason this looks the way it does)

- **`hs.task` callbacks die silently when the child writes large stdout** (Hammerspoon 1.1.1). A curl piping a full page (~1MB) through the pipe never calls back. Fix: `curl -o /tmp/file`, read from disk in the callback.
- **Lua patterns have no `|` alternation.** `(YouTube|GitHub)` is matched as one literal string. Strip alternatives in a loop.
- **macOS keycodes: `V` = 9, `D` = 2.** Easy to confuse with HID usage IDs — a hotkey bound to "9 = D" silently fires on ⌘⇧V instead of ⌘⇧D.
- **A synthetic ⌘V posted while the user still holds ⇧ arrives as ⌘⇧V** — in FSNotes that's *Duplicate*, not paste. Any clipboard+keystroke delivery needs a modifier-release wait; AX insertion needs nothing.
- **Event taps must return `nil`, never `true`.** `true` consumes every keypress system-wide. And macOS silently disables taps on callback timeouts — hence the 0.5s re-arm watchdog.
- **Clipboard swaps are a state machine**: propagation delays, restore timers, repeat-detection. AX insertion deletes that entire class of bugs.

## Install

Requirements: Hammerspoon (granted Accessibility), FSNotes.

```bash
git clone https://github.com/romanakmath/fsnotes-toolkit.git
cd fsnotes-toolkit
./install.sh        # symlinks the live files to this checkout
```

`install.sh` links:

| Live location | Repo file |
|---|---|
| `~/.hammerspoon/init.lua` | `hammerspoon/init.lua` |
| `~/bin/paste-as-md-link.sh` | `bin/paste-as-md-link.sh` |
| `~/Library/Application Support/Raycast/Scripts/paste-as-markdown-link.sh` | `raycast/paste-as-markdown-link.sh` |

Then reload Hammerspoon. The flight recorder logs every press and code path with ms timestamps to `/tmp/hs-mdlink.log` — if something misbehaves, the evidence is there.

### Standalone without Hammerspoon

`bin/paste-as-md-link.sh` transforms the clipboard in place and sends ⌘V itself — works from any launcher (the Raycast wrapper in `raycast/` calls it).

## Roadmap / ideas

- `public.url` rich-clipboard links as instant source (v1 limitation)
- more FSNotes workflow shortcuts as they prove themselves
