local api = vim.api

local Config = require("avante.config")
local Highlights = require("avante.highlights")

local M = {}

local NAMESPACE = api.nvim_create_namespace("avante-selection-diff-highlight")
local PRIORITY = (vim.hl or vim.highlight).priorities.user

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

---@param opts? { timeout_ms?: integer }
---@return integer
local function timeout_from_opts(opts)
  if opts and opts.timeout_ms ~= nil then return opts.timeout_ms end
  return Config.selection.diff_highlight_timeout_ms
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
        tokens[#tokens + 1] = {
          text = line:sub(col, col),
          row = row,
          start_col = col - 1,
          end_col = col,
        }
        col = col + 1
      end
    end
  end

  return tokens
end

---@param lines string[]
---@param start_lnum integer 1-indexed
---@return avante.SelectionDiffToken[]
local function tokenize_bytes(lines, start_lnum)
  local tokens = {}

  for line_idx, line in ipairs(lines) do
    local row = start_lnum + line_idx - 2

    for col = 1, #line do
      tokens[#tokens + 1] = {
        text = line:sub(col, col),
        row = row,
        start_col = col - 1,
        end_col = col,
      }
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
    lines[idx] = token.text
  end
  return table.concat(lines, "\n")
end

---@param bufnr integer
---@param token avante.SelectionDiffToken
---@param hl_group string
local function add_highlight(bufnr, token, hl_group)
  api.nvim_buf_set_extmark(bufnr, NAMESPACE, token.row, token.start_col, {
    end_row = token.row,
    end_col = token.end_col,
    hl_group = hl_group,
    hl_mode = "combine",
    priority = PRIORITY,
  })
end

---@param old_tokens avante.SelectionDiffToken[]
---@param new_tokens avante.SelectionDiffToken[]
---@return avante.SelectionDiffToken[]
function M.changed_tokens(old_tokens, new_tokens)
  if #new_tokens == 0 then return {} end
  if #old_tokens == 0 then return new_tokens end

  ---@diagnostic disable-next-line: assign-type-mismatch
  local patch = vim.diff( ---@type integer[][]
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
  local old_tokens = tokenize_bytes(old_lines, start_lnum)
  if #old_tokens == 0 then return {} end

  local new_tokens = tokenize_bytes(new_lines, 1)
  return merge_adjacent_tokens(M.changed_tokens(new_tokens, old_tokens))
end

---@param old_lines string[]
---@param new_lines string[]
---@param start_lnum integer 1-indexed
---@return avante.SelectionDiffToken[]
local function inserted_ranges(old_lines, new_lines, start_lnum)
  local new_tokens = tokenize_bytes(new_lines, start_lnum)
  if #new_tokens == 0 then return {} end

  local old_tokens = tokenize_bytes(old_lines, 1)
  return merge_adjacent_tokens(M.changed_tokens(old_tokens, new_tokens))
end

---@param bufnr integer?
function M.clear(bufnr)
  bufnr = bufnr or 0
  if not api.nvim_buf_is_valid(bufnr) then return end
  api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
end

---@param bufnr integer
---@param old_lines string[]
---@param new_lines string[]
---@param start_lnum integer 1-indexed
---@param opts? { timeout_ms?: integer }
function M.show(bufnr, old_lines, new_lines, start_lnum, opts)
  if not api.nvim_buf_is_valid(bufnr) then return end

  local timeout_ms = timeout_from_opts(opts)
  if timeout_ms == 0 then return end

  M.clear(bufnr)
  if #inserted_ranges(old_lines, new_lines, start_lnum) == 0 then return end

  local changed = M.changed_tokens(tokenize(old_lines, 1), tokenize(new_lines, start_lnum))
  for _, token in ipairs(changed) do
    add_highlight(bufnr, token, Highlights.SELECTION_DIFF)
  end

  if #changed > 0 and timeout_ms and timeout_ms > 0 then vim.defer_fn(function() M.clear(bufnr) end, timeout_ms) end
end

---@param bufnr integer
---@param old_lines string[]
---@param new_lines string[]
---@param start_lnum integer 1-indexed
---@param opts? { timeout_ms?: integer }
---@return integer count
function M.show_deletions(bufnr, old_lines, new_lines, start_lnum, opts)
  if not api.nvim_buf_is_valid(bufnr) then return 0 end

  local timeout_ms = timeout_from_opts(opts)
  if timeout_ms == 0 then return 0 end

  local deleted = M.deleted_ranges(old_lines, new_lines, start_lnum)
  if #deleted == 0 then return 0 end

  M.clear(bufnr)
  for _, token in ipairs(deleted) do
    add_highlight(bufnr, token, Highlights.SELECTION_DIFF_DELETE)
  end

  if timeout_ms > 0 then vim.defer_fn(function() M.clear(bufnr) end, timeout_ms) end

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
  if not api.nvim_buf_is_valid(bufnr) then return false end

  local timeout_ms = timeout_from_opts(opts)
  if timeout_ms <= 0 then return false end

  local deleted = M.deleted_ranges(old_lines, new_lines, start_lnum)
  if #deleted == 0 then return false end

  M.clear(bufnr)
  for _, token in ipairs(deleted) do
    add_highlight(bufnr, token, Highlights.SELECTION_DIFF_DELETE)
  end

  vim.defer_fn(function()
    M.clear(bufnr)
    if api.nvim_buf_is_valid(bufnr) then callback() end
  end, timeout_ms)

  return true
end

M._tokenize = tokenize
M._tokenize_bytes = tokenize_bytes
M._namespace = NAMESPACE

return M
