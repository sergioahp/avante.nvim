local Providers = require("avante.providers")
local Utils = require("avante.utils")

---Thin client for the Morph fast-apply model. Given the original code and a lazy
---edit snippet (an "update"), Morph merges them and returns the complete updated
---code. The <instruction>/<code>/<update> request shape is what Morph V3 expects.
---@class avante.Morph
local M = {}

---Padding around the selection in the file view the drafting model is shown.
---Wide on purpose: that model has to understand the code before it can act on a
---terse request, and the `<selection>` markers -- not a narrow view -- are what
---tell it which region is the target. This view was once cropped to the same few
---lines as the apply context below, back when a locally unique crop was the only
---way the model could tell which of two identical lines was selected
---(reports/selection-edit-context_2026-09-09.md).
local DRAFT_CONTEXT_LINES = 100

---Padding around the selection in the edit window the drafting model rewrites.
---Deliberately NOT snapped to syntactic regions: wider, node-aligned windows
---measurably hurt (they reach into comment runs and hand Morph more duplicate
---anchors).
local WINDOW_CONTEXT_LINES = 3

---Padding around the selection in the code handed to the apply model. It only
---has to cover the edit window plus room for the landmarks wrapping it to
---resolve; every line beyond that is one more anchor Morph can land on by
---mistake, and wider context makes duplicate-anchor ambiguity worse rather than
---better (reports/regen-window-selection-edit_2026-07-18.md).
local APPLY_CONTEXT_LINES = WINDOW_CONTEXT_LINES + 3

---@param lines string[] original whole-buffer lines
---@param start_lnum integer 1-indexed first line of the selection
---@param finish_lnum integer 1-indexed last line of the selection
---@param padding integer whole lines to keep on each side, clamped at the file bounds
---@return integer source_start_lnum
---@return integer source_finish_lnum
local function padded_range(lines, start_lnum, finish_lnum, padding)
  if start_lnum < 1 or finish_lnum < start_lnum or finish_lnum > #lines then error("selection range out of bounds") end
  return math.max(1, start_lnum - padding), math.min(#lines, finish_lnum + padding)
end

---Crop a buffer around a selected range for the apply model.
---@param lines string[] original whole-buffer lines
---@param start_lnum integer 1-indexed first line of the selection
---@param finish_lnum integer 1-indexed last line of the selection
---@return string[] cropped_lines
---@return integer cropped_start_lnum selection start relative to cropped_lines
---@return integer cropped_finish_lnum selection finish relative to cropped_lines
---@return integer source_start_lnum first whole-buffer line included in the crop
---@return integer source_finish_lnum last whole-buffer line included in the crop
function M.crop_around_selection(lines, start_lnum, finish_lnum)
  local source_start_lnum, source_finish_lnum = padded_range(lines, start_lnum, finish_lnum, APPLY_CONTEXT_LINES)
  local cropped_lines = {}
  for lnum = source_start_lnum, source_finish_lnum do
    cropped_lines[#cropped_lines + 1] = lines[lnum]
  end
  return cropped_lines,
    start_lnum - source_start_lnum + 1,
    finish_lnum - source_start_lnum + 1,
    source_start_lnum,
    source_finish_lnum
end

---The edit window the drafting model regenerates: the selection plus a few lines
---of context on each side, always whole lines.
---@param lines string[] original whole-buffer lines
---@param start_lnum integer 1-indexed first line of the selection
---@param finish_lnum integer 1-indexed last line of the selection
---@return integer window_start_lnum
---@return integer window_finish_lnum
function M.window_around_selection(lines, start_lnum, finish_lnum)
  return padded_range(lines, start_lnum, finish_lnum, WINDOW_CONTEXT_LINES)
end

---The span of the file the drafting model is shown for comprehension. Much wider
---than the window it rewrites and than the crop the apply model merges into.
---@param lines string[] original whole-buffer lines
---@param start_lnum integer 1-indexed first line of the selection
---@param finish_lnum integer 1-indexed last line of the selection
---@return integer context_start_lnum
---@return integer context_finish_lnum
function M.draft_context_around_selection(lines, start_lnum, finish_lnum)
  return padded_range(lines, start_lnum, finish_lnum, DRAFT_CONTEXT_LINES)
end

---Align model output against the original context lines around a selection and
---return only the lines that belong to the selection region, discarding the
---model's version of the context. The greedy strip-level match tolerates the
---drift weak models produce when asked to copy code byte-for-byte (dropped
---blank lines, whitespace changes). Callers restore the original context
---around the returned region.
---@param orig_lines string[] the span the model was asked to reproduce
---@param model_lines string[] what the model (or Morph) actually produced
---@param n_before integer context lines before the selection in orig_lines
---@param n_after integer context lines after the selection in orig_lines
---@return string[] region_lines the model's selection region
function M.fuzzy_align_region(orig_lines, model_lines, n_before, n_after)
  local function stripped(s) return s:gsub("^%s+", ""):gsub("%s+$", "") end
  local i, j = 1, 1
  while i <= n_before and j <= #model_lines do
    if stripped(orig_lines[i]) == stripped(model_lines[j]) then
      i = i + 1
      j = j + 1
    else
      i = i + 1 -- context line the model dropped or rewrote: discard it
    end
  end
  local k, m = 0, 0 -- counted from the end
  while k < n_after and m < #model_lines - j + 1 do
    if stripped(orig_lines[#orig_lines - k]) == stripped(model_lines[#model_lines - m]) then
      k = k + 1
      m = m + 1
    else
      k = k + 1
    end
  end
  local region = {}
  for idx = j, #model_lines - m do
    region[#region + 1] = model_lines[idx]
  end
  return region
end

---Merge `update` into `original_code` via the Morph apply model.
---Calls `on_complete(merged, nil)` on success, `on_complete(nil, err)` on failure.
---@param original_code string
---@param update string
---@param instructions string surgical, boring apply instruction (the change lives in `update`)
---@param on_complete fun(merged: string|nil, err: string|nil)
function M.apply(original_code, update, instructions, on_complete)
  local provider = Providers["morph"]
  if not provider then return on_complete(nil, "morph provider not found") end
  if not provider.is_env_set() then return on_complete(nil, "morph provider not configured (set MORPH_API_KEY)") end

  local provider_conf = Providers.parse_config(provider)
  local body = {
    model = provider_conf.model,
    messages = {
      {
        role = "user",
        content = "<instruction>"
          .. (instructions or "")
          .. "</instruction>\n<code>"
          .. original_code
          .. "</code>\n<update>"
          .. update
          .. "</update>",
      },
    },
  }

  local body_file = vim.fn.tempname() .. "-morph-request.json"
  vim.fn.writefile(vim.split(vim.json.encode(body), "\n"), body_file)

  local curl_cmd = { "curl", "-s", "-X", "POST", "-H", "Content-Type: application/json" }
  if Providers.env.require_api_key(provider_conf) then
    vim.list_extend(curl_cmd, { "-H", "Authorization: Bearer " .. provider.parse_api_key() })
  end
  vim.list_extend(curl_cmd, {
    "-d",
    "@" .. body_file,
    "--connect-timeout",
    "30",
    "--max-time",
    "120",
    Utils.url_join(provider_conf.endpoint, "/chat/completions"),
  })

  vim.system(
    curl_cmd,
    { text = true },
    vim.schedule_wrap(function(result)
      vim.fn.delete(body_file)
      if result.code ~= 0 then
        return on_complete(
          nil,
          "morph curl failed (" .. result.code .. "): " .. (result.stderr or result.stdout or "")
        )
      end
      local ok, jsn = pcall(vim.json.decode, result.stdout or "")
      if not ok then return on_complete(nil, "morph: could not parse response: " .. (result.stdout or "")) end
      -- Morph still returns 200 with an `error` body for e.g. credit issues.
      if jsn.error then
        local msg = type(jsn.error) == "table" and (jsn.error.message or vim.inspect(jsn.error)) or tostring(jsn.error)
        return on_complete(nil, "morph: " .. msg)
      end
      if not (jsn.choices and jsn.choices[1] and jsn.choices[1].message) then
        return on_complete(nil, "morph: invalid response shape")
      end
      on_complete(jsn.choices[1].message.content, nil)
    end)
  )
end

---@class AvanteMorphRejectDetail
---@field where "before"|"after"|"length"|"prefix"|"suffix"|"unchanged"|"emptied"
---@field lnum? integer 1-indexed buffer line of the stray change
---@field orig? string original content of the line that changed
---@field merged? string what the merge turned it into

---Confine a whole-file Morph merge back to the originally selected region.
---When Morph is handed the entire file as context (so it can place an anchored
---edit accurately) it returns the whole merged file. This checks that every line
---OUTSIDE the selection is byte-identical to the original and returns just the new
---lines that replace the selection. It is the client-side guard against Morph
---editing the wrong place -- e.g. an unanchored snippet landing on a different,
---similar-looking row elsewhere in the file.
---@param orig_lines string[] original whole-buffer lines (1-indexed)
---@param merged_lines string[] Morph's merged whole-buffer lines
---@param start_lnum integer 1-indexed first line of the selection
---@param finish_lnum integer 1-indexed last line of the selection
---@return string[]|nil region_lines new lines for the selection, or nil on mismatch
---@return string|nil err where the merge strayed outside the selected region
---@return AvanteMorphRejectDetail|nil detail content-based description of the stray change, for callers that relay the rejection to a model that never sees line numbers
function M.scoped_region_change(orig_lines, merged_lines, start_lnum, finish_lnum)
  -- Trailing blank lines at EOF are not meaningful and Morph routinely normalizes
  -- them (e.g. drops a final empty line). Ignore them on both sides so a benign
  -- EOF whitespace change outside the selection doesn't reject a clean merge. We
  -- never trim past the end of the selection, so this stays purely about EOF.
  local function content_len(t)
    local n = #t
    while n > 0 and t[n]:match("^%s*$") do
      n = n - 1
    end
    return n
  end
  local orig_n = math.max(content_len(orig_lines), finish_lnum)
  local merged_n = content_len(merged_lines)

  -- Same story one level down: Morph also strips trailing whitespace from a line it
  -- otherwise leaves alone (e.g. a stray space on the last line becomes no space).
  -- The lines outside the selection are discarded anyway -- we only splice Morph's
  -- region back in and keep the buffer's own copy of everything else -- so a trailing
  -- whitespace-only difference there must not reject the whole merge. Compare the
  -- unchanged context with trailing whitespace ignored.
  local function same_outside(a, b) return a == b or a:gsub("%s+$", "") == b:gsub("%s+$", "") end

  local n_before = start_lnum - 1
  local n_after = orig_n - finish_lnum
  if n_before < 0 or n_after < 0 then return nil, "selection range out of bounds" end
  if merged_n < n_before + n_after then
    return nil, "merged output is shorter than the unchanged context around the selection", { where = "length" }
  end
  for i = 1, n_before do
    if not same_outside(merged_lines[i], orig_lines[i]) then
      return nil,
        ("Morph changed line %d, before the selected region"):format(i),
        { where = "before", lnum = i, orig = orig_lines[i], merged = merged_lines[i] }
    end
  end
  for k = 0, n_after - 1 do
    if not same_outside(merged_lines[merged_n - k], orig_lines[orig_n - k]) then
      return nil,
        ("Morph changed line %d, after the selected region"):format(orig_n - k),
        { where = "after", lnum = orig_n - k, orig = orig_lines[orig_n - k], merged = merged_lines[merged_n - k] }
    end
  end
  local region = {}
  for i = n_before + 1, merged_n - n_after do
    region[#region + 1] = merged_lines[i]
  end
  return region, nil
end

---Second half of the guard, for selections that start or end mid-line.
---`scoped_region_change` only sees whole lines, so it cannot tell that the user
---selected one cell of a row: check that the unselected text on the two boundary
---lines came back byte-for-byte.
---@param region string[] the new lines replacing the selected lines
---@param prefix string text on the first selected line before the selection
---@param suffix string text on the last selected line after the selection
---@return string|nil err nil when both boundaries survived
---@return AvanteMorphRejectDetail|nil detail
---A selection is free to grow across lines (making a signature or a JSON array
---multi-line is a normal request), so the prefix only has to lead the region's
---first line and the suffix only has to trail its last. Trailing whitespace on
---the suffix is ignored for the same reason it is ignored above: Morph strips it
---on lines it otherwise leaves alone. Leading whitespace in the prefix is real
---indentation, so it is compared byte for byte.
function M.check_region_boundaries(region, prefix, suffix)
  local suffix_t = suffix:gsub("%s+$", "")
  if prefix == "" and suffix_t == "" then return nil end
  if #region == 0 then
    return "the whole selected line was deleted, including the text outside the selection",
      { where = "prefix", orig = prefix, merged = "" }
  end
  if #region == 1 and #region[1] < #prefix + #suffix_t then
    return "the line came back too short to still contain the text outside the selection",
      { where = "prefix", orig = prefix, merged = region[1] }
  end
  if prefix ~= "" and region[1]:sub(1, #prefix) ~= prefix then
    return "the text before the selection, on the selection's own line, was changed",
      { where = "prefix", orig = prefix, merged = region[1] }
  end
  local last = region[#region]:gsub("%s+$", "")
  if suffix_t ~= "" and last:sub(-#suffix_t) ~= suffix_t then
    return "the text after the selection, on the selection's own line, was changed",
      { where = "suffix", orig = suffix, merged = region[#region] }
  end
  return nil
end

return M
