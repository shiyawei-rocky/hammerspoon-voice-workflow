local M = {}

function M.cfg_value(value, default)
    if value == nil then
        return default
    end
    return value
end

function M.sh_escape(s)
    return "'" .. tostring(s):gsub("'", [=['\"'\"']=]) .. "'"
end

function M.trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.ensure_dir(path)
    if not path or path == "" then
        return
    end
    hs.execute("mkdir -p " .. M.sh_escape(path), true)
end

return M
