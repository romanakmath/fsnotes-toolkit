#!/bin/bash
# Symlink the live tooling files to this repo checkout (idempotent).
set -euo pipefail
cd "$(dirname "$0")"
REPO="$(pwd -P)"

link() {  # link <repo-file> <live-path>
  local src="$REPO/$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    mv "$dst" "$dst.pre-toolkit.bak"
    echo "backed up: $dst → $dst.pre-toolkit.bak"
  fi
  ln -sfn "$src" "$dst"
  echo "linked: $dst → $src"
}

link "hammerspoon/init.lua" "$HOME/.hammerspoon/init.lua"
link "bin/paste-as-md-link.sh" "$HOME/bin/paste-as-md-link.sh"
link "raycast/paste-as-markdown-link.sh" \
  "$HOME/Library/Application Support/Raycast/Scripts/paste-as-markdown-link.sh"

chmod +x "$REPO/bin/paste-as-md-link.sh" "$REPO/raycast/paste-as-markdown-link.sh"

echo
echo "Done. Reload Hammerspoon (or: hs -c 'hs.reload()') to activate."
