local api = vim.api

local M = {}

---@param bufnr integer
---@param winid? integer
---@return integer[]|nil cursor (1-based line, 0-based byte column)
function M.cursor(bufnr, winid)
  if bufnr == 0 then bufnr = api.nvim_get_current_buf() end
  if winid and api.nvim_win_is_valid(winid) and api.nvim_win_get_buf(winid) == bufnr then
    return api.nvim_win_get_cursor(winid)
  end
  if api.nvim_get_current_buf() == bufnr then return api.nvim_win_get_cursor(0) end
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if api.nvim_win_is_valid(win) then return api.nvim_win_get_cursor(win) end
  end
end

---@param bufnr integer
---@param cursor? integer[]
---@return AvanteSelectedFile file
function M.file(bufnr, cursor)
  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  cursor = cursor or M.cursor(bufnr)
  if cursor then
    local row = math.max(1, math.min(cursor[1], #lines))
    local line = lines[row]
    local col = math.max(0, math.min(cursor[2], #line))
    -- A saved column can fall inside a UTF-8 character after a buffer change.
    while col > 0 and col < #line do
      local byte = line:byte(col + 1)
      if byte < 128 or byte >= 192 then break end
      col = col - 1
    end
    lines[row] = line:sub(1, col) .. "<cursor/>" .. line:sub(col + 1)
  end
  return {
    content = table.concat(lines, "\n"),
    path = api.nvim_buf_get_name(bufnr),
    file_type = vim.bo[bufnr].filetype,
  }
end

return M
