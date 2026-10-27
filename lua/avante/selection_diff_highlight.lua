local api = vim.api

local Config = require("avante.config")
local Highlights = require("avante.highlights")

local M = {}

---@diagnostic disable-next-line: deprecated
local text_diff = vim.text and vim.text.diff or vim.diff

local NAMESPACE = api.nvim_create_namespace("avante-selection-diff-highlight")
local DELETE_NAMESPACE = api.nvim_create_namespace("avante-selection-diff-delete")
local PRIORITY = (vim.hl or vim.highlight).priorities.user
local INLINE_MAX_GROUPS = 2
local INLINE_MAX_EDIT_RATIO = 0.9

---@type table<integer, integer>
local generations = {}

---@class avante.SelectionDiffToken
---@field text string
---@field row integer 0-indexed buffer row
---@field start_col integer 0-indexed byte column
---@field end_col integer 0-indexed exclusive byte column

local function is_word_byte(byte)
  return (byte >= 48 and byte <= 57) or (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122) or byte == 95
end

local function is_space_byte(byte)
  return byte == 9 or byte == 10 or byte == 11 or byte == 12 or byte == 13 or byte == 32
end

local function resolve_bufnr(bufnr)
  if not bufnr or bufnr == 0 then return api.nvim_get_current_buf() end
  return bufnr
end

local function next_char_col(line, col)
  col = col + 1
  while col <= #line do
    local byte = line:byte(col)
    if byte < 128 or byte >= 192 then break end
    col = col + 1
  end
  return col
end

---@param opts? { timeout_ms?: integer }
---@return integer
local function timeout_from_opts(opts)
  if opts and opts.timeout_ms ~= nil then return opts.timeout_ms end
  return Config.selection.diff_highlight_timeout_ms
end

---@param opts? { transition_timeout_ms?: integer, added_timeout_ms?: integer }
---@return integer transition_timeout_ms
---@return integer added_timeout_ms
local function transition_timeouts_from_opts(opts)
  local transition_timeout_ms = opts and opts.transition_timeout_ms
  if transition_timeout_ms == nil then transition_timeout_ms = Config.selection.diff_highlight_timeout_ms or 100 end

  local added_timeout_ms = opts and opts.added_timeout_ms
  if added_timeout_ms == nil then added_timeout_ms = Config.selection.diff_highlight_added_timeout_ms or 500 end

  return transition_timeout_ms, added_timeout_ms
end

---@param lines string[]
---@param start_lnum integer 1-indexed
---@return avante.SelectionDiffToken[]
local function tokenize(lines, start_lnum)
  local tokens = {}

  for line_idx, line in ipairs(lines) do
    local col = 1
    local row = start_lnum + line_idx - 2

    while col <= #line do
      local byte = line:byte(col)

      if is_space_byte(byte) then
        col = col + 1
      elseif is_word_byte(byte) then
        local token_start = col
        repeat
          col = col + 1
          byte = line:byte(col)
        until byte == nil or not is_word_byte(byte)
        tokens[#tokens + 1] = {
          text = line:sub(token_start, col - 1),
          row = row,
          start_col = token_start - 1,
          end_col = col - 1,
        }
      else
        local next_col = next_char_col(line, col)
        tokens[#tokens + 1] = {
          text = line:sub(col, next_col - 1),
          row = row,
          start_col = col - 1,
          end_col = next_col - 1,
        }
        col = next_col
      end
    end
  end

  return tokens
end

---@param lines string[]
---@param start_lnum integer 1-indexed
---@return avante.SelectionDiffToken[]
local function tokenize_chars(lines, start_lnum)
  local tokens = {}

  for line_idx, line in ipairs(lines) do
    local row = start_lnum + line_idx - 2

    local col = 1
    while col <= #line do
      local next_col = next_char_col(line, col)
      tokens[#tokens + 1] = {
        text = line:sub(col, next_col - 1),
        row = row,
        start_col = col - 1,
        end_col = next_col - 1,
      }
      col = next_col
    end
  end

  return tokens
end

---@param tokens avante.SelectionDiffToken[]
---@return avante.SelectionDiffToken[]
local function merge_adjacent_tokens(tokens)
  local merged = {}

  for _, token in ipairs(tokens) do
    local prev = merged[#merged]
    if prev and prev.row == token.row and prev.end_col == token.start_col then
      prev.text = prev.text .. token.text
      prev.end_col = token.end_col
    else
      merged[#merged + 1] = {
        text = token.text,
        row = token.row,
        start_col = token.start_col,
        end_col = token.end_col,
      }
    end
  end

  return merged
end

---@param tokens avante.SelectionDiffToken[]
---@return string
local function tokens_to_diff_text(tokens)
  local lines = {}
  for idx, token in ipairs(tokens) do
    lines[idx] = token.text .. "\n"
  end
  return table.concat(lines)
end

---@param namespace integer
---@param bufnr integer
---@param token avante.SelectionDiffToken
---@param hl_group string
local function add_highlight(namespace, bufnr, token, hl_group)
  api.nvim_buf_set_extmark(bufnr, namespace, token.row, token.start_col, {
    end_row = token.row,
    end_col = token.end_col,
    hl_group = hl_group,
    hl_mode = "combine",
    priority = PRIORITY,
  })
end

---@param tokens avante.SelectionDiffToken[]
---@param start_idx integer
---@param count integer
---@return string
local function concat_tokens(tokens, start_idx, count)
  local parts = {}
  for idx = start_idx, start_idx + count - 1 do
    if tokens[idx] then parts[#parts + 1] = tokens[idx].text end
  end
  return table.concat(parts)
end

---@param old_line string
---@param new_line string
---@return { text: string, col: integer }[]
---@return integer edit_count
local function deleted_inline_groups(old_line, new_line)
  local old_tokens = tokenize_chars({ old_line }, 1)
  if #old_tokens == 0 then return {}, 0 end

  local new_tokens = tokenize_chars({ new_line }, 1)
  ---@diagnostic disable-next-line: assign-type-mismatch
  local patch = text_diff( ---@type integer[][]
    tokens_to_diff_text(old_tokens),
    tokens_to_diff_text(new_tokens),
    ---@diagnostic disable-next-line: missing-fields
    { algorithm = "histogram", result_type = "indices", ctxlen = 0 }
  )

  local groups = {}
  local edit_count = 0
  for _, hunk in ipairs(patch or {}) do
    local start_a, count_a, start_b, count_b = unpack(hunk)
    edit_count = edit_count + count_a + count_b
    if count_a > 0 then
      local col = 0
      if count_b > 0 and new_tokens[start_b] then
        col = new_tokens[start_b].start_col
      elseif start_b > 0 and new_tokens[start_b] then
        col = new_tokens[start_b].end_col
      end
      groups[#groups + 1] = { text = concat_tokens(old_tokens, start_a, count_a), col = col }
    end
  end
  return groups, edit_count
end

---@param groups table[]
---@param edit_count integer
---@param old_line string
---@param new_line string
---@return boolean
local function inline_ok(groups, edit_count, old_line, new_line)
  if #groups == 0 or #groups > INLINE_MAX_GROUPS then return false end
  local length = math.max(vim.fn.strchars(old_line), vim.fn.strchars(new_line), 1)
  return edit_count / length <= INLINE_MAX_EDIT_RATIO
end

---@param bufnr integer
---@param row integer
---@param line string
local function add_deleted_virtual_line(bufnr, row, line)
  api.nvim_buf_set_extmark(bufnr, DELETE_NAMESPACE, row, 0, {
    virt_lines = { { { line == "" and " " or line, Highlights.SELECTION_DIFF_DELETE } } },
    virt_lines_above = true,
    priority = PRIORITY,
  })
end

---@param bufnr integer
---@param old_lines string[]
---@param new_lines string[]
---@param start_lnum integer
local function show_deleted_virtual_text(bufnr, old_lines, new_lines, start_lnum)
  ---@diagnostic disable-next-line: assign-type-mismatch
  local hunks = text_diff( ---@type integer[][]
    #old_lines > 0 and table.concat(old_lines, "\n") .. "\n" or "",
    #new_lines > 0 and table.concat(new_lines, "\n") .. "\n" or "",
    ---@diagnostic disable-next-line: missing-fields
    { algorithm = "histogram", result_type = "indices", ctxlen = 0 }
  )

  for _, hunk in ipairs(hunks or {}) do
    local start_a, count_a, start_b, count_b = unpack(hunk)
    local available_old = math.max(#old_lines - start_a + 1, 0)
    local available_new = math.max(#new_lines - start_b + 1, 0)
    local paired_count = math.min(count_a, count_b, available_old, available_new)

    for offset = 0, paired_count - 1 do
      local row = start_lnum + start_b + offset - 2
      local old_line = old_lines[start_a + offset]
      local new_line = new_lines[start_b + offset]
      local groups, edit_count = deleted_inline_groups(old_line, new_line)
      if inline_ok(groups, edit_count, old_line, new_line) then
        for _, group in ipairs(groups) do
          if group.text ~= "" then
            api.nvim_buf_set_extmark(bufnr, DELETE_NAMESPACE, row, group.col, {
              virt_text = { { group.text, Highlights.SELECTION_DIFF_DELETE } },
              virt_text_pos = "inline",
              priority = PRIORITY,
            })
          end
        end
      elseif #groups > 0 then
        add_deleted_virtual_line(bufnr, row, old_line)
      end
    end

    if count_a > paired_count then
      local virt_lines = {}
      for idx = start_a + paired_count, start_a + count_a - 1 do
        local line = old_lines[idx] or ""
        virt_lines[#virt_lines + 1] = { { line == "" and " " or line, Highlights.SELECTION_DIFF_DELETE } }
      end

      local line_count = api.nvim_buf_line_count(bufnr)
      -- A deletion's start_b is the preceding line; a replacement's is the
      -- first replacement line. Anchor above the following line, or below EOF.
      local next_row = start_lnum - 1 + start_b + paired_count - (count_b > 0 and 1 or 0)
      local anchor_row = math.min(next_row, line_count - 1)
      api.nvim_buf_set_extmark(bufnr, DELETE_NAMESPACE, anchor_row, 0, {
        virt_lines = virt_lines,
        virt_lines_above = next_row < line_count,
        priority = PRIORITY,
      })
    end
  end
end

---@param old_tokens avante.SelectionDiffToken[]
---@param new_tokens avante.SelectionDiffToken[]
---@return avante.SelectionDiffToken[]
function M.changed_tokens(old_tokens, new_tokens)
  if #new_tokens == 0 then return {} end
  if #old_tokens == 0 then return new_tokens end

  ---@diagnostic disable-next-line: assign-type-mismatch
  local patch = text_diff( ---@type integer[][]
    tokens_to_diff_text(old_tokens),
    tokens_to_diff_text(new_tokens),
    ---@diagnostic disable-next-line: missing-fields
    { algorithm = "histogram", result_type = "indices", ctxlen = 0 }
  )
  if not patch then return {} end

  local changed = {}
  for _, hunk in ipairs(patch) do
    local _, _, start_b, count_b = unpack(hunk)
    for idx = start_b, start_b + count_b - 1 do
      if new_tokens[idx] then changed[#changed + 1] = new_tokens[idx] end
    end
  end
  return changed
end

---@param old_lines string[]
---@param new_lines string[]
---@param start_lnum integer 1-indexed
---@return avante.SelectionDiffToken[]
function M.deleted_ranges(old_lines, new_lines, start_lnum)
  local old_tokens = tokenize_chars(old_lines, start_lnum)
  if #old_tokens == 0 then return {} end

  local new_tokens = tokenize_chars(new_lines, 1)
  return merge_adjacent_tokens(M.changed_tokens(new_tokens, old_tokens))
end

---@param old_lines string[]
---@param new_lines string[]
---@param start_lnum integer 1-indexed
---@return avante.SelectionDiffToken[]
local function inserted_ranges(old_lines, new_lines, start_lnum)
  local new_tokens = tokenize_chars(new_lines, start_lnum)
  if #new_tokens == 0 then return {} end

  local old_tokens = tokenize_chars(old_lines, 1)
  return merge_adjacent_tokens(M.changed_tokens(old_tokens, new_tokens))
end

---@param bufnr integer?
function M.clear(bufnr)
  bufnr = resolve_bufnr(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then return end
  generations[bufnr] = (generations[bufnr] or 0) + 1
  api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
  api.nvim_buf_clear_namespace(bufnr, DELETE_NAMESPACE, 0, -1)
end

---@param bufnr integer
---@param old_lines string[]
---@param new_lines string[]
---@param start_lnum integer 1-indexed
---@param opts? { timeout_ms?: integer }
function M.show(bufnr, old_lines, new_lines, start_lnum, opts)
  bufnr = resolve_bufnr(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then return end

  local timeout_ms = timeout_from_opts(opts)
  M.clear(bufnr)
  if timeout_ms == 0 then return end

  local generation = generations[bufnr]
  if #inserted_ranges(old_lines, new_lines, start_lnum) == 0 then return end

  local changed = M.changed_tokens(tokenize(old_lines, 1), tokenize(new_lines, start_lnum))
  for _, token in ipairs(changed) do
    add_highlight(NAMESPACE, bufnr, token, Highlights.SELECTION_DIFF)
  end

  if #changed > 0 and timeout_ms and timeout_ms > 0 then
    vim.defer_fn(function()
      if api.nvim_buf_is_valid(bufnr) and generations[bufnr] == generation then M.clear(bufnr) end
    end, timeout_ms)
  end
end

---Show an already-applied edit in two stages. The buffer stays in its after state:
---deleted text is temporarily restored as red virtual text while inserted characters are
---green, then only the green insertion highlights remain.
---@param bufnr integer
---@param old_lines string[]
---@param new_lines string[]
---@param start_lnum integer 1-indexed
---@param opts? { transition_timeout_ms?: integer, added_timeout_ms?: integer }
function M.show_transition(bufnr, old_lines, new_lines, start_lnum, opts)
  bufnr = resolve_bufnr(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then return end

  local transition_timeout_ms, added_timeout_ms = transition_timeouts_from_opts(opts)
  M.clear(bufnr)
  if transition_timeout_ms == 0 and added_timeout_ms == 0 then return end
  local generation = generations[bufnr]

  local inserted = inserted_ranges(old_lines, new_lines, start_lnum)
  for _, token in ipairs(inserted) do
    add_highlight(NAMESPACE, bufnr, token, Highlights.SELECTION_DIFF)
  end
  if transition_timeout_ms ~= 0 then show_deleted_virtual_text(bufnr, old_lines, new_lines, start_lnum) end

  local function clear_added_after_timeout()
    if added_timeout_ms == 0 then
      api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
    elseif added_timeout_ms > 0 then
      vim.defer_fn(function()
        if not api.nvim_buf_is_valid(bufnr) or generations[bufnr] ~= generation then return end
        api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
      end, added_timeout_ms)
    end
  end

  if transition_timeout_ms > 0 then
    vim.defer_fn(function()
      if not api.nvim_buf_is_valid(bufnr) or generations[bufnr] ~= generation then return end
      api.nvim_buf_clear_namespace(bufnr, DELETE_NAMESPACE, 0, -1)
      clear_added_after_timeout()
    end, transition_timeout_ms)
  elseif transition_timeout_ms == 0 then
    clear_added_after_timeout()
  end
end

---@param bufnr integer
---@param old_lines string[]
---@param new_lines string[]
---@param start_lnum integer 1-indexed
---@param opts? { timeout_ms?: integer }
---@return integer count
function M.show_deletions(bufnr, old_lines, new_lines, start_lnum, opts)
  bufnr = resolve_bufnr(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then return 0 end

  local timeout_ms = timeout_from_opts(opts)
  M.clear(bufnr)
  if timeout_ms == 0 then return 0 end

  local deleted = M.deleted_ranges(old_lines, new_lines, start_lnum)
  if #deleted == 0 then return 0 end

  local generation = generations[bufnr]
  for _, token in ipairs(deleted) do
    add_highlight(DELETE_NAMESPACE, bufnr, token, Highlights.SELECTION_DIFF_DELETE)
  end

  if timeout_ms > 0 then
    vim.defer_fn(function()
      if api.nvim_buf_is_valid(bufnr) and generations[bufnr] == generation then M.clear(bufnr) end
    end, timeout_ms)
  end

  return #deleted
end

---@param bufnr integer
---@param old_lines string[]
---@param new_lines string[]
---@param start_lnum integer 1-indexed
---@param callback fun()
---@param opts? { timeout_ms?: integer }
---@return boolean delayed
function M.flash_deletions_before(bufnr, old_lines, new_lines, start_lnum, callback, opts)
  bufnr = resolve_bufnr(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then return false end

  local timeout_ms = timeout_from_opts(opts)
  if timeout_ms <= 0 then return false end

  local deleted = M.deleted_ranges(old_lines, new_lines, start_lnum)
  if #deleted == 0 then return false end

  M.clear(bufnr)
  local generation = generations[bufnr]
  for _, token in ipairs(deleted) do
    add_highlight(DELETE_NAMESPACE, bufnr, token, Highlights.SELECTION_DIFF_DELETE)
  end

  vim.defer_fn(function()
    if generations[bufnr] == generation then M.clear(bufnr) end
    if api.nvim_buf_is_valid(bufnr) then callback() end
  end, timeout_ms)

  return true
end

M._tokenize = tokenize
M._tokenize_chars = tokenize_chars
M._namespace = NAMESPACE
M._delete_namespace = DELETE_NAMESPACE

return M
