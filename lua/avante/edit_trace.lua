local Popup = require("nui.popup")
local event = require("nui.utils.autocmd").event

---In-memory trace of the most recent ephemeral selection edit (the Morph
---fast-apply path in avante.selection). That flow keeps no chat history, so
---once it finishes there is nothing to inspect; this module records what each
---side was shown and what it answered, and :AvanteInspectEdit replays it in a
---chat-style popup.
---@class avante.EditTrace
local M = {}

---@class AvanteEditTraceRun
---@field started_at string
---@field t0 integer hrtime at begin, for per-event elapsed ms
---@field meta table
---@field events { ms: integer, kind: string, data: table }[]

---@type AvanteEditTraceRun | nil
M.last = nil

---@param meta table run-level facts: input, path, filetype, selection/crop ranges
function M.begin(meta)
  M.last = {
    started_at = os.date("%Y-%m-%d %H:%M:%S") --[[@as string]],
    t0 = vim.uv.hrtime(),
    meta = meta,
    events = {},
  }
end

---@param kind string
---@param data? table
function M.add(kind, data)
  if not M.last then return end
  table.insert(M.last.events, { ms = math.floor((vim.uv.hrtime() - M.last.t0) / 1e6), kind = kind, data = data or {} })
end

local function fence(lines, lang, text)
  lines[#lines + 1] = "```" .. (lang or "")
  for _, l in ipairs(vim.split(text or "", "\n")) do
    lines[#lines + 1] = l
  end
  lines[#lines + 1] = "```"
  lines[#lines + 1] = ""
end

local function header(lines, ms, who, note)
  lines[#lines + 1] = ("### %s  `+%dms`%s"):format(who, ms, note and ("  — " .. note) or "")
  lines[#lines + 1] = ""
end

---@param run AvanteEditTraceRun
---@return string[]
local function render(run)
  local meta = run.meta
  local lines = {}
  lines[#lines + 1] = ("# Selection edit — %s"):format(run.started_at)
  lines[#lines + 1] = ""
  lines[#lines + 1] = ("- file: `%s` (%s), protocol: %s"):format(
    meta.path or "?",
    meta.filetype or "?",
    meta.protocol or "landmark"
  )
  lines[#lines + 1] = ("- selection: lines %d-%d, crop: lines %d-%d"):format(
    meta.sel_start or 0,
    meta.sel_finish or 0,
    meta.crop_start or 0,
    meta.crop_finish or 0
  )
  lines[#lines + 1] = ""
  header(lines, 0, "user")
  fence(lines, "", meta.input)
  for _, ev in ipairs(run.events) do
    local d = ev.data
    if ev.kind == "context" then
      header(lines, ev.ms, "client → model", "crop shown to the drafting model and Morph")
      fence(lines, meta.filetype, d.crop)
    elseif ev.kind == "window" then
      header(lines, ev.ms, "client → model", "edit window with the selection marked")
      fence(lines, meta.filetype, d.window)
    elseif ev.kind == "rewrite" then
      header(lines, ev.ms, "model → rewrite_window", ("attempt %d"):format(d.attempt or 0))
      fence(lines, meta.filetype, d.code)
    elseif ev.kind == "rescue" then
      header(lines, ev.ms, "fuzzy rescue", "out-of-region drift discarded; applied region:")
      fence(lines, meta.filetype, d.region)
    elseif ev.kind == "draft" then
      header(lines, ev.ms, "model → edit_file", ("attempt %d"):format(d.attempt or 0))
      lines[#lines + 1] = ("instructions: %s"):format(d.instructions or "")
      lines[#lines + 1] = ""
      fence(lines, meta.filetype, d.code_edit)
    elseif ev.kind == "draft_text" then
      header(lines, ev.ms, "model (no tool call)", "raw response used as the draft")
      fence(lines, "", d.text)
    elseif ev.kind == "morph" then
      if d.err then
        header(lines, ev.ms, "morph", "ERROR")
        fence(lines, "", d.err)
      else
        header(lines, ev.ms, "morph → merged crop")
        fence(lines, meta.filetype, d.merged)
      end
    elseif ev.kind == "guard" then
      header(lines, ev.ms, "guard", d.ok and "ACCEPT" or ("REJECT — " .. (d.verr or "?")))
      if d.detail and d.detail.orig then
        lines[#lines + 1] = ("%s the selection, `%s` became `%s`."):format(
          d.detail.where == "before" and "Above" or "Below",
          d.detail.orig,
          d.detail.merged
        )
        lines[#lines + 1] = ""
      end
    elseif ev.kind == "feedback" then
      header(lines, ev.ms, "client → model", "tool result for the rejected draft")
      fence(lines, "", d.text)
    elseif ev.kind == "final" then
      header(lines, ev.ms, "result", d.status)
      if d.note then
        lines[#lines + 1] = d.note
        lines[#lines + 1] = ""
      end
    end
  end
  return lines
end

function M.show()
  if not M.last then
    require("avante.utils").warn("No selection edit has run yet in this session", { title = "Avante" })
    return
  end
  local popup = Popup({
    position = "50%",
    enter = true,
    focusable = true,
    border = {
      style = "rounded",
      padding = { 0, 1 },
      text = { top = " Avante last selection edit ", top_align = "center" },
    },
    size = {
      width = math.floor(vim.o.columns * 0.8),
      height = math.floor(vim.o.lines * 0.8),
    },
    buf_options = { filetype = "markdown", modifiable = true },
    win_options = { wrap = true, conceallevel = 2 },
  })
  popup:mount()
  popup:map("n", "q", function() popup:unmount() end, { noremap = true, silent = true })
  popup:on(event.BufLeave, function() popup:unmount() end)
  vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, render(M.last))
  vim.api.nvim_set_option_value("modifiable", false, { buf = popup.bufnr })
end

return M
