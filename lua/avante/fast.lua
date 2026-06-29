local Utils = require("avante.utils")
local Config = require("avante.config")
local Llm = require("avante.llm")
local Provider = require("avante.providers")
local Morph = require("avante.morph")
local PendingEdits = require("avante.pending_edits")
local History = require("avante.history")
local Path = require("avante.path")

local api = vim.api

---Fast chat: a minimal, non-agentic Morph editor. One model turn drafts every edit
---as a single `edit_file` call; Morph merges it whole-file; the diff lands as a
---pending virtual-text overlay (see `avante.pending_edits`) instead of being written.
---The only other tool is an on-demand `get_diagnostics` (so "fix the diagnostics"
---works without auto-injecting them). Native tool calls, current file only, tuned for
---sub-3s round-trips. This is the engine behind `chat_mode = "fast"` and the
---no-selection float prompt.
---@class avante.Fast
local M = {}

---@return boolean ok, string|nil err
local function morph_ready()
  local provider = Provider["morph"]
  if not provider or not provider.is_env_set() then
    return false, "Fast chat needs the `morph` provider configured (set MORPH_API_KEY)."
  end
  return true
end

local edit_file_tool_param = {
  type = "table",
  fields = {
    { name = "path", type = "string", description = "The path of the current file to modify." },
    {
      name = "instructions",
      type = "string",
      description = 'A single first-person sentence describing the change, e.g. "I am adding a guard clause to '
        .. 'the parse function". When you make several edits at once, summarize them in this one sentence.',
    },
    {
      name = "code_edit",
      type = "string",
      description = "Only the lines you are changing, with a `// ... existing code ...` marker (in the file's "
        .. "language) for every unchanged span you skip. Put ALL edits in this one call, each separated by a "
        .. "marker. Never omit existing code without a marker.",
    },
  },
}

---Build the fast tool set bound to `bufnr`: a single `edit_file` that drafts to Morph
---and lands the merge as a pending overlay (reading the buffer FRESH at call time, so
---edits the user made since the last turn are picked up), plus an optional on-demand
---`get_diagnostics`. The Morph result is never returned to the model -- it gets only a
---tiny ack and keeps its turn for an explanation. Shared by the float prompt and the
---sidebar/zen fast mode.
---@param bufnr integer
---@param opts? { with_diagnostics?: boolean, on_call?: fun(), on_applied?: fun(hunks: integer) }
---@return table[]
function M.make_fast_tools(bufnr, opts)
  opts = opts or {}
  local edit_file_tool = {
    name = "edit_file",
    description = "Make the requested change to the current file. A faster apply model merges your draft, so "
      .. "write only the lines you change, with a `// ... existing code ...` marker for every unchanged span. "
      .. "Put ALL of your edits in this one call.",
    param = edit_file_tool_param,
    returns = { { name = "success", type = "boolean", description = "Whether the edit was accepted for apply" } },
    func = function(tool_input, tool_opts)
      -- Edit tools are also invoked with partial input while the call streams in;
      -- act only on the final, complete call.
      if tool_opts and tool_opts.streaming then return end
      if opts.on_call then opts.on_call() end
      if not api.nvim_buf_is_valid(bufnr) then return "The target buffer is no longer open." end
      local code_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local code_content = table.concat(code_lines, "\n")
      local code_edit = tool_input.code_edit or ""
      local instruction = tool_input.instructions
      if instruction == nil or instruction == "" then instruction = "Apply the requested change to the file." end
      Morph.apply(code_content, code_edit, instruction, function(merged, merr)
        if merr or merged == nil then
          Utils.error("Morph apply failed: " .. (merr or "unknown error"), { once = true, title = "Avante" })
          if opts.on_applied then opts.on_applied(0) end
          return
        end
        local merged_lines = vim.split(merged, "\n")
        if #merged_lines > 1 and merged_lines[#merged_lines] == "" then table.remove(merged_lines) end
        if not api.nvim_buf_is_valid(bufnr) then return end
        local n = PendingEdits.set(bufnr, code_lines, merged_lines)
        if n == 0 then
          Utils.info("Avante fast: no changes", { title = "Avante" })
        else
          Utils.info(
            ("Avante fast: %d pending edit%s -- <Tab> to review"):format(n, n == 1 and "" or "s"),
            { title = "Avante" }
          )
        end
        if opts.on_applied then opts.on_applied(n) end
      end)
      -- Tiny ack so the model keeps its turn; it never sees the merged code.
      return "Your edit was submitted and is now shown to the user as a pending change to review."
    end,
  }
  local tools = { edit_file_tool }
  -- The "+1": on-demand diagnostics. Returns a real result so the loop continues
  -- and the model still has to make its edit (or answer) afterward.
  if opts.with_diagnostics ~= false then table.insert(tools, require("avante.llm_tools.get_diagnostics")) end
  return tools
end

---@class avante.fast.SubmitOpts
---@field prompt string
---@field bufnr? integer target buffer (defaults to current)
---@field selection? avante.SelectionResult optional visual selection for extra context
---@field with_diagnostics? boolean expose the get_diagnostics tool (the "+1"); default true
---@field on_state? fun(state: "start"|"done") UI hook (spinner etc.)
---@field on_done? fun(result: { applied: boolean, hunks?: integer, error?: string })

---Run one fast-chat exchange against `opts.bufnr`. The model drafts the edit, Morph
---applies it, and the result shows up as pending hunks in the buffer.
---@param opts avante.fast.SubmitOpts
function M.submit(opts)
  local prompt = opts.prompt
  if not prompt or prompt == "" then
    Utils.error("No input provided", { once = true, title = "Avante" })
    return
  end
  local ok, err = morph_ready()
  if not ok then
    Utils.error(err or "Fast chat unavailable", { once = true, title = "Avante" })
    return
  end

  local bufnr = opts.bufnr or api.nvim_get_current_buf()
  local code_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local code_content = table.concat(code_lines, "\n")
  local filetype = api.nvim_get_option_value("filetype", { buf = bufnr })
  local filepath = api.nvim_buf_get_name(bufnr)

  -- This prompt IS the chat window's session, just without the window: we drive the
  -- real per-buffer history, so the exchange (and the model's reply) shows up in the
  -- sidebar/zen when it is opened next. Prior turns are seeded as context so the
  -- thread continues.
  local chat_history = Path.history.load(bufnr)
  local messages = History.get_history_messages(chat_history)
  local user_msg = History.Message:new("user", prompt, { is_user_submission = true })
  user_msg.provider = Config.provider
  local provider_conf = Config.get_provider_config and Config.get_provider_config(Config.provider) or nil
  if provider_conf then user_msg.model = provider_conf.model end
  table.insert(messages, user_msg)

  local function persist()
    chat_history.messages = messages
    if chat_history.title == nil or chat_history.title == "" or chat_history.title == "untitled" then
      local first = vim.split(prompt, "\n")[1]
      if first and first ~= "" then chat_history.title = first end
    end
    pcall(Path.history.save, bufnr, chat_history)
  end

  local morph_started = false
  local turn_done = false
  local final_text = ""

  local function notify_done(result)
    if opts.on_state then opts.on_state("done") end
    if opts.on_done then opts.on_done(result) end
  end

  -- The model drafts its whole change as one edit_file call. Morph + the overlay fire
  -- the moment it lands (in parallel with the model finishing its turn); the merge
  -- result is never handed back, so the model keeps its turn for a markdown explanation.
  local tools = M.make_fast_tools(bufnr, {
    with_diagnostics = opts.with_diagnostics,
    on_call = function() morph_started = true end,
    on_applied = function(n) notify_done({ applied = n > 0, hunks = n }) end,
  })

  -- The stream appends its assistant/tool messages straight into the session list,
  -- so the tool loop sees pending calls, reasoning rides across the get_diagnostics /
  -- explanation rounds, and the whole turn is ready to persist.
  local function on_messages_add(msgs)
    msgs = vim.islist(msgs) and msgs or { msgs }
    for _, msg in ipairs(msgs) do
      local idx
      for i, m in ipairs(messages) do
        if m.uuid == msg.uuid then
          idx = i
          break
        end
      end
      if idx then
        messages[idx] = msg
      else
        table.insert(messages, msg)
      end
    end
  end
  local function get_history_messages() return messages end

  ---@type AvanteLLMChunkCallback
  local function on_chunk(chunk)
    -- Accumulate the model's user-visible answer / explanation (markdown).
    if type(chunk) == "string" then final_text = final_text .. chunk end
  end

  ---@type AvanteLLMStopCallback
  local function on_stop(stop_opts)
    if stop_opts.error then
      if type(stop_opts.error) == "table" and stop_opts.error.exit == nil and stop_opts.error.stderr == "{}" then
        return
      end
      if turn_done then return end
      turn_done = true
      local emsg = vim.inspect(stop_opts.error)
      Utils.error("Fast chat error: " .. emsg, { once = true, title = "Avante" })
      persist()
      if not morph_started then notify_done({ applied = false, error = emsg }) end
      return
    end
    if turn_done then return end
    turn_done = true
    -- The edit + overlay are handled by start_morph; the model's reply (its markdown
    -- explanation, or a plain answer when nothing was edited) is already in `messages`.
    -- Persist the thread so it shows in the chat window when opened -- no popup.
    persist()
    if not morph_started then notify_done({ applied = false, text = vim.trim(final_text) }) end
  end

  ---@type AvanteSelectedCode|nil
  local selected_code = nil
  if opts.selection then
    selected_code = {
      content = opts.selection.content,
      file_type = opts.selection.filetype,
      path = opts.selection.filepath,
    }
  end

  if opts.on_state then opts.on_state("start") end

  Llm.stream({
    ask = true,
    selected_files = { { content = code_content, file_type = filetype, path = filepath } },
    code_lang = filetype,
    selected_code = selected_code,
    -- The current prompt is the last user message in `messages`; prior turns precede
    -- it so the model has the running conversation.
    history_messages = messages,
    mode = "fast",
    tools = tools,
    get_history_messages = get_history_messages,
    on_messages_add = on_messages_add,
    on_start = function() end,
    on_chunk = on_chunk,
    on_reasoning_chunk = function() end,
    on_stop = on_stop,
  })
end

-- Public accept/reject surface (current-buffer scoped). Wire these to keys; see
-- the user-config glue for the <Tab> accept-or-next + minuet fallback.
M.has_pending = PendingEdits.has_pending
M.accept_or_next = PendingEdits.accept_or_next
M.reject_under_cursor = PendingEdits.reject_under_cursor
M.accept_all = PendingEdits.accept_all
M.dismiss_all = PendingEdits.dismiss_all

return M
