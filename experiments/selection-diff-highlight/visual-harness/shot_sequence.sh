#!/usr/bin/env bash
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HARNESS_DIR/../../.." && pwd)"
FIXTURE="${1:-word_swap}"
STAMP="$(date +%Y-%m-%d_%H-%M-%S)"
SEQ_DIR="$HARNESS_DIR/sequences/${FIXTURE}_${STAMP}"

mkdir -p "$SEQ_DIR" "$HARNESS_DIR/.state"

render_phase() {
  local phase="$1"
  local index="$2"
  local title="$3"
  local conf="$HARNESS_DIR/.state/tmux_${FIXTURE}_${phase}_${STAMP}.conf"
  local dump="$HARNESS_DIR/.state/${FIXTURE}_${phase}_${STAMP}.ansi"
  local ready="$HARNESS_DIR/.state/${FIXTURE}_${phase}_${STAMP}.ready"
  local raw="$SEQ_DIR/${index}_${phase}.raw.png"
  local out="$SEQ_DIR/${index}_${phase}.png"
  local sock="avante-sdh-${phase}-${STAMP}-$$"

  cat > "$conf" <<'EOF'
set -g default-terminal "tmux-256color"
set -as terminal-features ",*:RGB"
set -g status off
set -g mouse off
EOF

  tmux -L "$sock" -f "$conf" new-session -d -x 100 -y 18 \
    -e AVANTE_REPO="$REPO" \
    -e AVANTE_SELECTION_DIFF_FIXTURE="$FIXTURE" \
    -e AVANTE_SELECTION_DIFF_PHASE="$phase" \
    -e AVANTE_SELECTION_DIFF_READY="$ready" \
    -e XDG_DATA_HOME="$HARNESS_DIR/.state/data" \
    -e XDG_STATE_HOME="$HARNESS_DIR/.state/state" \
    -e XDG_CACHE_HOME="$HARNESS_DIR/.state/cache" \
    -e XDG_CONFIG_HOME="$HARNESS_DIR/.state/config" \
    -e TERM=tmux-256color \
    -e COLORTERM=truecolor \
    "nvim --clean --noplugin -Nu '$HARNESS_DIR/init.lua'"

  for _ in {1..50}; do
    if [ -f "$ready" ]; then break; fi
    sleep 0.1
  done

  tmux -L "$sock" capture-pane -p -e > "$dump"
  tmux -L "$sock" kill-server

  if command -v freeze >/dev/null; then
    freeze "$dump" --output "$raw" --font.size 16
  else
    nix shell nixpkgs#charm-freeze --command freeze "$dump" --output "$raw" --font.size 16
  fi

  magick "$raw" -trim +repage \
    -background "#101216" -gravity north -splice 0x42 \
    -font DejaVu-Sans -fill "#d7dae0" -pointsize 26 -annotate +24+10 "$index  $title" \
    "$out"
  rm -f "$raw"
}

render_phase "before" "01" "before edit"
render_phase "selected" "02" "selection submitted"
render_phase "delete_flash" "03" "deleted tokens flash before edit"
render_phase "after_highlight" "04" "successful edit, changed tokens highlighted"
render_phase "after_cleared" "05" "highlight timeout elapsed"

echo "$SEQ_DIR"
