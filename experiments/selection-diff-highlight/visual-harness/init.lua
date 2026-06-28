local here = debug.getinfo(1, "S").source:sub(2)
local harness_dir = vim.fn.fnamemodify(here, ":p:h")
local repo = os.getenv("AVANTE_REPO")

if not repo or repo == "" then repo = vim.fn.fnamemodify(harness_dir, ":h:h:h") end

vim.opt.runtimepath:prepend(repo)
package.path = table.concat({
  repo .. "/lua/?.lua",
  repo .. "/lua/?/init.lua",
  package.path,
}, ";")

vim.o.termguicolors = true
vim.o.number = false
vim.o.relativenumber = false
vim.o.signcolumn = "no"
vim.o.laststatus = 0
vim.o.showtabline = 0
vim.o.ruler = false
vim.o.more = false
vim.o.showmode = false
vim.o.fillchars = "eob: "
vim.o.cmdheight = 0

vim.api.nvim_set_hl(0, "Normal", { fg = "#d7dae0", bg = "#101216" })
vim.api.nvim_set_hl(0, "Comment", { fg = "#737984", bg = "#101216" })
vim.api.nvim_set_hl(0, "String", { fg = "#a6d189", bg = "#101216" })
vim.api.nvim_set_hl(0, "Number", { fg = "#ef9f76", bg = "#101216" })
vim.api.nvim_set_hl(0, "Statement", { fg = "#8caaee", bg = "#101216" })
vim.api.nvim_set_hl(0, "Identifier", { fg = "#c6d0f5", bg = "#101216" })
vim.api.nvim_set_hl(0, "AvanteSelectionDiff", { fg = "#f4f1bb", bg = "#3d6137", bold = true })
vim.api.nvim_set_hl(0, "AvanteSelectionDiffDelete", { fg = "#ffd7d7", bg = "#562C30", bold = true })

local fixtures = dofile(harness_dir .. "/fixtures.lua")
local name = os.getenv("AVANTE_SELECTION_DIFF_FIXTURE")
if not name or name == "" then name = "word_swap" end
local phase = os.getenv("AVANTE_SELECTION_DIFF_PHASE")
if not phase or phase == "" then phase = "after_highlight" end

local fixture = fixtures[name]
if not fixture then error("unknown fixture: " .. name) end

local lines = {}
for _, line in ipairs(fixture.prefix or {}) do
  lines[#lines + 1] = line
end
local body = (phase == "before" or phase == "selected" or phase == "delete_flash") and fixture.before or fixture.after
for _, line in ipairs(body) do
  lines[#lines + 1] = line
end
for _, line in ipairs(fixture.suffix or {}) do
  lines[#lines + 1] = line
end

local buf = vim.api.nvim_get_current_buf()
vim.bo[buf].buftype = ""
vim.bo[buf].bufhidden = "wipe"
if fixture.filetype then vim.bo[buf].filetype = fixture.filetype end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
vim.cmd("syntax on")

if phase == "selected" then
  local end_lnum = fixture.start_lnum + #fixture.before - 1
  vim.api.nvim_buf_set_extmark(
    buf,
    vim.api.nvim_create_namespace("avante-selection-diff-harness"),
    fixture.start_lnum - 1,
    0,
    {
      end_row = end_lnum,
      end_col = 0,
      hl_group = "Visual",
      hl_eol = true,
      priority = (vim.hl or vim.highlight).priorities.user,
    }
  )
elseif phase == "after_highlight" then
  require("avante.selection_diff_highlight").show(buf, fixture.before, fixture.after, fixture.start_lnum, {
    timeout_ms = -1,
  })
elseif phase == "delete_flash" then
  require("avante.selection_diff_highlight").show_deletions(buf, fixture.before, fixture.after, fixture.start_lnum, {
    timeout_ms = -1,
  })
end

vim.api.nvim_win_set_cursor(0, { math.max(fixture.start_lnum - 2, 1), 0 })
vim.cmd("normal! zt")
vim.cmd("redraw")

local ready = os.getenv("AVANTE_SELECTION_DIFF_READY")
if ready and ready ~= "" then vim.fn.writefile({ "ready" }, ready) end
