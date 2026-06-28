#!/usr/bin/env bash
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HARNESS_DIR/../../.." && pwd)"
FIXTURE="${1:-word_swap}"
PHASE="${2:-after_highlight}"
STAMP="$(date +%Y-%m-%d_%H-%M-%S)"

mkdir -p "$HARNESS_DIR/out" "$HARNESS_DIR/.state"

CONF="$HARNESS_DIR/.state/tmux_${FIXTURE}_${PHASE}_${STAMP}.conf"
DUMP="$HARNESS_DIR/.state/${FIXTURE}_${PHASE}_${STAMP}.ansi"
READY="$HARNESS_DIR/.state/${FIXTURE}_${PHASE}_${STAMP}.ready"
OUT="$HARNESS_DIR/out/${FIXTURE}_${PHASE}_${STAMP}.tmux.png"
SOCK="avante-sdh-${PHASE}-${STAMP}-$$"

cat > "$CONF" <<'EOF'
set -g default-terminal "tmux-256color"
set -as terminal-features ",*:RGB"
set -g status off
set -g mouse off
EOF

tmux -L "$SOCK" -f "$CONF" new-session -d -x 100 -y 18 \
  -e AVANTE_REPO="$REPO" \
  -e AVANTE_SELECTION_DIFF_FIXTURE="$FIXTURE" \
  -e AVANTE_SELECTION_DIFF_PHASE="$PHASE" \
  -e AVANTE_SELECTION_DIFF_READY="$READY" \
  -e XDG_DATA_HOME="$HARNESS_DIR/.state/data" \
  -e XDG_STATE_HOME="$HARNESS_DIR/.state/state" \
  -e XDG_CACHE_HOME="$HARNESS_DIR/.state/cache" \
  -e XDG_CONFIG_HOME="$HARNESS_DIR/.state/config" \
  -e TERM=tmux-256color \
  -e COLORTERM=truecolor \
  "nvim --clean --noplugin -Nu '$HARNESS_DIR/init.lua'"

for _ in {1..50}; do
  if [ -f "$READY" ]; then break; fi
  sleep 0.1
done

tmux -L "$SOCK" capture-pane -p -e > "$DUMP"
tmux -L "$SOCK" kill-server

if command -v freeze >/dev/null; then
  freeze "$DUMP" --output "$OUT" --font.size 16
else
  nix shell nixpkgs#charm-freeze --command freeze "$DUMP" --output "$OUT" --font.size 16
fi

if command -v magick >/dev/null; then
  magick "$OUT" -trim +repage "$OUT"
fi

echo "wrote $OUT"
