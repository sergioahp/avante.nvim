local Utils = require("avante.utils")
local Config = require("avante.config")
local Llm = require("avante.llm")
local Provider = require("avante.providers")
local RepoMap = require("avante.repo_map")
local PromptInput = require("avante.ui.prompt_input")
local SelectionResult = require("avante.selection_result")
local SelectionDiffHighlight = require("avante.selection_diff_highlight")
local Range = require("avante.range")
local Morph = require("avante.morph")

local api = vim.api
local fn = vim.fn

local NAMESPACE = api.nvim_create_namespace("avante_selection")
local SELECTED_CODE_NAMESPACE = api.nvim_create_namespace("avante_selected_code")
local PRIORITY = (vim.hl or vim.highlight).priorities.user

---@class avante.Selection
---@field id integer
---@field selection avante.SelectionResult | nil
---@field cursor_pos table | nil
---@field shortcuts_extmark_id integer | nil
---@field shortcuts_hint_timer? uv.uv_timer_t
---@field selected_code_extmark_id integer | nil
---@field augroup integer | nil
---@field visual_mode_augroup integer | nil
---@field code_winid integer | nil
---@field code_bufnr integer | nil
---@field prompt_input avante.ui.PromptInput | nil
local Selection = {}
Selection.__index = Selection

Selection.did_setup = false

---@param id integer the tabpage id retrieved from api.nvim_get_current_tabpage()
function Selection:new(id)
  return setmetatable({
    id = id,
    shortcuts_extmark_id = nil,
    selected_code_extmark_id = nil,
    augroup = api.nvim_create_augroup("avante_selection_" .. id, { clear = true }),
    selection = nil,
    cursor_pos = nil,
    code_winid = nil,
    code_bufnr = nil,
    prompt_input = nil,
  }, Selection)
end

function Selection:get_virt_text_line()
  local current_pos = fn.getpos(".")

  -- Get the current and start position line numbers
  local current_line = current_pos[2] - 1 -- 0-indexed

  -- Ensure line numbers are not negative and don't exceed buffer range
  local total_lines = api.nvim_buf_line_count(0)
  if current_line < 0 then current_line = 0 end
  if current_line >= total_lines then current_line = total_lines - 1 end

  -- Take the first line of the selection to ensure virt_text is always in the top right corner
  return current_line
end

function Selection:show_shortcuts_hints_popup()
  local virt_text_line = self:get_virt_text_line()
  if self.shortcuts_extmark_id then
    local extmark = vim.api.nvim_buf_get_extmark_by_id(0, NAMESPACE, self.shortcuts_extmark_id, {})
    if extmark and extmark[1] == virt_text_line then
      -- The hint text is already where it is supposed to be
      return
    end
    self:close_shortcuts_hints_popup()
  end

  local hint_text = string.format(" [%s: ask, %s: edit] ", Config.mappings.ask, Config.mappings.edit)

  self.shortcuts_extmark_id = api.nvim_buf_set_extmark(0, NAMESPACE, virt_text_line, -1, {
    virt_text = { { hint_text, "AvanteInlineHint" } },
    virt_text_pos = "eol",
    priority = PRIORITY,
  })
end

function Selection:close_shortcuts_hints_popup()
  if self.shortcuts_extmark_id then
    api.nvim_buf_del_extmark(0, NAMESPACE, self.shortcuts_extmark_id)
    self.shortcuts_extmark_id = nil
  end
end

function Selection:close_editing_input()
  if self.prompt_input then
    self.prompt_input:close()
    self.prompt_input = nil
  end
  Llm.cancel_inflight_request()
  if self.code_winid and api.nvim_win_is_valid(self.code_winid) then
    local code_bufnr = api.nvim_win_get_buf(self.code_winid)
    api.nvim_buf_clear_namespace(code_bufnr, SELECTED_CODE_NAMESPACE, 0, -1)
    if self.selected_code_extmark_id then
      api.nvim_buf_del_extmark(code_bufnr, SELECTED_CODE_NAMESPACE, self.selected_code_extmark_id)
      self.selected_code_extmark_id = nil
    end
  end
  if self.cursor_pos and self.code_winid and api.nvim_win_is_valid(self.code_winid) then
    vim.schedule(function()
      local bufnr = api.nvim_win_get_buf(self.code_winid)
      local line_count = api.nvim_buf_line_count(bufnr)
      local row = math.min(self.cursor_pos[1], line_count)
      local line = api.nvim_buf_get_lines(bufnr, row - 1, row, true)[1] or ""
      local col = math.min(self.cursor_pos[2], #line)
      api.nvim_win_set_cursor(self.code_winid, { row, col })
    end)
  end
end

function Selection:submit_input(input)
  if not input then
    Utils.error("No input provided", { once = true, title = "Avante" })
    return
  end
  if self.prompt_input and self.prompt_input.spinner_active then
    Utils.error(
      "Please wait for the previous request to finish before submitting another",
      { once = true, title = "Avante" }
    )
    return
  end
  local code_lines = api.nvim_buf_get_lines(self.code_bufnr, 0, -1, false)
  local code_content = table.concat(code_lines, "\n")
  local original_selection_lines =
    vim.list_slice(code_lines, self.selection.range.start.lnum, self.selection.range.finish.lnum)

  -- Shared mutable state for the streaming edit. on_chunk only mutates fields
  -- here; do_flush reads them at fire time. See spec: closures over a single
  -- table, serialized through Neovim's main loop, so no race-safety needed.
  local flusher = {
    full_response = "",
    done = false,
    start_line = self.selection.range.start.lnum,
    finish_line = self.selection.range.finish.lnum,
    need_prepend_indentation = false,
    original_first_line_indentation = Utils.get_indentation(code_lines[self.selection.range.start.lnum]),
    delete_flash_attempted = false,
    delete_flash_pending = false,
    response_complete = false,
    after_pending_flush = nil,
  }

  if self.prompt_input then self.prompt_input:start_spinner() end

  ---@type AvanteLLMStartCallback
  local function on_start(_) end

  local function do_flush(on_applied)
    if flusher.done then return false end
    if flusher.delete_flash_pending then
      if on_applied then flusher.after_pending_flush = on_applied end
      return false
    end
    if not api.nvim_buf_is_valid(self.code_bufnr) then return false end
    local response_lines_ = vim.split(flusher.full_response, "\n")
    local response_lines = {}
    local in_code_block = false
    local line_processed
    for _, line in ipairs(response_lines_) do
      if line:match("^<code>") then
        in_code_block = true
        line_processed = line:gsub("^<code>", ""):gsub("</code>.*$", "")
        if line_processed ~= "" then table.insert(response_lines, line_processed) end
      elseif line:match("</code>") then
        in_code_block = false
        line_processed = line:gsub("</code>.*$", "")
        if line_processed ~= "" then table.insert(response_lines, line_processed) end
      elseif in_code_block then
        table.insert(response_lines, line)
      end
    end
    if #response_lines == 1 then
      local first_line = response_lines[1]
      local first_line_indentation = Utils.get_indentation(first_line)
      flusher.need_prepend_indentation = first_line_indentation ~= flusher.original_first_line_indentation
    end
    if flusher.need_prepend_indentation then
      for i, line in ipairs(response_lines) do
        response_lines[i] = flusher.original_first_line_indentation .. line
      end
    end

    if not flusher.delete_flash_attempted then
      if #response_lines == 0 then return false end
      if not flusher.response_complete and #response_lines < #original_selection_lines then return false end

      flusher.delete_flash_attempted = true
      local delayed = SelectionDiffHighlight.flash_deletions_before(
        self.code_bufnr,
        original_selection_lines,
        response_lines,
        flusher.start_line,
        function()
          local after_pending_flush = flusher.after_pending_flush or on_applied
          flusher.after_pending_flush = nil
          flusher.delete_flash_pending = false
          do_flush(after_pending_flush)
        end
      )
      if delayed then
        flusher.delete_flash_pending = true
        return false
      end
    end

    local ok = pcall(
      function()
        api.nvim_buf_set_lines(self.code_bufnr, flusher.start_line - 1, flusher.finish_line, true, response_lines)
      end
    )
    if ok then
      flusher.finish_line = flusher.start_line + #response_lines - 1
      if on_applied then on_applied() end
    end

    return ok
  end

  -- No args: Utils.throttle captures args at schedule time, but do_flush reads
  -- from `flusher` at fire time, so chunks that arrive during the window are
  -- still picked up. 0 disables coalescing.
  --
  -- Resolution order: per-provider override -> global default -> 0.
  -- An explicit 0 anywhere disables coalescing for that scope. Lua's `or`
  -- chains correctly here because 0 is truthy; only nil falls through.
  local provider_cfg = Provider.get_config(Config.provider)
  local interval_ms = (provider_cfg and provider_cfg.edit_stream_flush_interval_ms)
    or Config.selection.edit_stream_flush_interval_ms
    or 0
  local schedule_flush = interval_ms > 0 and Utils.throttle(do_flush, interval_ms) or do_flush

  ---@type AvanteLLMChunkCallback
  local function on_chunk(chunk)
    if flusher.done then return end
    local was_empty = flusher.full_response == ""
    flusher.full_response = flusher.full_response .. chunk
    -- Leading edge: try to show the first usable replacement before waiting
    -- for the throttle interval.
    if was_empty then
      do_flush()
    else
      schedule_flush()
    end
  end

  ---@type AvanteLLMStopCallback
  local function on_stop(stop_opts)
    if stop_opts.error then
      -- NOTE: in Ubuntu 22.04+ you will see this ignorable error from ~/.local/share/nvim/lazy/avante.nvim/lua/avante/llm.lua `on_error = function(err)`, check to avoid showing this error.
      if type(stop_opts.error) == "table" and stop_opts.error.exit == nil and stop_opts.error.stderr == "{}" then
        return
      end
      Utils.error(
        "Error occurred while processing the response: " .. vim.inspect(stop_opts.error),
        { once = true, title = "Avante" }
      )
      return
    end
    local function finish()
      if flusher.done then return end
      flusher.done = true
      if self.prompt_input then self.prompt_input:stop_spinner() end
      if api.nvim_buf_is_valid(self.code_bufnr) then
        local new_selection_lines =
          api.nvim_buf_get_lines(self.code_bufnr, flusher.start_line - 1, flusher.finish_line, false)
        SelectionDiffHighlight.show(self.code_bufnr, original_selection_lines, new_selection_lines, flusher.start_line)
      end
      vim.defer_fn(function() self:close_editing_input() end, 0)
      Utils.debug("full response:", flusher.full_response)
    end

    -- Final synchronous flush so the tail chunks land before we tear down,
    -- then block any pending throttle timer from firing on stale state.
    flusher.response_complete = true
    local applied = do_flush(finish)
    if not applied and not flusher.delete_flash_pending then finish() end
  end

  local filetype = api.nvim_get_option_value("filetype", { buf = self.code_bufnr })
  local file_ext = api.nvim_buf_get_name(self.code_bufnr):match("^.+%.(.+)$")

  local mentions = Utils.extract_mentions(input)
  input = mentions.new_content
  local project_context = mentions.enable_project_context and RepoMap.get_repo_map(file_ext) or nil

  local diagnostics = Utils.lsp.get_current_selection_diagnostics(self.code_bufnr, self.selection)

  ---@type AvanteSelectedCode | nil
  local selected_code = nil

  if self.selection then
    selected_code = {
      content = self.selection.content,
      file_type = self.selection.filetype,
      path = self.selection.filepath,
    }
  end

  -- Fast-apply path: the configured (fast) provider drafts the edit by CALLING the
  -- edit_file tool (Morph's documented draft format: path/instructions/code_edit with
  -- `// ... existing code ...` markers). We capture that single tool call, hand Morph
  -- the WHOLE file as context plus the model's first-person instruction, then confine
  -- the merge back to the selected region client-side. Falls back to the inline <code>
  -- replacement when Morph isn't configured.
  local morph_provider = Provider["morph"]
  local use_morph = Config.selection.fastapply and morph_provider ~= nil and morph_provider.is_env_set()

  -- The non-fast-apply path returns the full <code> region inline, so we forbid tool
  -- calls there. The fast-apply path needs the edit_file tool, so leave tools enabled.
  local instructions = use_morph and input or ("Do not call any tools and just response the request: " .. input)

  local Helpers = require("avante.llm_tools.helpers")
  -- The model's single edit_file call lands here.
  local captured = {}
  local edit_file_tool = {
    name = "edit_file",
    description = "Propose an edit to the selected region. A faster, less capable model applies it, so write "
      .. "the change as a sketch: only the lines you are changing, with a `// ... existing code ...` comment "
      .. "(in the file's language) standing in for every unchanged span. Call this tool exactly once.",
    param = {
      type = "table",
      fields = {
        { name = "path", type = "string", description = "The target file path to modify." },
        {
          name = "instructions",
          type = "string",
          description = 'A single first-person sentence describing the edit, e.g. "I am filling in the z-row '
            .. 'of the tableau". Used to disambiguate where the edit applies.',
        },
        {
          name = "code_edit",
          type = "string",
          description = "Only the changed lines, with `// ... existing code ...` markers for every unchanged "
            .. "span. Keep enough surrounding context to anchor the edit; never omit code without a marker.",
        },
      },
    },
    returns = {
      { name = "success", type = "boolean", description = "Whether the edit was captured" },
    },
    func = function(tool_input)
      captured.path = tool_input.path
      captured.instructions = tool_input.instructions
      captured.code_edit = tool_input.code_edit
      -- End the draft turn after this single tool call rather than letting the agent
      -- loop re-prompt the model; we run the Morph apply ourselves in on_stop_morph.
      -- CANCEL_TOKEN is the framework's "this tool ended the turn" signal.
      return nil, Helpers.CANCEL_TOKEN
    end,
  }

  -- Minimal history harness so the stream's tool loop can find the pending tool call.
  local history_messages = {}
  local function on_messages_add(msgs)
    msgs = vim.islist(msgs) and msgs or { msgs }
    for _, msg in ipairs(msgs) do
      local idx
      for i, m in ipairs(history_messages) do
        if m.uuid == msg.uuid then
          idx = i
          break
        end
      end
      if idx then
        history_messages[idx] = msg
      else
        table.insert(history_messages, msg)
      end
    end
  end
  local function get_history_messages() return history_messages end

  ---@type AvanteLLMChunkCallback
  local function on_chunk_morph(chunk)
    if flusher.done then return end
    flusher.full_response = flusher.full_response .. chunk
  end

  ---@type AvanteLLMStopCallback
  local function on_stop_morph(stop_opts)
    -- A real streaming error aborts; the tool-ended-turn "cancelled" stop carries no
    -- error and falls through to the apply below.
    if stop_opts.error then
      if type(stop_opts.error) == "table" and stop_opts.error.exit == nil and stop_opts.error.stderr == "{}" then
        return
      end
      if self.prompt_input then self.prompt_input:stop_spinner() end
      Utils.error("Error drafting the edit: " .. vim.inspect(stop_opts.error), { once = true, title = "Avante" })
      return
    end
    if flusher.done then return end
    flusher.done = true

    -- Prefer the tool call; fall back to raw text if the model answered inline.
    local code_edit = captured.code_edit
    if (code_edit == nil or code_edit == "") and flusher.full_response ~= "" then code_edit = flusher.full_response end
    if code_edit == nil or code_edit == "" then
      if self.prompt_input then self.prompt_input:stop_spinner() end
      Utils.error("The model did not produce an edit", { once = true, title = "Avante" })
      return
    end
    local morph_instruction = captured.instructions
    if morph_instruction == nil or morph_instruction == "" then
      morph_instruction = "Apply the update to the selected region only, leaving the rest of the file unchanged."
    end

    -- Whole file as context so Morph can anchor the snippet accurately; the markers
    -- plus the instruction tell it where to apply.
    Morph.apply(code_content, code_edit, morph_instruction, function(merged, err)
      if self.prompt_input then self.prompt_input:stop_spinner() end
      if err or merged == nil then
        Utils.error("Morph apply failed: " .. (err or "unknown error"), { once = true, title = "Avante" })
        return
      end
      local merged_lines = vim.split(merged, "\n")
      if #merged_lines > 1 and merged_lines[#merged_lines] == "" then table.remove(merged_lines) end
      -- Client-side guard: make sure Morph only touched the selected region.
      local region, verr = Morph.scoped_region_change(
        code_lines,
        merged_lines,
        self.selection.range.start.lnum,
        self.selection.range.finish.lnum
      )
      if region == nil then
        Utils.error(
          "Morph edit rejected: " .. verr .. ". The buffer was left unchanged.",
          { once = true, title = "Avante" }
        )
        return
      end
      local function apply_region()
        if not api.nvim_buf_is_valid(self.code_bufnr) then return end
        local ok = pcall(
          function()
            api.nvim_buf_set_lines(
              self.code_bufnr,
              self.selection.range.start.lnum - 1,
              self.selection.range.finish.lnum,
              true,
              region
            )
          end
        )
        if ok then
          SelectionDiffHighlight.show(
            self.code_bufnr,
            original_selection_lines,
            region,
            self.selection.range.start.lnum
          )
        end
        vim.defer_fn(function() self:close_editing_input() end, 0)
      end

      if
        not SelectionDiffHighlight.flash_deletions_before(
          self.code_bufnr,
          original_selection_lines,
          region,
          self.selection.range.start.lnum,
          apply_region
        )
      then
        apply_region()
      end
    end)
  end

  Llm.stream({
    ask = true,
    project_context = vim.json.encode(project_context),
    diagnostics = vim.json.encode(diagnostics),
    selected_files = { { content = code_content, file_type = filetype, path = "" } },
    code_lang = filetype,
    selected_code = selected_code,
    instructions = instructions,
    mode = use_morph and "editing_morph" or "editing",
    tools = use_morph and { edit_file_tool } or nil,
    get_history_messages = use_morph and get_history_messages or nil,
    on_messages_add = use_morph and on_messages_add or nil,
    on_start = on_start,
    on_chunk = use_morph and on_chunk_morph or on_chunk,
    on_reasoning_chunk = function() end,
    on_stop = use_morph and on_stop_morph or on_stop,
  })
end

---@param request? string
---@param line1? integer
---@param line2? integer
function Selection:create_editing_input(request, line1, line2)
  self:close_editing_input()

  if not vim.g.avante_login or vim.g.avante_login == false then
    api.nvim_exec_autocmds("User", { pattern = Provider.env.REQUEST_LOGIN_PATTERN })
    vim.g.avante_login = true
  end

  self.code_bufnr = api.nvim_get_current_buf()
  self.code_winid = api.nvim_get_current_win()
  self.cursor_pos = api.nvim_win_get_cursor(self.code_winid)
  local code_lines = api.nvim_buf_get_lines(self.code_bufnr, 0, -1, false)

  if line1 ~= nil and line2 ~= nil then
    local filepath = vim.fn.expand("%:p")
    local filetype = Utils.get_filetype(filepath)
    local content_lines = vim.list_slice(code_lines, line1, line2)
    local content = table.concat(content_lines, "\n")
    local range = Range:new(
      { lnum = line1, col = #content_lines[1] },
      { lnum = line2, col = #content_lines[#content_lines] }
    )
    self.selection = SelectionResult:new(filepath, filetype, content, range)
  else
    self.selection = Utils.get_visual_selection_and_range()
  end

  if self.selection == nil then
    Utils.error("No visual selection found", { once = true, title = "Avante" })
    return
  end

  local start_row
  local start_col
  local end_row
  local end_col
  if vim.fn.mode() == "V" then
    start_row = self.selection.range.start.lnum - 1
    start_col = 0
    end_row = self.selection.range.finish.lnum - 1
    end_col = #code_lines[self.selection.range.finish.lnum]
  else
    start_row = self.selection.range.start.lnum - 1
    start_col = self.selection.range.start.col - 1
    end_row = self.selection.range.finish.lnum - 1
    end_col = math.min(self.selection.range.finish.col, #code_lines[self.selection.range.finish.lnum])
  end

  self.selected_code_extmark_id =
    api.nvim_buf_set_extmark(self.code_bufnr, SELECTED_CODE_NAMESPACE, start_row, start_col, {
      hl_group = "Visual",
      hl_mode = "combine",
      end_row = end_row,
      end_col = end_col,
      priority = PRIORITY,
    })

  local prompt_input = PromptInput:new({
    default_value = request,
    submit_callback = function(input) self:submit_input(input) end,
    cancel_callback = function() self:close_editing_input() end,
    win_opts = {
      border = Config.windows.edit.border,
      height = Config.windows.edit.height,
      width = Config.windows.edit.width,
      title = { { "Avante edit selected block", "FloatTitle" } },
    },
    start_insert = Config.windows.edit.start_insert,
  })

  self.prompt_input = prompt_input

  prompt_input:open()
end

---Show the hints virtual line and set up autocommands to update it or stop showing it when exiting visual mode
---@param bufnr integer
function Selection:on_entering_visual_mode(bufnr)
  if Config.selection.hint_display == "none" then return end
  if vim.bo[bufnr].buftype == "terminal" or Utils.is_sidebar_buffer(bufnr) then return end

  self:show_shortcuts_hints_popup()

  self.visual_mode_augroup = api.nvim_create_augroup("avante_selection_visual_" .. self.id, { clear = true })
  if Config.selection.hint_display == "delayed" then
    local deferred_show_shortcut_hints_popup = Utils.debounce(function()
      self:show_shortcuts_hints_popup()
      self.shortcuts_hint_timer = nil
    end, vim.o.updatetime)

    api.nvim_create_autocmd({ "CursorMoved" }, {
      group = self.visual_mode_augroup,
      buffer = bufnr,
      callback = function()
        self:close_shortcuts_hints_popup()
        self.shortcuts_hint_timer = deferred_show_shortcut_hints_popup()
      end,
    })
  else
    self:show_shortcuts_hints_popup()
    api.nvim_create_autocmd({ "CursorMoved" }, {
      group = self.visual_mode_augroup,
      buffer = bufnr,
      callback = function() self:show_shortcuts_hints_popup() end,
    })
  end
  api.nvim_create_autocmd({ "ModeChanged" }, {
    group = self.visual_mode_augroup,
    buffer = bufnr,
    callback = function(ev)
      -- Check if exiting visual mode. Autocommand pattern matching does not work
      -- with buffer-local autocommands so need to test explicitly
      if ev.match:match("[vV]:[^vV]") then self:on_exiting_visual_mode() end
    end,
  })
  api.nvim_create_autocmd({ "BufLeave" }, {
    group = self.visual_mode_augroup,
    buffer = bufnr,
    callback = function() self:on_exiting_visual_mode() end,
  })
end

function Selection:on_exiting_visual_mode()
  self:close_shortcuts_hints_popup()

  if self.shortcuts_hint_timer then
    self.shortcuts_hint_timer:stop()
    self.shortcuts_hint_timer:close()
    self.shortcuts_hint_timer = nil
  end

  api.nvim_del_augroup_by_id(self.visual_mode_augroup)
  self.visual_mode_augroup = nil
end

function Selection:setup_autocmds()
  self.did_setup = true

  api.nvim_create_autocmd("User", {
    group = self.augroup,
    pattern = "AvanteEditSubmitted",
    callback = function(ev) self:submit_input(ev.data.request) end,
  })

  api.nvim_create_autocmd({ "ModeChanged" }, {
    group = self.augroup,
    pattern = { "n:v", "n:V", "n:" }, -- Entering Visual mode from Normal mode
    callback = function(ev) self:on_entering_visual_mode(ev.buf) end,
  })
end

function Selection:delete_autocmds()
  if self.augroup then
    api.nvim_del_augroup_by_id(self.augroup)
    self.augroup = nil
  end

  self.did_setup = false
end

return Selection
