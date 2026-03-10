-- ASR 服务层:统一 ASR 转录接口
-- 职责:ASR 请求 ID 管理、错误码映射、转录逻辑封装

local M = {}
local sanitize_utf8_or_keep = function(text)
    return tostring(text or ""), true
end
do
    local ok, normalize = pcall(require, "lib.normalize_numbers")
    if ok and type(normalize) == "table" and type(normalize.sanitize_utf8_or_keep) == "function" then
        sanitize_utf8_or_keep = normalize.sanitize_utf8_or_keep
    end
end

-- ========================================
-- 内部状态
-- ========================================
local active_requests = {}
local request_seq = 0
local CLOUD_TRANSCRIBE_SCRIPT = nil  -- 由 init() 设置
local ASR_TASK_TIMEOUT_SEC = 600
local PRIMARY_PROVIDER = nil
local FALLBACK_PROVIDER = nil
local FALLBACK_ENABLED = false
local FALLBACK_MODE = "session"
local FALLBACK_ON_ERRORS = { "asr_request_failed", "chunk_transcribe_failed", "asr_timeout", "invalid_json", "asr_text_repetition", "401", "403", "429", "5xx" }
local FALLBACK_CIRCUIT_WINDOW_SEC = 300
local FALLBACK_CIRCUIT_FAILURE_THRESHOLD = 3
local FALLBACK_CIRCUIT_COOLDOWN_SEC = 600
local fallback_fail_times = {}
local fallback_open_until = 0
local ASR_TEXT_MAX_CHARS = 5000

-- 错误码映射
local ASR_ERROR_MAP = {
    no_api_key = "缺少 ASR API Key",
    missing_jq = "缺少 jq",
    missing_ffmpeg = "缺少 ffmpeg",
    no_audio_file = "未找到录音文件",
    missing_model = "ASR 模型未配置",
    split_failed = "音频分段失败",
    asr_request_failed = "ASR 请求失败或超时",
    chunk_transcribe_failed = "分段转写失败",
    empty_transcription = "没有识别到语音",
    invalid_json = "ASR 响应解析失败",
    asr_text_repetition = "ASR 输出疑似重复退化",
    asr_timeout = "ASR 请求超时（可在 config.lua 的 limits.asr_task_timeout_sec 调整）",
}

local PRIMARY_DEFAULTS = {
    endpoint = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
    api_key_env = "DASHSCOPE_API_KEY",
    api_key_envs = "DASHSCOPE_API_KEY",
    keychain_service = "aliyun_dashscope",
    keychain_account = "default",
    keychain_candidates = "aliyun_dashscope:default,aliyun_dashscope:default_2,aliyun_dashscope:default_3,aliyun_dashscope:default_4",
    key_max_switches = 3,
    key_retry_on = "401,429,5xx",
    request_retry_on = "429,5xx,timeout",
    request_max_retries = 1,
    request_backoff_ms = 300,
    request_backoff_max_ms = 800,
    audio_normalize = "1",
    audio_sample_rate = "16000",
    audio_channels = "1",
    model = "qwen3-asr-flash",
    provider_name = "aliyun_dashscope",
}

local FALLBACK_DEFAULTS = {
    endpoint = "https://api.siliconflow.cn/v1/chat/completions",
    api_key_env = "SILICONFLOW_API_KEY",
    api_key_envs = "SILICONFLOW_API_KEY",
    keychain_service = "siliconflow",
    keychain_account = "siliconflow",
    keychain_candidates = "siliconflow:siliconflow,siliconflow:siliconflow_2",
    key_max_switches = 1,
    key_retry_on = "401,403,429,5xx",
    request_retry_on = "429,5xx,timeout",
    request_max_retries = 1,
    request_backoff_ms = 300,
    request_backoff_max_ms = 800,
    audio_normalize = "1",
    audio_sample_rate = "16000",
    audio_channels = "1",
    model = "Qwen/Qwen3-Omni-30B-A3B-Instruct",
    provider_name = "siliconflow",
}

-- ========================================
-- 初始化接口（由 init.lua 调用）
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

local function csv_from_list(values)
    if type(values) ~= "table" then
        return ""
    end
    local out = {}
    for _, v in ipairs(values) do
        if type(v) == "string" and v ~= "" then
            table.insert(out, v)
        end
    end
    return table.concat(out, ",")
end

local function keychain_candidates_csv(values)
    if type(values) ~= "table" then
        return ""
    end
    local out = {}
    for _, item in ipairs(values) do
        if type(item) == "table" and type(item.service) == "string" and item.service ~= "" then
            local account = ""
            if type(item.account) == "string" then
                account = item.account
            end
            table.insert(out, string.format("%s:%s", item.service, account))
        end
    end
    return table.concat(out, ",")
end

local function parse_provider(cfg, defaults, route)
    local provider = {
        route = route or "primary",
        endpoint = defaults.endpoint,
        api_key_env = defaults.api_key_env,
        api_key_envs = defaults.api_key_envs,
        keychain_service = defaults.keychain_service,
        keychain_account = defaults.keychain_account,
        keychain_candidates = defaults.keychain_candidates,
        key_max_switches = defaults.key_max_switches,
        key_retry_on = defaults.key_retry_on,
        request_retry_on = defaults.request_retry_on,
        request_max_retries = defaults.request_max_retries,
        request_backoff_ms = defaults.request_backoff_ms,
        request_backoff_max_ms = defaults.request_backoff_max_ms,
        audio_normalize = defaults.audio_normalize,
        audio_sample_rate = defaults.audio_sample_rate,
        audio_channels = defaults.audio_channels,
        model = defaults.model,
        provider_name = defaults.provider_name,
    }
    if type(cfg) ~= "table" then
        provider.endpoint = normalize_chat_endpoint(provider.endpoint) or provider.endpoint
        return provider
    end

    local endpoint = cfg.endpoint
    if type(endpoint) == "string" and endpoint ~= "" then
        provider.endpoint = endpoint
    end
    provider.endpoint = normalize_chat_endpoint(provider.endpoint) or provider.endpoint

    if type(cfg.api_key_env) == "string" and cfg.api_key_env ~= "" then
        provider.api_key_env = cfg.api_key_env
    end
    if type(cfg.api_key_envs) == "table" then
        local v = csv_from_list(cfg.api_key_envs)
        provider.api_key_envs = v ~= "" and v or provider.api_key_envs
    end
    if type(cfg.keychain_service) == "string" and cfg.keychain_service ~= "" then
        provider.keychain_service = cfg.keychain_service
    end
    if type(cfg.keychain_account) == "string" and cfg.keychain_account ~= "" then
        provider.keychain_account = cfg.keychain_account
    end
    if type(cfg.keychain_candidates) == "table" then
        local v = keychain_candidates_csv(cfg.keychain_candidates)
        provider.keychain_candidates = v ~= "" and v or provider.keychain_candidates
    end
    if type(cfg.key_rotation) == "table" then
        local rot = cfg.key_rotation
        if type(rot.retry_on) == "table" then
            local v = csv_from_list(rot.retry_on)
            provider.key_retry_on = v ~= "" and v or provider.key_retry_on
        end
        local max_switches = tonumber(rot.max_switches)
        if max_switches and max_switches >= 0 then
            provider.key_max_switches = math.floor(max_switches)
        end
    end
    if type(cfg.request_retry) == "table" then
        local req = cfg.request_retry
        if type(req.retry_on) == "table" then
            local v = csv_from_list(req.retry_on)
            provider.request_retry_on = v ~= "" and v or provider.request_retry_on
        end
        local max_retries = tonumber(req.max_retries)
        if max_retries and max_retries >= 0 then
            provider.request_max_retries = math.floor(max_retries)
        end
        local backoff_ms = tonumber(req.backoff_ms)
        if backoff_ms and backoff_ms > 0 then
            provider.request_backoff_ms = math.floor(backoff_ms)
        end
        local backoff_max_ms = tonumber(req.backoff_max_ms)
        if backoff_max_ms and backoff_max_ms > 0 then
            provider.request_backoff_max_ms = math.floor(backoff_max_ms)
        end
    end
    if type(cfg.audio) == "table" then
        if cfg.audio.normalize == false then
            provider.audio_normalize = "0"
        else
            provider.audio_normalize = "1"
        end
        local sample_rate = tonumber(cfg.audio.sample_rate)
        if sample_rate and sample_rate > 0 then
            provider.audio_sample_rate = tostring(math.floor(sample_rate))
        end
        local channels = tonumber(cfg.audio.channels)
        if channels and channels > 0 then
            provider.audio_channels = tostring(math.floor(channels))
        end
    end
    if type(cfg.model) == "string" and cfg.model ~= "" then
        provider.model = cfg.model
    end
    if type(cfg.provider_name) == "string" and cfg.provider_name ~= "" then
        provider.provider_name = cfg.provider_name
    end
    return provider
end

local function trim_fallback_failures(now_sec)
    local keep = {}
    for _, ts in ipairs(fallback_fail_times) do
        if now_sec - ts <= FALLBACK_CIRCUIT_WINDOW_SEC then
            table.insert(keep, ts)
        end
    end
    fallback_fail_times = keep
end

local function is_fallback_circuit_open(now_sec)
    if fallback_open_until <= 0 then
        return false
    end
    return now_sec < fallback_open_until
end

local function record_fallback_success()
    fallback_fail_times = {}
    fallback_open_until = 0
end

local function record_fallback_failure()
    local now_sec = os.time()
    trim_fallback_failures(now_sec)
    table.insert(fallback_fail_times, now_sec)
    if #fallback_fail_times >= FALLBACK_CIRCUIT_FAILURE_THRESHOLD then
        fallback_open_until = now_sec + FALLBACK_CIRCUIT_COOLDOWN_SEC
        fallback_fail_times = {}
        hs.printf(
            "[whisper] asr_fallback circuit open: cooldown=%ds threshold=%d",
            FALLBACK_CIRCUIT_COOLDOWN_SEC,
            FALLBACK_CIRCUIT_FAILURE_THRESHOLD
        )
    end
end

local function status_matches_token(status, token)
    if token == "" then
        return false
    end
    local numeric_status = tonumber(status)
    if token == "5xx" then
        return numeric_status and numeric_status >= 500 and numeric_status < 600 or false
    end
    return status == token
end

local function should_fallback(err_code, metrics)
    if not FALLBACK_ENABLED or not FALLBACK_PROVIDER then
        return false
    end
    local status = tostring(metrics and metrics.provider_status or "")
    local err = tostring(err_code or "")
    for _, token in ipairs(FALLBACK_ON_ERRORS) do
        if type(token) == "string" and token ~= "" then
            if err == token or status_matches_token(status, token) then
                return true
            end
        end
    end
    return false
end

function M.init(config)
    if not config or type(config) ~= "table" then
        error("asr.init: 配置缺失")
    end
    if not config.paths or not config.paths.script_dir then
        error("asr.init: 配置缺失 cfg.paths.script_dir")
    end
    local script_dir = config.paths.script_dir
    CLOUD_TRANSCRIBE_SCRIPT = script_dir .. "/whisper_cloud_transcribe.sh"
    local timeout = tonumber(config.limits and config.limits.asr_task_timeout_sec)
    if timeout and timeout > 0 then
        ASR_TASK_TIMEOUT_SEC = math.max(60, math.floor(timeout))
    end
    local asr_text_max_chars = tonumber(config.limits and config.limits.asr_text_max_chars)
    if asr_text_max_chars and asr_text_max_chars > 0 then
        ASR_TEXT_MAX_CHARS = math.max(256, math.floor(asr_text_max_chars))
    end

    local asr_cfg = config.asr or {}

    local primary_cfg = asr_cfg
    if (not primary_cfg.endpoint or primary_cfg.endpoint == "") and config.llm and config.llm.endpoint then
        primary_cfg = {}
        for k, v in pairs(asr_cfg) do
            primary_cfg[k] = v
        end
        primary_cfg.endpoint = config.llm.endpoint
    end
    PRIMARY_PROVIDER = parse_provider(primary_cfg, PRIMARY_DEFAULTS, "primary")

    local fallback_cfg = asr_cfg.fallback
    FALLBACK_ENABLED = type(fallback_cfg) == "table" and fallback_cfg.enabled ~= false
    FALLBACK_MODE = "session"
    FALLBACK_ON_ERRORS = { "asr_request_failed", "chunk_transcribe_failed", "asr_timeout", "invalid_json", "asr_text_repetition", "401", "403", "429", "5xx" }
    FALLBACK_CIRCUIT_WINDOW_SEC = 300
    FALLBACK_CIRCUIT_FAILURE_THRESHOLD = 3
    FALLBACK_CIRCUIT_COOLDOWN_SEC = 600
    fallback_fail_times = {}
    fallback_open_until = 0

    if FALLBACK_ENABLED and type(fallback_cfg) == "table" then
        FALLBACK_PROVIDER = parse_provider(fallback_cfg, FALLBACK_DEFAULTS, "fallback")
        if type(fallback_cfg.mode) == "string" and fallback_cfg.mode ~= "" then
            FALLBACK_MODE = fallback_cfg.mode
        end
        if type(fallback_cfg.on_errors) == "table" and #fallback_cfg.on_errors > 0 then
            local values = {}
            for _, token in ipairs(fallback_cfg.on_errors) do
                if type(token) == "string" and token ~= "" then
                    table.insert(values, token)
                end
            end
            if #values > 0 then
                FALLBACK_ON_ERRORS = values
            end
        end
        if type(fallback_cfg.circuit_breaker) == "table" then
            local cb = fallback_cfg.circuit_breaker
            local window_sec = tonumber(cb.window_sec)
            if window_sec and window_sec > 0 then
                FALLBACK_CIRCUIT_WINDOW_SEC = math.floor(window_sec)
            end
            local failure_threshold = tonumber(cb.failure_threshold)
            if failure_threshold and failure_threshold > 0 then
                FALLBACK_CIRCUIT_FAILURE_THRESHOLD = math.floor(failure_threshold)
            end
            local cooldown_sec = tonumber(cb.cooldown_sec)
            if cooldown_sec and cooldown_sec > 0 then
                FALLBACK_CIRCUIT_COOLDOWN_SEC = math.floor(cooldown_sec)
            end
        end
    else
        FALLBACK_PROVIDER = nil
        FALLBACK_ENABLED = false
    end
end

local function parse_metrics_from_stderr(stderr)
    if type(stderr) ~= "string" or stderr == "" then
        return nil
    end
    local metrics = {}
    local line = stderr:match("[^\r\n]*asr_metrics[^\r\n]*")
    if not line then
        return nil
    end
    for key, value in line:gmatch("([%w_]+)=([^%s]+)") do
        metrics[key] = value
    end
    if next(metrics) == nil then
        return nil
    end
    return metrics
end

-- ========================================
-- 辅助函数
-- ========================================

local function new_request_id()
    request_seq = request_seq + 1
    local id = string.format("%d_%d_%d", os.time(), hs.timer.absoluteTime(), request_seq)
    active_requests[id] = { task = nil }
    return id
end

local function is_request_active(id)
    return id ~= nil and active_requests[id] ~= nil
end

local function set_request_task(id, task)
    local req = active_requests[id]
    if req then
        req.task = task
    end
end

local function clear_request(id)
    local req = active_requests[id]
    if req then
        req.task = nil
        active_requests[id] = nil
    end
end

local function terminate_request(id)
    local req = active_requests[id]
    if req and req.task then
        pcall(function()
            req.task:terminate()
        end)
    end
    clear_request(id)
end

function M.invalidate_requests()
    for id, req in pairs(active_requests) do
        if req and req.task then
            pcall(function()
                req.task:terminate()
            end)
        end
        active_requests[id] = nil
    end
end

-- 错误格式化
function M.format_error(err)
    if not err or err == "" then
        return "未知错误"
    end
    return ASR_ERROR_MAP[err] or err
end

function M.runtime_info()
    local now_sec = os.time()
    local circuit_open = is_fallback_circuit_open(now_sec)
    local remaining = 0
    if circuit_open then
        remaining = math.max(0, fallback_open_until - now_sec)
    end
    return {
        provider = PRIMARY_PROVIDER and PRIMARY_PROVIDER.provider_name or "unknown",
        model = PRIMARY_PROVIDER and PRIMARY_PROVIDER.model or "unknown",
        endpoint = PRIMARY_PROVIDER and PRIMARY_PROVIDER.endpoint or "",
        api_key_env = PRIMARY_PROVIDER and PRIMARY_PROVIDER.api_key_env or "",
        keychain_service = PRIMARY_PROVIDER and PRIMARY_PROVIDER.keychain_service or "",
        keychain_account = PRIMARY_PROVIDER and PRIMARY_PROVIDER.keychain_account or "",
        fallback_enabled = FALLBACK_ENABLED and FALLBACK_PROVIDER ~= nil,
        fallback_provider = FALLBACK_PROVIDER and FALLBACK_PROVIDER.provider_name or "",
        fallback_model = FALLBACK_PROVIDER and FALLBACK_PROVIDER.model or "",
        fallback_mode = FALLBACK_MODE,
        fallback_circuit_open = circuit_open,
        fallback_circuit_remaining_sec = remaining,
    }
end

local function utf8_len_or_nil(text)
    local ok, len = pcall(utf8.len, text)
    if ok and type(len) == "number" then
        return len
    end
    return nil
end

local function utf8_prefix(text, max_chars)
    if max_chars <= 0 then
        return ""
    end
    local count = 0
    local out = {}
    for _, code in utf8.codes(text) do
        count = count + 1
        if count > max_chars then
            break
        end
        table.insert(out, utf8.char(code))
    end
    return table.concat(out)
end

local function has_repeated_lines(text)
    local prev = nil
    local run = 0
    for line in text:gmatch("[^\r\n]+") do
        local v = line:gsub("^%s*(.-)%s*$", "%1")
        if v ~= "" and #v >= 8 then
            if v == prev then
                run = run + 1
            else
                prev = v
                run = 1
            end
            if run >= 3 then
                return true
            end
        end
    end
    return false
end

local function has_repeated_chunks(text)
    if #text < 48 then
        return false
    end
    if text:find("(.)%1%1%1%1%1%1%1%1%1%1%1") then
        return true
    end
    local units = { 16, 24, 32, 48, 64, 80 }
    for _, unit in ipairs(units) do
        local limit = #text - (unit * 3) + 1
        if limit >= 1 then
            for i = 1, limit do
                local a = text:sub(i, i + unit - 1)
                local b_start = i + unit
                local c_start = i + (unit * 2)
                if a == text:sub(b_start, b_start + unit - 1) and a == text:sub(c_start, c_start + unit - 1) then
                    return true
                end
            end
        end
    end
    return false
end

-- ASR 响应解析
local function parse_asr_text(stdout)
    local ok, data = pcall(hs.json.decode, stdout or "")
    if not ok or type(data) ~= "table" then
        return nil, "invalid_json"
    end
    if data.error then
        return nil, tostring(data.error)
    end
    local raw_text = tostring(data.text or "")
    local text, valid_utf8 = sanitize_utf8_or_keep(raw_text)
    if not valid_utf8 then
        hs.printf("[whisper] asr_text sanitized: invalid UTF-8 detected")
    end
    text = text:gsub("^%s*(.-)%s*$", "%1")
    if text == "" then
        return nil, "empty_transcription"
    end
    local char_len = utf8_len_or_nil(text)
    if char_len and char_len > ASR_TEXT_MAX_CHARS then
        text = utf8_prefix(text, ASR_TEXT_MAX_CHARS)
        hs.printf("[whisper] asr_text truncated: chars=%d max=%d", char_len, ASR_TEXT_MAX_CHARS)
    elseif not char_len and #text > ASR_TEXT_MAX_CHARS then
        text = text:sub(1, ASR_TEXT_MAX_CHARS)
        hs.printf("[whisper] asr_text truncated (byte fallback): bytes=%d max=%d", #text, ASR_TEXT_MAX_CHARS)
    end
    if has_repeated_lines(text) or has_repeated_chunks(text) then
        return nil, "asr_text_repetition"
    end
    return text, nil
end

local function build_task_args(provider, audio_path)
    return {
        audio_path or "/tmp/whisper_input.wav",
        provider.endpoint,
        provider.api_key_env,
        provider.keychain_service,
        provider.keychain_account,
        provider.api_key_envs,
        provider.keychain_candidates,
        tostring(provider.key_max_switches),
        provider.key_retry_on,
        provider.request_retry_on,
        tostring(provider.request_max_retries),
        tostring(provider.request_backoff_ms),
        tostring(provider.request_backoff_max_ms),
        provider.audio_normalize,
        provider.audio_sample_rate,
        provider.audio_channels,
        provider.model,
        provider.provider_name,
    }
end

local function run_provider(provider, audio_path, request_id, started_at_ns, on_result)
    local task = hs.task.new(CLOUD_TRANSCRIBE_SCRIPT, function(exitCode, stdout, stderr)
        local elapsed_ms = math.floor((hs.timer.absoluteTime() - started_at_ns) / 1e6)
        local metrics = parse_metrics_from_stderr(stderr) or {}
        metrics.provider = metrics.provider or provider.provider_name
        metrics.model = metrics.model or provider.model
        metrics.route = provider.route
        if not metrics.request_ms then
            metrics.request_ms = tostring(elapsed_ms)
        end
        if not metrics.provider_status then
            metrics.provider_status = exitCode == 0 and "ok" or ("exit_" .. tostring(exitCode))
        end

        if not is_request_active(request_id) then
            hs.printf("[whisper] Ignore stale ASR callback: %s", tostring(request_id))
            return
        end

        local text, err_code = parse_asr_text(stdout)
        hs.printf(
            "[whisper] asr_metrics provider=%s model=%s request_ms=%s retry_count=%s provider_status=%s route=%s",
            tostring(metrics.provider or ""),
            tostring(metrics.model or ""),
            tostring(metrics.request_ms or ""),
            tostring(metrics.retry_count or "0"),
            tostring(metrics.provider_status or ""),
            tostring(metrics.route or "")
        )
        if not text then
            on_result(false, nil, err_code, metrics)
        else
            on_result(true, text, nil, metrics)
        end
    end, build_task_args(provider, audio_path))

    local started = task:start()
    if not started then
        local metrics = {
            provider = provider.provider_name,
            model = provider.model,
            route = provider.route,
            provider_status = "spawn_failed",
            request_ms = "0",
            retry_count = "0",
        }
        on_result(false, nil, "asr_request_failed", metrics)
        return nil
    end
    return task
end

-- ========================================
-- 统一 ASR 转录接口
-- ========================================

function M.transcribe(audio_path, callback, opts)
    if not PRIMARY_PROVIDER then
        callback(nil, "asr_request_failed", { provider_status = "missing_primary_provider" })
        return
    end

    local request_id = new_request_id()
    local timeout_timer = nil  -- 前置声明
    local started_at = hs.timer.absoluteTime()
    local last_provider = PRIMARY_PROVIDER
    local finished = false
    local timeout_sec = tonumber(opts and opts.timeout_sec) or ASR_TASK_TIMEOUT_SEC
    timeout_sec = math.max(5, math.min(3600, math.floor(timeout_sec)))

    local function finish(text, err_code, metrics)
        if finished then
            return
        end
        finished = true
        if timeout_timer then
            timeout_timer:stop()
            timeout_timer = nil
        end
        local active = is_request_active(request_id)
        clear_request(request_id)
        if not active then
            return
        end
        if err_code then
            callback(nil, err_code, metrics or {})
        else
            callback(text, nil, metrics or {})
        end
    end

    local function run_fallback(primary_err, primary_metrics)
        if not FALLBACK_ENABLED or not FALLBACK_PROVIDER then
            finish(nil, primary_err, primary_metrics)
            return
        end
        if FALLBACK_MODE ~= "session" then
            finish(nil, primary_err, primary_metrics)
            return
        end
        local now_sec = os.time()
        if is_fallback_circuit_open(now_sec) then
            local remaining = math.max(0, fallback_open_until - now_sec)
            hs.printf("[whisper] asr_fallback skipped: circuit_open remaining=%ds", remaining)
            local metrics = primary_metrics or {}
            metrics.fallback_skipped = "circuit_open"
            metrics.fallback_circuit_remaining_sec = tostring(remaining)
            finish(nil, primary_err, metrics)
            return
        end
        hs.printf(
            "[whisper] asr_fallback start: from=%s to=%s reason=%s",
            tostring(primary_metrics and primary_metrics.provider or PRIMARY_PROVIDER.provider_name),
            tostring(FALLBACK_PROVIDER.provider_name),
            tostring(primary_err or "")
        )
        last_provider = FALLBACK_PROVIDER
        local task = run_provider(FALLBACK_PROVIDER, audio_path, request_id, started_at, function(ok, text, err_code, metrics)
            if ok then
                record_fallback_success()
                metrics.fallback_from = tostring(primary_metrics and primary_metrics.provider or PRIMARY_PROVIDER.provider_name)
                metrics.fallback_reason = tostring(primary_err or "")
                finish(text, nil, metrics)
                return
            end
            record_fallback_failure()
            local merged = metrics or {}
            merged.fallback_from = tostring(primary_metrics and primary_metrics.provider or PRIMARY_PROVIDER.provider_name)
            merged.fallback_reason = tostring(primary_err or "")
            merged.primary_provider_status = tostring(primary_metrics and primary_metrics.provider_status or "")
            finish(nil, err_code or primary_err, merged)
        end)
        if task then
            set_request_task(request_id, task)
        end
    end

    last_provider = PRIMARY_PROVIDER
    local primary_task = run_provider(PRIMARY_PROVIDER, audio_path, request_id, started_at, function(ok, text, err_code, metrics)
        if ok then
            finish(text, nil, metrics)
            return
        end
        if should_fallback(err_code, metrics) then
            run_fallback(err_code, metrics)
            return
        end
        finish(nil, err_code, metrics)
    end)
    if primary_task then
        set_request_task(request_id, primary_task)
    end

    if not primary_task then
        clear_request(request_id)
        callback(nil, "asr_request_failed", { provider_status = "spawn_failed" })
        return
    end

    -- 超时保护：超时后强制终止
    timeout_timer = hs.timer.doAfter(timeout_sec, function()
        if is_request_active(request_id) then
            hs.printf("[whisper] ASR timeout after %ds, terminating task", timeout_sec)
            local req = active_requests[request_id]
            if req and req.task then
                pcall(function()
                    req.task:terminate()
                end)
            end
            finish(nil, "asr_timeout", {
                provider = last_provider and last_provider.provider_name or "unknown",
                model = last_provider and last_provider.model or "unknown",
                route = last_provider and last_provider.route or "",
                provider_status = "timeout",
            })
        end
    end)
end

return M
