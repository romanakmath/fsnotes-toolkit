#!/bin/bash

# Paste the clipboard as a Markdown link.
#   (no args)  if clipboard is a plain http(s) URL: fetch the page <title>,
#              put [Title](url) on the clipboard and send a real ⌘V keystroke.
#   --prepare  same transformation, but do NOT send ⌘V — the caller (e.g.
#              Hammerspoon) does the pasting itself.

PREPARE_ONLY=0
[ "$1" = "--prepare" ] && PREPARE_ONLY=1

url=$(printf '%s' "$(pbpaste)" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

paste_normally() {
  [ "$PREPARE_ONLY" = 1 ] && exit 0
  osascript -e 'tell application "System Events" to keystroke "v" using command down'
}

# Only transform if the clipboard is exactly one plain URL
if ! printf '%s' "$url" | grep -qE '^https?://[^[:space:]]+$'; then
  paste_normally
  exit 0
fi

title=$(curl -sL --compressed --max-time 3 \
  -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15" \
  "$url" | LC_ALL=en_US.UTF-8 python3 -c '
import sys, re, html
data = sys.stdin.buffer.read().decode("utf-8", "ignore")
m = re.search(r"<title[^>]*>(.*?)</title>", data, re.I | re.S)
if not m:
    sys.exit(0)
t = re.sub(r"\s+", " ", html.unescape(m.group(1))).strip()
t = re.sub(r"\s*[-–|]\s*(YouTube|GitHub|Google|Wikipedia)$", "", t)
print(t)')
[ -z "$title" ] && title=$(printf '%s' "$url" | sed -E 's#^https?://(www\.)?([^/]+).*#\2#')

# Escape brackets in the label; angle-wrap the URL if it contains () or spaces
esc_title=${title//[/\\[}; esc_title=${esc_title//]/\\]}
case "$url" in
  *\(*|*\)*|*\ *) link="<$url>" ;;
  *)               link="$url"  ;;
esac

printf '[%s](%s)' "$esc_title" "$link" | pbcopy
paste_normally
