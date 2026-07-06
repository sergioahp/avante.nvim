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
---@field inline_marks integer[]|nil extmarks carrying inline replacement spans
---@field old_count integer buffer lines this hunk replaces (0 = pure insertion)
---@field new_lines string[] replacement / inserted lines
---@field insert_above boolean insertion lands above the anchor row (top-of-file case)

---@class avante.PendingState
---@field hunks avante.PendingHunk[]

---@type table<integer, avante.PendingState>
local state = {}

local INLINE_MAX_GROUPS = 2
local INLINE_MAX_EDIT_RATIO = 0.9
local NEG_INF = -1000000000

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
  for _, mark in ipairs(hunk.inline_marks or {}) do
    api.nvim_buf_del_extmark(bufnr, NS, mark)
  end
end

---@param text string
---@param i integer 1-based byte index
---@return integer
local function utf8_char_len(text, i)
  local b = text:byte(i) or 0
  if b < 0x80 then
    return 1
  elseif b < 0xe0 then
    return 2
  elseif b < 0xf0 then
    return 3
  end
  return 4
end

---@param text string
---@return { text: string, start_col: integer, end_col: integer }[]
local function codepoint_tokens(text)
  local tokens = {}
  local i = 1
  while i <= #text do
    local len = utf8_char_len(text, i)
    tokens[#tokens + 1] = {
      text = text:sub(i, i + len - 1),
      start_col = i - 1,
      end_col = i + len - 1,
    }
    i = i + len
  end
  return tokens
end

local function vget(v, k)
  local value = v[k]
  if value == nil then return NEG_INF end
  return value
end

local function copy_v(v)
  local out = {}
  for k, value in pairs(v) do
    out[k] = value
  end
  return out
end

---@param old_tokens { text: string }[]
---@param new_tokens { text: string }[]
---@return { kind: '"equal"'|'"delete"'|'"insert"', old_idx?: integer, new_idx?: integer }[]
local function myers(old_tokens, new_tokens)
  local n, m = #old_tokens, #new_tokens
  if n == 0 then
    local ops = {}
    for j = 1, m do
      ops[#ops + 1] = { kind = "insert", new_idx = j }
    end
    return ops
  elseif m == 0 then
    local ops = {}
    for i = 1, n do
      ops[#ops + 1] = { kind = "delete", old_idx = i }
    end
    return ops
  end

  local trace = {}
  local v = { [1] = 0 }
  local found_d

  for d = 0, n + m do
    for k = -d, d, 2 do
      local x
      if k == -d or (k ~= d and vget(v, k - 1) < vget(v, k + 1)) then
        x = vget(v, k + 1)
      else
        x = vget(v, k - 1) + 1
      end
      if x < 0 then x = 0 end
      local y = x - k
      while x < n and y < m and old_tokens[x + 1].text == new_tokens[y + 1].text do
        x = x + 1
        y = y + 1
      end
      v[k] = x
      if x >= n and y >= m then
        trace[d] = copy_v(v)
        found_d = d
        break
      end
    end
    trace[d] = trace[d] or copy_v(v)
    if found_d then break end
  end

  local ops = {}
  local x, y = n, m
  for d = found_d or (n + m), 1, -1 do
    local k = x - y
    local prev_v = trace[d - 1] or {}
    local prev_k
    if k == -d or (k ~= d and vget(prev_v, k - 1) < vget(prev_v, k + 1)) then
      prev_k = k + 1
    else
      prev_k = k - 1
    end
    local prev_x = math.max(0, vget(prev_v, prev_k))
    local prev_y = prev_x - prev_k

    while x > prev_x and y > prev_y do
      table.insert(ops, 1, { kind = "equal", old_idx = x, new_idx = y })
      x = x - 1
      y = y - 1
    end

    if x == prev_x then
      table.insert(ops, 1, { kind = "insert", new_idx = y })
      y = y - 1
    else
      table.insert(ops, 1, { kind = "delete", old_idx = x })
      x = x - 1
    end
  end

  while x > 0 and y > 0 do
    table.insert(ops, 1, { kind = "equal", old_idx = x, new_idx = y })
    x = x - 1
    y = y - 1
  end
  while x > 0 do
    table.insert(ops, 1, { kind = "delete", old_idx = x })
    x = x - 1
  end
  while y > 0 do
    table.insert(ops, 1, { kind = "insert", new_idx = y })
    y = y - 1
  end

  return ops
end

---@param tokens { text: string }[]
---@param indices integer[]
---@return string
local function concat_token_indices(tokens, indices)
  local parts = {}
  for _, idx in ipairs(indices) do
    parts[#parts + 1] = tokens[idx].text
  end
  return table.concat(parts)
end

---@param line string
---@param start_col integer?
---@param end_col integer?
---@return string
local function byte_slice(line, start_col, end_col)
  if not start_col or not end_col or end_col <= start_col then return "" end
  return line:sub(start_col + 1, end_col)
end

---@param old_tokens { start_col: integer, end_col: integer }[]
---@param old_indices integer[]
---@param fallback_col integer
---@return integer
local function insert_col(old_tokens, old_indices, fallback_col)
  local first = old_indices[1]
  if first and old_tokens[first] then return old_tokens[first].start_col end
  return fallback_col
end

---@param old_line string
---@param new_line string
---@return { old_text: string, new_text: string, old_start_col: integer?, old_end_col: integer?, new_start_col: integer?, new_end_col: integer?, insert_col: integer }[] groups
---@return integer edit_count
local function text_groups(old_line, new_line)
  local old_tokens = codepoint_tokens(old_line)
  local new_tokens = codepoint_tokens(new_line)
  local ops = myers(old_tokens, new_tokens)
  local groups = {}
  local edit_count = 0
  local old_run, new_run = {}, {}
  local last_old_col = 0

  local function flush()
    if #old_run == 0 and #new_run == 0 then return end
    local old_first = old_run[1]
    local old_last = old_run[#old_run]
    local new_first = new_run[1]
    local new_last = new_run[#new_run]
    local old_start_col = old_first and old_tokens[old_first].start_col or nil
    local old_end_col = old_last and old_tokens[old_last].end_col or nil
    local new_start_col = new_first and new_tokens[new_first].start_col or nil
    local new_end_col = new_last and new_tokens[new_last].end_col or nil

    groups[#groups + 1] = {
      old_text = concat_token_indices(old_tokens, old_run),
      new_text = concat_token_indices(new_tokens, new_run),
      old_start_col = old_start_col,
      old_end_col = old_end_col,
      new_start_col = new_start_col,
      new_end_col = new_end_col,
      insert_col = insert_col(old_tokens, old_run, last_old_col),
    }
    old_run, new_run = {}, {}
  end

  for _, op in ipairs(ops) do
    if op.kind == "equal" then
      flush()
      last_old_col = old_tokens[op.old_idx].end_col
    elseif op.kind == "delete" then
      edit_count = edit_count + 1
      old_run[#old_run + 1] = op.old_idx
    elseif op.kind == "insert" then
      edit_count = edit_count + 1
      new_run[#new_run + 1] = op.new_idx
    end
  end
  flush()

  local coalesced = {}
  for _, group in ipairs(groups) do
    local last = coalesced[#coalesced]
    local last_old_end = last and (last.old_end_col or last.insert_col) or nil
    local group_old_start = group.old_start_col or group.insert_col
    local old_gap = last_old_end and (group_old_start - last_old_end) or nil
    if last and old_gap and old_gap >= 0 and old_gap <= 1 then
      local old_start = last.old_start_col or last.insert_col
      local old_end = group.old_end_col or group.insert_col
      local new_start = last.new_start_col or group.new_start_col
      local new_end = group.new_end_col or last.new_end_col
      if not group.new_end_col and last.new_end_col then
        new_end = last.new_end_col + old_gap
      elseif not last.new_start_col and group.new_start_col then
        new_start = math.max(0, group.new_start_col - old_gap)
      end
      last.old_start_col = old_start
      last.old_end_col = old_end > old_start and old_end or nil
      last.new_start_col = new_start
      last.new_end_col = new_start and new_end and new_end > new_start and new_end or nil
      last.insert_col = old_start
      last.old_text = byte_slice(old_line, last.old_start_col, last.old_end_col)
      last.new_text = byte_slice(new_line, last.new_start_col, last.new_end_col)
    else
      coalesced[#coalesced + 1] = vim.deepcopy(group)
    end
  end

  return coalesced, edit_count
end

---@param groups table[]
---@param edit_count integer
---@param old_line string
---@param new_line string
---@return boolean
local function inline_ok(groups, edit_count, old_line, new_line)
  if #groups == 0 or #groups > INLINE_MAX_GROUPS then return false end
  local denom = math.max(vim.fn.strchars(old_line), vim.fn.strchars(new_line), 1)
  return (edit_count / denom) <= INLINE_MAX_EDIT_RATIO
end

---@param old_lines string[]
---@param new_lines string[]
---@return table[]|nil
local function inline_groups_for_replacement(old_lines, new_lines)
  if #old_lines == 0 or #old_lines ~= #new_lines then return nil end
  local per_line = {}
  for i, old_line in ipairs(old_lines) do
    local new_line = new_lines[i]
    if old_line ~= new_line then
      local groups, edit_count = text_groups(old_line, new_line)
      if not inline_ok(groups, edit_count, old_line, new_line) then return nil end
      per_line[i] = groups
    else
      per_line[i] = {}
    end
  end
  return per_line
end

---@param bufnr integer
---@param hunk avante.PendingHunk
---@param del_start integer
---@param inline_groups table[]
local function render_inline_replacement(bufnr, hunk, del_start, inline_groups)
  hunk.mark = api.nvim_buf_set_extmark(bufnr, NS, del_start, 0, { priority = 200 })
  hunk.inline_marks = {}

  for offset, groups in ipairs(inline_groups) do
    local row = del_start + offset - 1
    for _, group in ipairs(groups) do
      if group.old_start_col and group.old_end_col and group.old_end_col > group.old_start_col then
        hunk.inline_marks[#hunk.inline_marks + 1] = api.nvim_buf_set_extmark(bufnr, NS, row, group.old_start_col, {
          end_col = group.old_end_col,
          hl_group = DEL_HL,
          hl_mode = "combine",
          priority = 200,
        })
      end
      if group.new_text ~= "" then
        hunk.inline_marks[#hunk.inline_marks + 1] =
          api.nvim_buf_set_extmark(bufnr, NS, row, group.old_end_col or group.insert_col, {
            virt_text = { { group.new_text, ADD_HL } },
            virt_text_pos = "inline",
            priority = 200,
          })
      end
    end
  end
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

    local old_lines = {}
    for i = start_a, start_a + count_a - 1 do
      old_lines[#old_lines + 1] = original_lines[i]
    end

    local inline_groups = nil
    if count_a > 0 and count_b > 0 then inline_groups = inline_groups_for_replacement(old_lines, new_lines) end

    if inline_groups then
      render_inline_replacement(bufnr, hunk, start_a - 1, inline_groups)
    elseif count_a > 0 then
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
