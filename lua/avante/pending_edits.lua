local api = vim.api

---Pending-edit overlay for the fast chat path. A Morph merge produces a whole new
---version of the buffer; instead of writing it (which would mutate buffer bytes and
---break per-keystroke compile / syntax-highlight pipelines) we render the diff as
---virtual text: removed lines are highlighted in place, added lines hang below as
---`virt_lines`. Buffer bytes change only when a hunk is accepted. Everything here is
---current-buffer scoped and anchored on extmarks, so hunks track edits and can be
---accepted in any order.
---@class avante.PendingEdits
local M = {}

local NS = api.nvim_create_namespace("avante_pending_edits")

-- Reuse the selection-edit diff colors: green for additions, dark red for removals.
local ADD_HL = "AvanteSelectionDiff"
local DEL_HL = "AvanteToBeDeletedWOStrikethrough"

---@class avante.PendingHunk
---@field mark integer primary extmark, tracks the hunk's start row
---@field add_mark integer|nil extmark carrying the added lines as virt_lines
---@field old_count integer buffer lines this hunk replaces (0 = pure insertion)
---@field new_lines string[] replacement / inserted lines
---@field insert_above boolean insertion lands above the anchor row (top-of-file case)

---@class avante.PendingState
---@field hunks avante.PendingHunk[]

---@type table<integer, avante.PendingState>
local state = {}

---@param bufnr? integer
---@return integer
local function resolve(bufnr)
  if bufnr == nil or bufnr == 0 then return api.nvim_get_current_buf() end
  return bufnr
end

---Current 0-indexed start row of a hunk, read live from its extmark.
---@param bufnr integer
---@param hunk avante.PendingHunk
---@return integer|nil
local function hunk_row(bufnr, hunk)
  local pos = api.nvim_buf_get_extmark_by_id(bufnr, NS, hunk.mark, {})
  if not pos or pos[1] == nil then return nil end
  return pos[1]
end

---@param bufnr integer
---@param hunk avante.PendingHunk
local function clear_hunk(bufnr, hunk)
  if not api.nvim_buf_is_valid(bufnr) then return end
  api.nvim_buf_del_extmark(bufnr, NS, hunk.mark)
  if hunk.add_mark then api.nvim_buf_del_extmark(bufnr, NS, hunk.add_mark) end
end

---Render the diff between `original_lines` (the buffer as the merge saw it) and
---`merged_lines` (Morph's output) as a pending-edit overlay. Replaces any existing
---overlay on the buffer.
---@param bufnr integer
---@param original_lines string[]
---@param merged_lines string[]
---@return integer hunk_count
function M.set(bufnr, original_lines, merged_lines)
  bufnr = resolve(bufnr)
  M.dismiss_all(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then return 0 end

  local hunks = vim.diff(
    table.concat(original_lines, "\n") .. "\n",
    table.concat(merged_lines, "\n") .. "\n",
    { result_type = "indices", algorithm = "histogram" }
  )
  if not hunks or #hunks == 0 then return 0 end

  local st = { hunks = {} }
  for _, h in ipairs(hunks) do
    local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]

    local new_lines = {}
    for i = start_b, start_b + count_b - 1 do
      new_lines[#new_lines + 1] = merged_lines[i]
    end

    local virt_lines = nil
    if count_b > 0 then
      virt_lines = {}
      for _, line in ipairs(new_lines) do
        -- An empty virt_line collapses to nothing, so pad it so the added blank
        -- line is still visible as a green strip.
        virt_lines[#virt_lines + 1] = { { line == "" and " " or line, ADD_HL } }
      end
    end

    local hunk = { old_count = count_a, new_lines = new_lines, insert_above = false }

    if count_a > 0 then
      -- Replacement or deletion: highlight the removed buffer lines in place.
      local del_start = start_a - 1
      hunk.mark = api.nvim_buf_set_extmark(bufnr, NS, del_start, 0, {
        end_row = del_start + count_a,
        end_col = 0,
        hl_group = DEL_HL,
        hl_eol = true,
        hl_mode = "combine",
        priority = 200,
      })
      if virt_lines then
        -- Added lines hang below the last removed line.
        hunk.add_mark = api.nvim_buf_set_extmark(bufnr, NS, del_start + count_a - 1, 0, {
          virt_lines = virt_lines,
          virt_lines_above = false,
          priority = 200,
        })
      end
    else
      -- Pure insertion. vim.diff gives start_a = the line (1-indexed) the insertion
      -- follows; 0 means before the first line.
      if start_a == 0 then
        hunk.insert_above = true
        hunk.mark = api.nvim_buf_set_extmark(bufnr, NS, 0, 0, {
          virt_lines = virt_lines,
          virt_lines_above = true,
          priority = 200,
        })
      else
        hunk.mark = api.nvim_buf_set_extmark(bufnr, NS, start_a - 1, 0, {
          virt_lines = virt_lines,
          virt_lines_above = false,
          priority = 200,
        })
      end
    end

    st.hunks[#st.hunks + 1] = hunk
  end

  state[bufnr] = st
  return #st.hunks
end

---@param bufnr? integer
---@return boolean
function M.has_pending(bufnr)
  bufnr = resolve(bufnr)
  local st = state[bufnr]
  return st ~= nil and #st.hunks > 0
end

---@param bufnr integer
---@param idx integer index into state[bufnr].hunks
local function apply_hunk(bufnr, idx)
  local st = state[bufnr]
  if not st then return end
  local hunk = st.hunks[idx]
  if not hunk then return end
  local row = hunk_row(bufnr, hunk)
  if row ~= nil and api.nvim_buf_is_valid(bufnr) then
    if hunk.old_count > 0 then
      api.nvim_buf_set_lines(bufnr, row, row + hunk.old_count, false, hunk.new_lines)
    else
      local at = hunk.insert_above and row or row + 1
      api.nvim_buf_set_lines(bufnr, at, at, false, hunk.new_lines)
    end
  end
  clear_hunk(bufnr, hunk)
  table.remove(st.hunks, idx)
  if #st.hunks == 0 then state[bufnr] = nil end
end

---0-indexed hunk index under the cursor, or nil.
---@param bufnr integer
---@return integer|nil
local function hunk_under_cursor(bufnr)
  local st = state[bufnr]
  if not st then return nil end
  local cur = api.nvim_win_get_cursor(0)[1] - 1
  for i, hunk in ipairs(st.hunks) do
    local row = hunk_row(bufnr, hunk)
    if row ~= nil then
      if hunk.old_count > 0 then
        if cur >= row and cur < row + hunk.old_count then return i end
      else
        if cur == row then return i end
      end
    end
  end
  return nil
end

---Accept the hunk under the cursor; if none, jump to the next pending hunk
---(wrapping). Mirrors minuet's duet `accept_or_next`.
---@param bufnr? integer
---@return boolean acted true if a hunk was accepted or the cursor moved
function M.accept_or_next(bufnr)
  bufnr = resolve(bufnr)
  if not M.has_pending(bufnr) then return false end

  local idx = hunk_under_cursor(bufnr)
  if idx then
    apply_hunk(bufnr, idx)
    return true
  end

  -- Jump to the first hunk below the cursor, else wrap to the first overall.
  local st = state[bufnr]
  local cur = api.nvim_win_get_cursor(0)[1] - 1
  local rows = {}
  for _, hunk in ipairs(st.hunks) do
    local row = hunk_row(bufnr, hunk)
    if row ~= nil then rows[#rows + 1] = row end
  end
  if #rows == 0 then return false end
  table.sort(rows)
  local target = rows[1]
  for _, row in ipairs(rows) do
    if row > cur then
      target = row
      break
    end
  end
  api.nvim_win_set_cursor(0, { target + 1, 0 })
  return true
end

---Reject (discard) the hunk under the cursor without touching buffer bytes.
---@param bufnr? integer
---@return boolean
function M.reject_under_cursor(bufnr)
  bufnr = resolve(bufnr)
  local idx = hunk_under_cursor(bufnr)
  if not idx then return false end
  local st = state[bufnr]
  clear_hunk(bufnr, st.hunks[idx])
  table.remove(st.hunks, idx)
  if #st.hunks == 0 then state[bufnr] = nil end
  return true
end

---Accept every pending hunk.
---@param bufnr? integer
---@return boolean
function M.accept_all(bufnr)
  bufnr = resolve(bufnr)
  local st = state[bufnr]
  if not st or #st.hunks == 0 then return false end
  -- Each apply reads live extmark positions, so consuming from the front is safe.
  while st.hunks[1] do
    apply_hunk(bufnr, 1)
  end
  return true
end

---Discard the whole overlay (no buffer change). Wire this to BufEnter or a key.
---@param bufnr? integer
function M.dismiss_all(bufnr)
  bufnr = resolve(bufnr)
  if api.nvim_buf_is_valid(bufnr) then api.nvim_buf_clear_namespace(bufnr, NS, 0, -1) end
  state[bufnr] = nil
end

return M
