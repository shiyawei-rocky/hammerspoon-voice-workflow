-- LLM 服务层：统一 LLM 请求接口
-- 职责：API Key 管理、请求 ID 管理、Prompt 加载、错误处理

local M = {}
local sh_escape = require("lib.utils").sh_escape

-- ========================================
-- 内部状态
-- ========================================
local current_request_id = nil
local llm_config = nil  -- 由 init() 设置
local cfg = nil         -- 由 init() 设置
local key_pool = nil
local next_key_index = 1
local bad_key_until = {}
local key_rotation = {
    strategy = "round_robin",
    retry_on = { "401", "429", "5xx" },
    max_switches = 2,
    bad_key_cooldown_sec = 1800,
}
local refresh_key_state

-- Prompt 文件路径（动态设置）
local PROMPTS_FILE = nil
local GLOSSARY_FILE = nil

-- 节流：每类错误只提示一次
local prompt_alert_shown = {
    file_missing = false,
    json_error = false,
    key_missing = {},
}

-- ========================================
-- 初始化接口（由 init.lua 调用）
-- ========================================
function M.init(config)
    if not config or type(config) ~= "table" then
        error("llm.init: 配置缺失")
    end
    if not config.llm then
        error("llm.init: 配置缺失 cfg.llm")
    end
    if not config.paths or not config.paths.script_dir then
        error("llm.init: 配置缺失 cfg.paths.script_dir")
    end
    cfg = config
    llm_config = config.llm
    local script_dir = config.paths.script_dir
    PROMPTS_FILE = script_dir .. "/prompts/prompts.json"
    GLOSSARY_FILE = script_dir .. "/prompts/glossary.txt"
    refresh_key_state()
end

local function get_app_style()
    if cfg and cfg.features and cfg.features.enable_app_style == false then
        return nil, nil
    end
    if not cfg or not cfg.app_styles then
        return nil, nil
    end
    local app = hs.application.frontmostApplication()
    if not app then
        return nil, nil
    end
    local bundle = app:bundleID()
    local name = app:name()
    if bundle and cfg.app_styles.bundle_id and cfg.app_styles.bundle_id[bundle] then
        return cfg.app_styles.bundle_id[bundle], name or bundle
    end
    if name and cfg.app_styles.app_name and cfg.app_styles.app_name[name] then
        return cfg.app_styles.app_name[name], name
    end
    return nil, name
end

function M.apply_app_style(system_prompt)
    local style, app_name = get_app_style()
    if style and style ~= "" then
        hs.printf("[whisper] App style: %s", app_name or "unknown")
        return system_prompt .. "\n\n场景风格要求：" .. style
    end
    return system_prompt
end

-- ========================================
-- 辅助函数
-- ========================================

local function normalize_chat_endpoint(url)
    if type(url) ~= "string" then
        return nil
    end
    local value = url:gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then
        return nil
    end
    if value:match("/chat/completions/?$") then
        return value
    end
    if value:match("/v1/?$") then
        return value:gsub("/?$", "") .. "/chat/completions"
    end
    return value
end

-- 请求 ID 管理
local function new_request_id()
    local id = string.format("%d_%d", os.time(), math.random(1000, 9999))
    current_request_id = id
    return id
end

local function is_request_active(id)
    return id ~= nil and id == current_request_id
end

function M.invalidate_requests()
    current_request_id = nil
end

-- API Key 获取
local function load_key_from_keychain(service, account)
    if not service or service == "" then
        return nil
    end
    local cmd = string.format("security find-generic-password -s %s -a %s -w 2>/dev/null",
                              sh_escape(service), sh_escape(account or ""))
    local out = hs.execute(cmd, true) or ""
    out = out:gsub("%s+$", "")
    if out == "" then
        return nil
    end
    return out
end

local function split_keys(raw)
    local out = {}
    if type(raw) ~= "string" then
        return out
    end
    for token in raw:gmatch("[^,%s]+") do
        if token ~= "" then
            table.insert(out, token)
        end
    end
    return out
end

local function load_key_pool()
    if not llm_config then
        return {}
    end
    local pool = {}
    local seen = {}
    local function add_key(value, source)
        if type(value) ~= "string" or value == "" or seen[value] then
            return
        end
        seen[value] = true
        table.insert(pool, { value = value, source = source })
    end

    local lock_key_sources = llm_config.lock_key_sources == true
    if not lock_key_sources then
        local env_candidates = {}
        local seen_env = {}
        local function add_env(name)
            if type(name) ~= "string" or name == "" or seen_env[name] then
                return
            end
            seen_env[name] = true
            table.insert(env_candidates, name)
        end
        add_env(llm_config.api_key_env)
        if type(llm_config.api_key_envs) == "table" then
            for _, name in ipairs(llm_config.api_key_envs) do
                add_env(name)
            end
        end
        add_env("SILICONFLOW_API_KEY")
        add_env("ZHONGZHUAN_API_KEY")
        add_env("OPENAI_API_KEY")
        for _, env_name in ipairs(env_candidates) do
            local raw = os.getenv(env_name) or ""
            if raw ~= "" then
                local keys = split_keys(raw)
                if #keys == 0 then
                    add_key(raw, "env:" .. env_name)
                else
                    for _, key in ipairs(keys) do
                        add_key(key, "env:" .. env_name)
                    end
                end
            end
        end
    else
        hs.printf("[whisper] LLM lock_key_sources=true: skip env keys")
    end

    local keychain_candidates = {}
    local seen_keychain = {}
    local function add_keychain(service, account)
        if type(service) ~= "string" or service == "" then
            return
        end
        local k = service .. "\0" .. tostring(account or "")
        if seen_keychain[k] then
            return
        end
        seen_keychain[k] = true
        table.insert(keychain_candidates, { service = service, account = account or "" })
    end
    local strict_candidates = llm_config.strict_keychain_candidates == true
    if type(llm_config.keychain_candidates) == "table" then
        for _, item in ipairs(llm_config.keychain_candidates) do
            if type(item) == "table" then
                add_keychain(item.service, item.account)
            end
        end
    elseif not strict_candidates then
        add_keychain(llm_config.keychain_service, llm_config.keychain_account)
    end

    if not strict_candidates then
        add_keychain("siliconflow", "siliconflow")
        add_keychain("siliconflow", "siliconflow_2")
        add_keychain("siliconflow", "siliconflow_3")
        add_keychain("siliconflow", "siliconflow_4")
        local endpoint = tostring(llm_config.endpoint or "")
        local service = tostring(llm_config.keychain_service or "")
        local use_zhongzhuan = endpoint:find("zhongzhuan", 1, true) ~= nil
            or service == "zhongzhuan"
        if use_zhongzhuan then
            add_keychain("zhongzhuan", "default")
            add_keychain("zhongzhuan", "default_2")
            add_keychain("zhongzhuan", "default_3")
        end
    else
        hs.printf("[whisper] LLM strict_keychain_candidates=true: only use configured candidates")
    end
    for _, item in ipairs(keychain_candidates) do
        local key = load_key_from_keychain(item.service, item.account)
        if key then
            add_key(key, string.format("keychain:%s/%s", item.service, item.account))
        end
    end

    local safe_limit = tonumber(llm_config.safe_key_limit) or 0
    if safe_limit > 0 and #pool > safe_limit then
        local limited = {}
        for i = 1, math.floor(safe_limit) do
            if pool[i] then
                table.insert(limited, pool[i])
            end
        end
        hs.printf("[whisper] LLM safe_key_limit enabled: using %d/%d keys", #limited, #pool)
        return limited
    end

    return pool
end

local function normalize_retry_tokens(tokens)
    local defaults = { "401", "429", "5xx" }
    local out = {}
    if type(tokens) ~= "table" then
        return defaults
    end
    for _, token in ipairs(tokens) do
        if type(token) == "string" then
            local v = token:gsub("^%s+", ""):gsub("%s+$", "")
            if v ~= "" then
                table.insert(out, v)
            end
        end
    end
    if #out == 0 then
        return defaults
    end
    return out
end

local function body_looks_like_json(body)
    if type(body) ~= "string" then
        return false
    end
    local trimmed = body:match("^%s*(.-)%s*$")
    if not trimmed or trimmed == "" then
        return false
    end
    local first = trimmed:sub(1, 1)
    return first == "{" or first == "["
end

local function prune_bad_keys(now_sec)
    local now = now_sec or os.time()
    for key, expires_at in pairs(bad_key_until) do
        if type(expires_at) ~= "number" or expires_at <= now then
            bad_key_until[key] = nil
        end
    end
end

local function is_key_blocked(value, now_sec)
    if type(value) ~= "string" or value == "" then
        return false
    end
    local expires_at = bad_key_until[value]
    if type(expires_at) ~= "number" then
        return false
    end
    local now = now_sec or os.time()
    if expires_at <= now then
        bad_key_until[value] = nil
        return false
    end
    return true
end

local function mark_key_bad(value)
    if type(value) ~= "string" or value == "" then
        return
    end
    local cooldown = tonumber(key_rotation.bad_key_cooldown_sec) or 1800
    if cooldown < 60 then
        cooldown = 60
    end
    bad_key_until[value] = os.time() + math.floor(cooldown)
end

local function load_key_rotation()
    local cfg_rot = llm_config and llm_config.key_rotation or {}
    local strategy = "round_robin"
    if type(cfg_rot.strategy) == "string" and cfg_rot.strategy ~= "" then
        strategy = cfg_rot.strategy
    end
    local max_switches = tonumber(cfg_rot.max_switches) or 2
    if max_switches < 0 then
        max_switches = 0
    end
    local bad_key_cooldown_sec = tonumber(cfg_rot.bad_key_cooldown_sec) or 1800
    if bad_key_cooldown_sec < 60 then
        bad_key_cooldown_sec = 60
    end
    return {
        strategy = strategy,
        max_switches = math.floor(max_switches),
        retry_on = normalize_retry_tokens(cfg_rot.retry_on),
        bad_key_cooldown_sec = math.floor(bad_key_cooldown_sec),
    }
end

refresh_key_state = function()
    key_pool = load_key_pool()
    key_rotation = load_key_rotation()
    prune_bad_keys()
    if next_key_index < 1 or next_key_index > #key_pool then
        next_key_index = 1
    end
end

local function ensure_key_pool()
    if not key_pool or #key_pool == 0 then
        refresh_key_state()
    end
    return key_pool and #key_pool > 0
end

local function is_retryable_status(status, retry_tokens)
    local code = tonumber(status) or -1
    local tokens = retry_tokens or key_rotation.retry_on or {}
    for _, token in ipairs(tokens) do
        if token == "5xx" and code >= 500 and code < 600 then
            return true
        end
        local n = tonumber(token)
        if n and code == n then
            return true
        end
    end
    return false
end

local function select_next_available_index(start_idx)
    if not ensure_key_pool() then
        return nil
    end
    local count = #key_pool
    if count == 0 then
        return nil
    end
    local start = tonumber(start_idx) or 1
    if start < 1 or start > count then
        start = 1
    end
    local idx = start
    local now = os.time()
    for _ = 1, count do
        local entry = key_pool[idx]
        if entry and entry.value and not is_key_blocked(entry.value, now) then
            return idx
        end
        idx = (idx % count) + 1
    end
    return nil
end

local function select_key_index()
    if not ensure_key_pool() then
        return nil
    end
    local idx = 1
    if key_rotation.strategy == "round_robin" then
        idx = next_key_index
    end
    local selected = select_next_available_index(idx)
    if not selected then
        return nil
    end
    next_key_index = (selected % #key_pool) + 1
    return selected
end

-- Prompt 加载（热加载）
local function load_prompt(key)
    local f = io.open(PROMPTS_FILE, "r")
    if not f then
        hs.printf("[whisper] ERROR: Cannot open prompts file: %s", PROMPTS_FILE)
        if not prompt_alert_shown.file_missing then
            hs.alert.show("⚠️ prompts.json 缺失，使用内置 Prompt", 2)
            prompt_alert_shown.file_missing = true
        end
        return nil
    end
    local content = f:read("*all")
    f:close()

    local ok, prompts = pcall(hs.json.decode, content)
    if not ok or not prompts then
        hs.printf("[whisper] ERROR: JSON parse failed in prompts.json")
        if not prompt_alert_shown.json_error then
            hs.alert.show("⚠️ prompts.json 格式错误，使用内置 Prompt", 2)
            prompt_alert_shown.json_error = true
        end
        return nil
    end

    if prompts[key] then
        return prompts[key]
    end

    hs.printf("[whisper] WARNING: Prompt key not found: %s", key)
    if not prompt_alert_shown.key_missing[key] then
        hs.alert.show("⚠️ Prompt key 缺失: " .. key, 2)
        prompt_alert_shown.key_missing[key] = true
    end
    return nil
end

-- Glossary 加载
local glossary_cache = nil
local glossary_mtime = nil
local glossary_terms = nil

local function parse_glossary_terms(content)
    local terms = {}
    for line in content:gmatch("[^\r\n]+") do
        if line:match("^%s*#") or line:match("^%s*$") then
            goto continue
        end
        local left, right = line:match("^(.-)=(.-)$")
        if left and right then
            left = left:gsub("^%s*(.-)%s*$", "%1")
            right = right:gsub("^%s*(.-)%s*$", "%1")
            if #left >= 2 then
                table.insert(terms, left)
            end
            if #right >= 2 then
                table.insert(terms, right)
            end
        else
            local term = line:gsub("^%s*(.-)%s*$", "%1")
            if #term >= 2 then
                table.insert(terms, term)
            end
        end
        ::continue::
    end
    return terms
end

local function load_glossary()
    if not GLOSSARY_FILE then
        return nil
    end
    local attr = hs.fs.attributes(GLOSSARY_FILE)
    if glossary_cache and attr and glossary_mtime == attr.modification then
        return glossary_cache
    end
    local f = io.open(GLOSSARY_FILE, "r")
    if not f then
        glossary_cache = nil
        glossary_terms = nil
        return nil
    end
    local content = f:read("*all") or ""
    f:close()
    local trimmed = content:gsub("^%s*(.-)%s*$", "%1")
    if trimmed == "" then
        glossary_cache = nil
        glossary_terms = nil
        return nil
    end
    glossary_cache = trimmed
    glossary_terms = parse_glossary_terms(trimmed)
    glossary_mtime = attr and attr.modification or nil
    return glossary_cache
end

local function glossary_hits(text)
    if not text or text == "" or not glossary_terms then
        return false
    end
    for _, term in ipairs(glossary_terms) do
        if text:find(term, 1, true) then
            return true
        end
    end
    return false
end

-- HTTP 错误格式化
local function format_http_error(status, body)
    local error_msg = string.format("HTTP %d", status or -1)
    if (tonumber(status) or -1) == -1 then
        return error_msg
    end
    if body_looks_like_json(body) then
        local ok, err_data = pcall(hs.json.decode, body)
        if ok and err_data and err_data.error and err_data.error.message then
            error_msg = error_msg .. ": " .. err_data.error.message
        end
    end
    return error_msg
end

-- LLM 响应解析
local function parse_llm_content(body)
    local ok, data = pcall(hs.json.decode, body or "")
    if not (ok and data and data.choices and data.choices[1] and data.choices[1].message) then
        return nil
    end
    local content = data.choices[1].message.content
    if type(content) == "string" then
        return content
    end
    if type(content) == "table" then
        local parts = {}
        for _, item in ipairs(content) do
            if type(item) == "string" then
                table.insert(parts, item)
            elseif type(item) == "table" and type(item.text) == "string" then
                table.insert(parts, item.text)
            end
        end
        if #parts > 0 then
            return table.concat(parts)
        end
    end
    return nil
end

-- ========================================
-- 统一 LLM 请求接口
-- ========================================

function M.request(opts, callback)
    opts = opts or {}

    -- 参数验证
    if not opts.text then
        callback(nil, "missing text parameter")
        return
    end

    if not llm_config.enabled then
        callback(opts.text, nil)
        return
    end

    if not ensure_key_pool() then
        callback(opts.text, "API key not found")
        return
    end

    -- Prompt 加载策略：prompt_key > system_prompt > 内置
    local system_prompt = opts.system_prompt or llm_config.system_prompt
    if opts.prompt_key then
        system_prompt = load_prompt(opts.prompt_key) or system_prompt
        hs.printf("[whisper] Using prompt key: %s", opts.prompt_key)
    end

    -- Glossary 附加
    if opts.use_glossary then
        local glossary = load_glossary()
        local only_on_hit = cfg and cfg.lexicon and cfg.lexicon.use_glossary_only_on_hit
        if glossary then
            if only_on_hit and not glossary_hits(opts.text) then
                hs.printf("[whisper] Glossary skipped: no hit")
            else
                system_prompt = system_prompt .. "\n\n术语表（优先使用）：\n" .. glossary
                hs.printf("[whisper] Glossary loaded: %d chars", #glossary)
            end
        end
    end

    system_prompt = M.apply_app_style(system_prompt)

    -- 模型选择
    local explicit_model = nil
    if type(opts.model) == "string" then
        local s = opts.model:gsub("^%s+", ""):gsub("%s+$", "")
        if s ~= "" then
            explicit_model = s
        end
    end
    local model = explicit_model or llm_config.models[opts.model_type or "fast"] or llm_config.default_model
    hs.printf("[whisper] Using model: %s", model)

    -- 请求 ID
    local request_id = new_request_id()
    local endpoint = normalize_chat_endpoint(llm_config.endpoint)
    if not endpoint then
        callback(opts.text, "LLM endpoint is empty")
        return
    end

    -- 构造 payload
    local user_prompt = opts.user_prompt or opts.text
    local payload = hs.json.encode({
        model = model,
        messages = {
            { role = "system", content = system_prompt },
            { role = "user", content = user_prompt },
        },
        temperature = llm_config.temperature,
    })

    local initial_key_idx = select_key_index()
    if not initial_key_idx then
        callback(opts.text, "API key not found")
        return
    end
    local max_switches = key_rotation.max_switches or 2
    if #key_pool <= 1 then
        max_switches = 0
    elseif max_switches > (#key_pool - 1) then
        max_switches = #key_pool - 1
    end

    -- 重试逻辑
    local enable_retry = opts.enable_retry
    if enable_retry == nil then
        enable_retry = true  -- 默认启用重试
    end
    local max_retries = tonumber(opts.max_retries)
    if max_retries == nil then
        max_retries = enable_retry and 1 or 0
    end
    if max_retries < 0 then
        max_retries = 0
    end
    local retry_on_statuses = nil
    if opts.retry_on_statuses ~= nil then
        if type(opts.retry_on_statuses) == "table" then
            retry_on_statuses = {}
            for _, token in ipairs(opts.retry_on_statuses) do
                if type(token) == "string" then
                    local value = token:gsub("^%s+", ""):gsub("%s+$", "")
                    if value ~= "" then
                        table.insert(retry_on_statuses, value)
                    end
                end
            end
        else
            retry_on_statuses = normalize_retry_tokens(opts.retry_on_statuses)
        end
    else
        retry_on_statuses = normalize_retry_tokens(key_rotation.retry_on)
    end
    local request_timeout_sec = tonumber(opts.request_timeout_sec)
    if request_timeout_sec and request_timeout_sec > 0 then
        request_timeout_sec = math.max(1, math.floor(request_timeout_sec))
    else
        request_timeout_sec = nil
    end
    local completed = false
    local timeout_timer = nil

    local function finish_once(result, error)
        if completed then
            return
        end
        completed = true
        if timeout_timer then
            timeout_timer:stop()
            timeout_timer = nil
        end
        if is_request_active(request_id) then
            current_request_id = nil
        end
        callback(result, error)
    end

    if request_timeout_sec then
        timeout_timer = hs.timer.doAfter(request_timeout_sec, function()
            if completed or not is_request_active(request_id) then
                return
            end
            hs.printf("[whisper] LLM request timeout: request_id=%s timeout_sec=%d", tostring(request_id), request_timeout_sec)
            finish_once(opts.text, "HTTP timeout")
        end)
    end

    local function do_request(key_idx, retry_count, switch_count)
        if completed then
            return
        end
        local usable_idx = select_next_available_index(key_idx)
        if not usable_idx then
            finish_once(opts.text, "API key exhausted (all blocked)")
            return
        end
        key_idx = usable_idx
        local key_entry = key_pool[key_idx]
        if not key_entry or not key_entry.value then
            finish_once(opts.text, "API key index invalid")
            return
        end
        hs.printf("[whisper] Using key index: %d/%d", key_idx, #key_pool)
        local headers = {
            ["Authorization"] = "Bearer " .. key_entry.value,
            ["Content-Type"] = "application/json",
        }
        hs.http.asyncPost(endpoint, payload, headers, function(status, body, respHeaders)
            -- 检查请求是否过期
            if not is_request_active(request_id) then
                hs.printf("[whisper] Ignore stale LLM callback: %s", tostring(request_id))
                return
            end
            if completed then
                return
            end

            -- 错误处理
            if status ~= 200 then
                hs.printf("[whisper] LLM request failed: status=%d, retry=%d, switch=%d", status or -1, retry_count, switch_count)
                if status == 401 or status == 403 then
                    mark_key_bad(key_entry.value)
                end

                if is_retryable_status(status, retry_on_statuses) and switch_count < max_switches then
                    local next_idx = select_next_available_index((key_idx % #key_pool) + 1)
                    if next_idx then
                        hs.printf("[whisper] LLM key switch: %d -> %d (status=%d)", key_idx, next_idx, status or -1)
                        hs.timer.doAfter(0.2, function()
                            do_request(next_idx, 0, switch_count + 1)
                        end)
                        return
                    end
                end

                -- 重试
                if enable_retry and retry_count < max_retries then
                    hs.timer.doAfter(1, function()
                        do_request(key_idx, retry_count + 1, switch_count)
                    end)
                    return
                end

                -- 失败
                local error_msg = format_http_error(status, body)
                finish_once(opts.text, error_msg)
                return
            end

            -- 成功
            local content = parse_llm_content(body)
            if content and content ~= "" then
                finish_once(content, nil)
            else
                finish_once(opts.text, "parse failed")
            end
        end)
    end

    do_request(initial_key_idx, 0, 0)
end

M.load_prompt = load_prompt

return M
