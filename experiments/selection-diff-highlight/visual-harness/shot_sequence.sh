#!/usr/bin/env bash
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HARNESS_DIR/../../.." && pwd)"
FIXTURE="${1:-word_swap}"
STAMP="$(date +%Y-%m-%d_%H-%M-%S)"
SEQ_DIR="$HARNESS_DIR/sequences/${FIXTURE}_${STAMP}"

mkdir -p "$SEQ_DIR" "$HARNESS_DIR/.state"

FRAME_CONTENTS=()
FRAME_OUTPUTS=()
FRAME_TITLES=()

render_phase() {
  local phase="$1"
  local index="$2"
  local title="$3"
  local conf="$HARNESS_DIR/.state/tmux_${FIXTURE}_${phase}_${STAMP}.conf"
  local dump="$HARNESS_DIR/.state/${FIXTURE}_${phase}_${STAMP}.ansi"
  local ready="$HARNESS_DIR/.state/${FIXTURE}_${phase}_${STAMP}.ready"
  local raw="$SEQ_DIR/${index}_${phase}.raw.png"
  local content="$SEQ_DIR/.${index}_${phase}.content.png"
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

  magick "$raw" -trim +repage "$content"
  rm -f "$raw"

  FRAME_CONTENTS+=("$content")
  FRAME_OUTPUTS+=("$out")
  FRAME_TITLES+=("$index  $title")
}

finalize_sequence() {
  local max_width=0
  local max_height=0
  local width
  local height
  local i

  for content in "${FRAME_CONTENTS[@]}"; do
    read -r width height < <(identify -format '%w %h\n' "$content")
    if ((width > max_width)); then max_width=$width; fi
    if ((height > max_height)); then max_height=$height; fi
  done

  for i in "${!FRAME_CONTENTS[@]}"; do
    magick "${FRAME_CONTENTS[$i]}" \
      -background "#101216" -gravity northwest -extent "${max_width}x${max_height}" \
      -bordercolor "#101216" -border 48x32 \
      -gravity north -splice 0x48 \
      -gravity northwest -font DejaVu-Sans -fill "#d7dae0" -pointsize 26 -annotate +48+10 "${FRAME_TITLES[$i]}" \
      "${FRAME_OUTPUTS[$i]}"
    rm -f "${FRAME_CONTENTS[$i]}"
  done
}

render_phase "before" "01" "before edit"
render_phase "selected" "02" "selection submitted"
render_phase "combined" "03" "after state + virtual before diff"
render_phase "added" "04" "virtual text cleared; additions remain"
render_phase "after_cleared" "05" "highlight timeout elapsed"
finalize_sequence

echo "$SEQ_DIR"
