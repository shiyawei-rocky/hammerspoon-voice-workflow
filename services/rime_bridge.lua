local M = {}

local dispatch_map = {}
local get_busy_reason = nil

local function normalize_action(action)
    if type(action) ~= "string" then
        return nil
    end
    local v = action:lower():gsub("^%s+", ""):gsub("%s+$", "")
    if v == "" then
        return nil
    end
    if not v:match("^[a-z_]+$") then
        return nil
    end
    return v
end

function M.setup(opts)
    opts = opts or {}
    dispatch_map = opts.actions or {}
    get_busy_reason = opts.get_busy_reason
end

function M.dispatch(action)
    local normalized = normalize_action(action)
    if not normalized then
        return "ERR:invalid_action"
    end
    if type(get_busy_reason) ~= "function" then
        return "ERR:not_ready"
    end
    local reason = get_busy_reason()
    if reason then
        hs.printf("[whisper] rime dispatch blocked: action=%s reason=%s", normalized, tostring(reason))
        return "ERR:busy"
    end
    local fn = dispatch_map[normalized]
    if type(fn) ~= "function" then
        return "ERR:unsupported_action"
    end
    local ok, err = pcall(fn)
    if not ok then
        hs.printf("[whisper] rime dispatch failed: action=%s error=%s", normalized, tostring(err))
        return "ERR:execution_failed"
    end
    hs.printf("[whisper] rime dispatch accepted: action=%s", normalized)
    return "OK:" .. normalized
end

return M
