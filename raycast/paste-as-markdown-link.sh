#!/bin/bash

# @raycast.schemaVersion 1
# @raycast.title Paste as Markdown Link
# @raycast.mode silent
# @raycast.packageName Clipboard Helpers
# @raycast.icon 📎
#
# Global fallback (any app). The real logic lives in ~/bin/paste-as-md-link.sh
# (also used by the BetterTouchTool trigger scoped to FSNotes).

exec bash "$HOME/bin/paste-as-md-link.sh"
