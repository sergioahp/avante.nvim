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

return M
