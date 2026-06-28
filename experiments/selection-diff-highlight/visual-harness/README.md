# Selection Diff Highlight Visual Harness

This renders synthetic before/after selection edits through
`avante.selection_diff_highlight`, then captures the real Neovim terminal output
as a PNG. No model call or API key is needed.

```bash
cd experiments/selection-diff-highlight/visual-harness
nix shell nixpkgs#tmux nixpkgs#charm-freeze nixpkgs#imagemagick nixpkgs#neovim -c bash shot_tmux.sh word_swap
```

The output path is printed at the end and includes the fixture name plus a
timestamp, for example:

```text
out/word_swap_2026-06-20_15-30-42.tmux.png
```

Fixtures live in `fixtures.lua`. Each fixture provides `before`, `after`, and a
1-indexed `start_lnum`, so the harness can place extmarks on the final buffer at
the same rows a real selection edit would occupy.
