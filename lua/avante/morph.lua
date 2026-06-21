local Providers = require("avante.providers")
local Utils = require("avante.utils")

---Thin client for the Morph fast-apply model. Given the original code and a lazy
---edit snippet (an "update"), Morph merges them and returns the complete updated
---code. The <instruction>/<code>/<update> request shape is what Morph V3 expects.
---@class avante.Morph
local M = {}

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

  local n_before = start_lnum - 1
  local n_after = orig_n - finish_lnum
  if n_before < 0 or n_after < 0 then return nil, "selection range out of bounds" end
  if merged_n < n_before + n_after then
    return nil, "merged output is shorter than the unchanged context around the selection"
  end
  for i = 1, n_before do
    if merged_lines[i] ~= orig_lines[i] then
      return nil, ("Morph changed line %d, before the selected region"):format(i)
    end
  end
  for k = 0, n_after - 1 do
    if merged_lines[merged_n - k] ~= orig_lines[orig_n - k] then
      return nil, ("Morph changed line %d, after the selected region"):format(orig_n - k)
    end
  end
  local region = {}
  for i = n_before + 1, merged_n - n_after do
    region[#region + 1] = merged_lines[i]
  end
  return region, nil
end

return M
