-- Whisper 语音输入 - 简化版 (使用外部脚本)
-- 避免 hs.task 的不稳定性问题
-- 2026-01-06: 简化输入链路，支持系统听写模式

local DEFAULT_SCRIPT_DIR = os.getenv("HOME") .. "/.hammerspoon"
local utils = require("lib.utils")
local cfg_value = utils.cfg_value
local sh_escape = utils.sh_escape

-- 允许 hs CLI 连接（用于自动重载与调试）
pcall(function()
    local ipc = require("hs.ipc")
    if ipc and ipc.cliStatus then
        ipc.cliStatus(true)
    end
end)

local function load_local_config(base_dir)
    local path = base_dir .. "/config.lua"
    local ok, data = pcall(dofile, path)
    if ok and type(data) == "table" then
        return data
    end
    if not ok then
        hs.printf("[whisper] config.lua load failed: %s", tostring(data))
    end
    return {}
end

local cfg = load_local_config(DEFAULT_SCRIPT_DIR)

local function tmp_path(name)
    local base = os.getenv("TMPDIR") or "/tmp"
    if not base:match("/$") then
        base = base .. "/"
    end
    return base .. name
end

local SCRIPT_DIR = cfg_value(cfg.paths and cfg.paths.script_dir, DEFAULT_SCRIPT_DIR)
local RECORD_SCRIPT = SCRIPT_DIR .. "/whisper_record.sh"
local AUDIO_FILE = cfg_value(cfg.paths and cfg.paths.audio_file, tmp_path("whisper_input.wav"))
local RECORD_PID_FILE = cfg_value(cfg.paths and cfg.paths.record_pid_file, tmp_path("whisper_record.pid"))
local LOG_FILE = cfg_value(cfg.paths and cfg.paths.log_file, SCRIPT_DIR .. "/whisper.log")
do -- whisper.log rotation: truncate to last 500 lines if > 1MB
    local attr = hs.fs.attributes(LOG_FILE)
    if attr and tonumber(attr.size or 0) > 1048576 then
        hs.execute("tail -500 " .. sh_escape(LOG_FILE) .. " > " .. sh_escape(LOG_FILE .. ".tmp") .. " && mv " .. sh_escape(LOG_FILE .. ".tmp") .. " " .. sh_escape(LOG_FILE), true)
        hs.printf("[whisper] log rotated: %s was %d bytes", LOG_FILE, attr.size)
    end
end
local TRANSCRIPT_ENABLED = cfg_value(cfg.transcript and cfg.transcript.enabled, false)
local TRANSCRIPT_DIR = cfg_value(cfg.transcript and cfg.transcript.dir, SCRIPT_DIR .. "/transcripts")
local TRANSCRIPT_WRITE_JSONL = cfg_value(cfg.transcript and cfg.transcript.write_jsonl, true)
local TRANSCRIPT_WRITE_MD = cfg_value(cfg.transcript and cfg.transcript.write_md, false)
local TRANSCRIPT_MD_INCLUDE_INPUT = cfg_value(cfg.transcript and cfg.transcript.md_include_input, true)
local LEXICON_ENABLED = cfg_value(cfg.lexicon and cfg.lexicon.enabled, false)
local LEXICON_AUTO_UPDATE = cfg_value(cfg.lexicon and cfg.lexicon.auto_update, false)
local LEXICON_AUTO_APPLY = cfg_value(cfg.lexicon and cfg.lexicon.auto_apply, false)
local LEXICON_UPDATE_DEBOUNCE = cfg_value(cfg.lexicon and cfg.lexicon.update_debounce_sec, 60)
local LEXICON_MIN_COUNT = cfg_value(cfg.lexicon and cfg.lexicon.min_count, 3)
local LEXICON_MAX_TERMS = cfg_value(cfg.lexicon and cfg.lexicon.max_terms, 300)
local LEXICON_RIME_DIR = cfg_value(cfg.lexicon and cfg.lexicon.rime_dir, os.getenv("HOME") .. "/Library/Rime")
local LEXICON_RIME_FILE = cfg_value(cfg.lexicon and cfg.lexicon.rime_phrase_file, os.getenv("HOME") .. "/Library/Rime/custom_phrase_double.txt")
local LEXICON_USE_GLOSSARY_ONLY_ON_HIT = cfg_value(cfg.lexicon and cfg.lexicon.use_glossary_only_on_hit, false)
local LEXICON_PENDING_DIR = cfg_value(cfg.lexicon and cfg.lexicon.pending_dir, SCRIPT_DIR .. "/knowledge/lexicon/pending")
local FLOMO_ENABLED = cfg_value(cfg.flomo and cfg.flomo.enabled, false)
local FLOMO_WEBHOOK = cfg_value(cfg.flomo and cfg.flomo.webhook, "")
local FLOMO_TAG = cfg_value(cfg.flomo and cfg.flomo.tag, "")
local FLOMO_TAGS_BY_ACTION = cfg.flomo and cfg.flomo.tags_by_action or nil
local FLOMO_TAGS_BY_APP = cfg.flomo and cfg.flomo.tags_by_app or nil
local FLOMO_MAX_CHARS = cfg_value(cfg.flomo and cfg.flomo.max_chars, 4000)
local FLOMO_ACTIONS = cfg.flomo and cfg.flomo.actions or nil

local function append_log(line)
    local f = io.open(LOG_FILE, "a")
    if not f then
        return
    end
    f:write(os.date("%Y-%m-%d %H:%M:%S "), line, "\n")
    f:close()
end

local function logf(fmt, ...)
    local msg = string.format(fmt, ...)
    hs.printf("%s", msg)
    append_log(msg)
end

local function get_front_app_info()
    local app = hs.application.frontmostApplication()
    if not app then
        return nil, nil
    end
    return app:name(), app:bundleID()
end

local lexicon_timer = nil
local lexicon_dirty = false
suppress_glossary_reload_until = 0
GLOSSARY_RELOAD_SUPPRESS_SEC = math.max(5, math.floor(cfg_value(cfg.timing and cfg.timing.glossary_reload_suppress_sec, 180)))

local function run_lexicon_update()
    if not (LEXICON_ENABLED and LEXICON_AUTO_UPDATE) then
        return
    end
    local script = SCRIPT_DIR .. "/scripts/update_lexicon_from_transcripts.py"
    local sync_script = SCRIPT_DIR .. "/scripts/sync_rime_glossary.sh"
    local cmd = string.format("python3 %s --transcripts %s --glossary %s --min-count %d --max-terms %d --rime %s --pending-dir %s%s",
        sh_escape(script),
        sh_escape(TRANSCRIPT_DIR),
        sh_escape(SCRIPT_DIR .. "/prompts/glossary.txt"),
        LEXICON_MIN_COUNT,
        LEXICON_MAX_TERMS,
        sh_escape(LEXICON_RIME_FILE),
        sh_escape(LEXICON_PENDING_DIR),
        LEXICON_AUTO_APPLY and " --apply" or ""
    )
    local task = hs.task.new("/bin/bash", function(exitCode, stdout, stderr)
        if exitCode ~= 0 then
            logf("[whisper] lexicon update failed: %s", tostring(stderr or stdout))
            return
        end
        local out = tostring(stdout or "")
        if out:find("PENDING_APPROVAL", 1, true) then
            logf("[whisper] lexicon update pending approval: %s", out:gsub("%s+", " "))
            return
        end
        if out:find("No lexicon changes.", 1, true) then
            logf("[whisper] lexicon unchanged")
            return
        end
        suppress_glossary_reload_until = os.time() + GLOSSARY_RELOAD_SUPPRESS_SEC
        hs.execute(sync_script .. " " .. sh_escape(LEXICON_RIME_DIR) .. " " .. sh_escape(SCRIPT_DIR .. "/prompts/glossary.txt"), true)
        logf("[whisper] lexicon updated and synced")
    end, { "-lc", cmd })
    task:start()
end

local function schedule_lexicon_update()
    if not (LEXICON_ENABLED and LEXICON_AUTO_UPDATE) then
        return
    end
    lexicon_dirty = true
    if lexicon_timer then
        lexicon_timer:stop()
        lexicon_timer = nil
    end
    lexicon_timer = hs.timer.doAfter(LEXICON_UPDATE_DEBOUNCE, function()
        if not lexicon_dirty then
            return
        end
        local reason = busy_reason and busy_reason() or nil
        if reason then
            logf("[whisper] lexicon update deferred: %s", tostring(reason))
            schedule_lexicon_update()
            return
        end
        lexicon_dirty = false
        run_lexicon_update()
    end)
end

local ui = require("services.ui")
local llm = require("services.llm")
local asr = require("services.asr")

local function safe_llm_request(opts, callback)
    local ok, err = pcall(llm.request, opts, callback)
    if not ok then callback(nil, "llm_throw: " .. tostring(err)) end
end

-- 初始化服务模块
llm.init(cfg)
asr.init(cfg)
local ASR_RUNTIME = (function()
    local info = (asr.runtime_info and asr.runtime_info()) or {}
    return {
        provider_name = tostring(info.provider or "unknown"),
        model_name = tostring(info.model or "unknown"),
        endpoint_url = tostring(info.endpoint or ""),
        fallback_enabled = info.fallback_enabled and true or false,
        fallback_provider = tostring(info.fallback_provider or ""),
        fallback_model = tostring(info.fallback_model or ""),
        fallback_mode = tostring(info.fallback_mode or ""),
    }
end)()
logf(
    "[whisper] ASR runtime provider=%s model=%s endpoint=%s fallback_enabled=%s fallback_provider=%s fallback_model=%s fallback_mode=%s",
    ASR_RUNTIME.provider_name,
    ASR_RUNTIME.model_name,
    ASR_RUNTIME.endpoint_url,
    tostring(ASR_RUNTIME.fallback_enabled),
    ASR_RUNTIME.fallback_provider,
    ASR_RUNTIME.fallback_model,
    ASR_RUNTIME.fallback_mode
)

-- 自动重载（仅监控核心配置文件，避免频繁重载）
local reload_timer = nil
reload_defer_timer = nil
local reload_watchers = {}
reload_pending = false
reload_pending_reason = ""
local cleanup_before_reload -- forward declaration, assigned after all resources defined

local function trigger_reload(reason)
    if reload_timer then
        reload_timer:stop()
        reload_timer = nil
    end
    reload_timer = hs.timer.doAfter(cfg_value(cfg.timing and cfg.timing.reload_debounce, 0.6), function()
        logf("[whisper] auto reload triggered reason=%s", tostring(reason or "unknown"))
        hs.alert.show("♻️ 已自动重载", 1)
        if cleanup_before_reload then cleanup_before_reload() end
        hs.reload()
    end)
end

local function schedule_reload(reason, file)
    local p = tostring(file or "")
    if p:match("/glossary%.txt$") and os.time() < suppress_glossary_reload_until then
        logf("[whisper] auto reload skipped: glossary_suppressed file=%s", p)
        return
    end

    local current_busy = busy_reason and busy_reason() or nil
    if current_busy then
        reload_pending = true
        reload_pending_reason = tostring(reason or "busy_deferred")
        if not reload_defer_timer then
            reload_defer_timer = hs.timer.doEvery(2, function()
                local busy = busy_reason and busy_reason() or nil
                if busy or not reload_pending then
                    return
                end
                reload_pending = false
                local pending_reason = reload_pending_reason
                reload_pending_reason = ""
                if reload_defer_timer then
                    reload_defer_timer:stop()
                    reload_defer_timer = nil
                end
                trigger_reload("deferred:" .. tostring(pending_reason))
            end)
        end
        logf("[whisper] auto reload deferred reason=%s busy=%s file=%s", tostring(reason or ""), tostring(current_busy), p)
        return
    end

    trigger_reload(reason)
end

reload_watchers.root = hs.pathwatcher.new(SCRIPT_DIR, function(files)
    for _, file in ipairs(files) do
        if file:match("/init%.lua$") or file:match("/system_dictation%.lua$") or file:match("/config%.lua$") then
            schedule_reload("watcher_root", file)
            return
        end
    end
end)
reload_watchers.root:start()

reload_watchers.prompts = hs.pathwatcher.new(SCRIPT_DIR .. "/prompts", function(files)
    for _, file in ipairs(files) do
        if file:match("/prompts%.json$") or file:match("/prompts%-v2%.json$") or file:match("/glossary%.txt$") then
            schedule_reload("watcher_prompts", file)
            return
        end
    end
end)
reload_watchers.prompts:start()

reload_watchers.services = hs.pathwatcher.new(SCRIPT_DIR .. "/services", function(files)
    for _, file in ipairs(files) do
        if file:match("%.lua$") then
            schedule_reload("watcher_services", file)
            return
        end
    end
end)
reload_watchers.services:start()

reload_watchers.lib = hs.pathwatcher.new(SCRIPT_DIR .. "/lib", function(files)
    for _, file in ipairs(files) do
        if file:match("%.lua$") then
            schedule_reload("watcher_lib", file)
            return
        end
    end
end)
reload_watchers.lib:start()

-- 输入模式开关
-- INPUT_MODE = "hammerspoon" 使用本地录音+云端 ASR
-- INPUT_MODE = "system"      使用系统听写输入，仅保留后处理热键
local INPUT_MODE = "hammerspoon"
-- 系统听写为实验功能，默认关闭（可手动改为 true 试用）
local ENABLE_SYSTEM_DICTATION = cfg_value(cfg.features and cfg.features.enable_system_dictation, false)
if not ENABLE_SYSTEM_DICTATION then
    INPUT_MODE = "hammerspoon"
end
-- 是否启用 F8 功能（digest/workflow）

-- F5/F6 是否自动追加 F7 级别的润色
local AUTO_F7_AFTER_F5 = cfg_value(cfg.features and cfg.features.auto_f7_after_f5, true)
local ENABLE_F5_QUICK_POLISH = cfg_value(cfg.features and cfg.features.enable_f5_quick_polish, true)
local F5_QUICK_POLISH_MODEL_TYPE = cfg_value(cfg.features and cfg.features.f5_quick_polish_model_type, "quick")
local F5_REFINER = {
    pipeline = cfg_value(cfg.features and cfg.features.f5_refine_pipeline, "balanced"),
    struct_model_type = cfg_value(cfg.features and cfg.features.f5_struct_model_type, "fast"),
    struct_min_chars = cfg_value(cfg.features and cfg.features.f5_struct_min_chars, 120),
}
local AUTO_F7_AFTER_F6 = cfg_value(cfg.features and cfg.features.auto_f7_after_f6, true)
-- Alt+W 默认使用非流式（可在 config.lua 打开回退）
local ALT_W_USE_STREAM = cfg_value(cfg.features and cfg.features.alt_w_use_stream, false)
-- Alt 热键文本获取策略：selected_first / force_full
local ALT_SELECTION_POLICY = cfg_value(cfg.features and cfg.features.alt_selection_policy, "selected_first")
-- Alt+Z 默认停用（可在 config.lua 开启）
local ENABLE_ALT_Z = cfg_value(cfg.features and cfg.features.enable_alt_z, false)

local function record_script_command(action, max_duration)
    local cmd = string.format(
        "WHISPER_AUDIO_FILE=%s WHISPER_RECORD_PID_FILE=%s",
        sh_escape(AUDIO_FILE),
        sh_escape(RECORD_PID_FILE)
    )
    if max_duration and tonumber(max_duration) then
        cmd = string.format("%s WHISPER_MAX_DURATION=%d", cmd, math.floor(tonumber(max_duration)))
    end
    return string.format("%s %s %s", cmd, sh_escape(RECORD_SCRIPT), action)
end

-- 启动时清理临时文件
hs.execute(record_script_command("clean"), true)

local RECORD_MAX_DURATION = cfg_value(cfg.limits and cfg.limits.record_max_duration, 1800)
local ASR_BYTES_PER_SEC = 32000
local DEFAULT_PROCESSING_TIMEOUT_SEC = cfg_value(cfg.limits and cfg.limits.processing_timeout_default, 300)
local MAX_PROCESSING_TIMEOUT_SEC = cfg_value(cfg.limits and cfg.limits.processing_timeout_max, 3600)
local F5_ASR_SHORT_THRESHOLD_SEC = cfg_value(cfg.limits and cfg.limits.f5_asr_short_threshold_sec, 8)
local F5_ASR_TIMEOUT_SHORT_SEC = cfg_value(cfg.limits and cfg.limits.f5_asr_timeout_short_sec, 12)
local F5_ASR_TIMEOUT_LONG_SEC = cfg_value(cfg.limits and cfg.limits.f5_asr_timeout_long_sec, 25)
local F5_CHUNK = {
    threshold_sec = math.max(10, math.floor(cfg_value(cfg.limits and cfg.limits.f5_chunk_threshold_sec, 60))),
    len_sec = math.max(8, math.floor(cfg_value(cfg.limits and cfg.limits.f5_chunk_len_sec, 30))),
    overlap_sec = math.max(0, math.floor(cfg_value(cfg.limits and cfg.limits.f5_chunk_overlap_sec, 1))),
    parallel = math.max(1, math.floor(cfg_value(cfg.limits and cfg.limits.f5_chunk_parallel, 2))),
    asr_timeout_sec = math.max(5, math.floor(cfg_value(cfg.limits and cfg.limits.f5_chunk_asr_timeout_sec, 25))),
    emit_partial = cfg_value(cfg.features and cfg.features.f5_emit_partial, false),
}
local COMMAND_RECORD_SEC = 1.5
local COMMAND_RETRY_DELAY = 0.1
local COMMAND_NEXT_DELAY = 0.1
local COMMAND_STATUS_DONE_SEC = cfg_value(cfg.timing and cfg.timing.status_done_sec, 1.2)

-- Prompt 文件路径
local PROMPTS_FILE = SCRIPT_DIR .. "/prompts/prompts.json"
local GLOSSARY_FILE = SCRIPT_DIR .. "/prompts/glossary.txt"

-- 节流：每类错误只提示一次
local prompt_alert_shown = {
    file_missing = false,
    json_error = false,
    key_missing = {},  -- 按 key 记录
}

-- 热加载 Prompt（每次调用时从文件读取，修改后立即生效）
-- 返回 nil 时会回退到内置 fallback
local function load_prompt(key)
    -- 优先使用 llm 模块的 load_prompt（setup 后可用）
    if llm and llm.load_prompt then
        local result = llm.load_prompt(key)
        if result then return result end
    end
    -- 回退到本地实现
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

local function load_glossary()
    local f = io.open(GLOSSARY_FILE, "r")
    if not f then
        return nil
    end
    local content = f:read("*all") or ""
    f:close()
    local trimmed = content:gsub("^%s*(.-)%s*$", "%1")
    if trimmed == "" then
        return nil
    end
    return trimmed
end

-- API Key 缓存（避免重复查询 Keychain）

-- 状态变量
local is_recording = false
local is_processing = false  -- 防止操作冲突
local processing_start_time = nil  -- 超时检测
local processing_timeout_sec = DEFAULT_PROCESSING_TIMEOUT_SEC
local recording_start_time = nil  -- 最短录音时间检测
local recording_start_tick_ns = nil
local f6_recording = false
local command_mode_active = false
local saved_clipboard = nil  -- 剪贴板保护
local stream_timer = nil
local stream_task = nil
local output_text
local refine_with_llm
local run_f6_llm

local function finish_processing()
    is_processing = false
    processing_start_time = nil
end
local clipboard_pollution_last_alert_at = 0
local RUNTIME_USAGE = {
    started_at = os.time(),
    total_events = 0,
    actions = {},
    apps = {},
    hours = {},
}

local function alert_clipboard_pollution(msg)
    local now = os.time()
    if now - clipboard_pollution_last_alert_at >= 10 then
        hs.alert.show(msg or "⚠️ 剪贴板被污染，请重试", 1.5)
        clipboard_pollution_last_alert_at = now
    end
end
local apply_f7_polish
local dictation = nil

local function set_processing_timeout(seconds)
    if seconds and seconds > 0 then
        processing_timeout_sec = seconds
    else
        processing_timeout_sec = DEFAULT_PROCESSING_TIMEOUT_SEC
    end
end

local function reset_processing_timeout()
    processing_timeout_sec = DEFAULT_PROCESSING_TIMEOUT_SEC
end

local function start_processing()
    is_processing = true
    processing_start_time = os.time()
end

-- 超时检测：每 5 秒检查一次
hs.timer.doEvery(5, function()
    if is_processing and processing_start_time then
        local elapsed = os.time() - processing_start_time
        if processing_timeout_sec > 0 and elapsed >= processing_timeout_sec then
            hs.printf("[whisper] Processing timeout after %ds, force reset", processing_timeout_sec)
            finish_processing()
            command_mode_active = false
            llm.invalidate_requests()
            asr.invalidate_requests()
            -- 清理流式资源
            if stream_timer then stream_timer:stop(); stream_timer = nil end
            ui.hide_stream()
            -- 仅终止当前流式 task，避免误杀同名进程
            if stream_task then stream_task:terminate(); stream_task = nil end
            reset_processing_timeout()
            ui.hide_icon()
            hs.alert.show("⚠️ 处理超时，已重置")
        elseif elapsed >= 30 and elapsed < 35 then
            -- 30秒提示（只提示一次）
            hs.alert.show("⏳ 处理中，请耐心等待...")
        end
    end
end)

-- 恢复剪贴板（处理完成后恢复原内容）
local function restore_clipboard()
    if saved_clipboard then
        hs.timer.doAfter(0.5, function()
            hs.pasteboard.setContents(saved_clipboard)
            saved_clipboard = nil
        end)
    end
end

-- ========================================
-- 安全的选区捕获 (防污染版本)
-- ========================================
local function capture_selection_safe(callback, opts)
    opts = opts or {}
    local old_count = hs.pasteboard.changeCount()  -- 当前剪贴板版本号
    local old_clip = hs.pasteboard.getContents()   -- 备份内容

    hs.eventtap.keyStroke({ "cmd" }, "c")

    hs.timer.doAfter(cfg_value(cfg.timing and cfg.timing.selection_delay, 0.3), function()
        local new_count = hs.pasteboard.changeCount()

        -- 检查剪贴板是否由我们的 Cmd+C 修改
        if new_count == old_count then
            -- 未变化：无选区或复制失败
            if not opts.silent_no_change then
                hs.printf("[whisper] 剪贴板未变化，可能无选区")
            end
            callback(nil)
            return
        end

        local selected = hs.pasteboard.getContents()
        if new_count > old_count + 1 then
            -- 某些应用一次复制会触发多次 changeCount（富文本/剪贴板管理器等）。
            -- 若本次仍拿到了有效选区内容，则接受结果而不是误报污染。
            if not selected or selected == "" or selected == old_clip then
                alert_clipboard_pollution("⚠️ 剪贴板被污染，请重试")
                hs.printf("[whisper] 剪贴板污染检测: old=%d new=%d", old_count, new_count)
                callback(nil)
                return
            end
            hs.printf("[whisper] 剪贴板多次变化但已捕获有效选区: old=%d new=%d", old_count, new_count)
        end

        -- 恢复原剪贴板
        if old_clip then
            hs.pasteboard.setContents(old_clip)
        end

        hs.printf("[whisper] 安全捕获选区: %d chars", #(selected or ""))
        callback(selected)
    end)
end

-- ========================================
-- 全文捕获（强制全选 + 重试）
-- ========================================
local function capture_full_text(callback)
    if hs.eventtap.isSecureInputEnabled() then
        hs.alert.show("⚠️ 安全输入开启，无法读取文本")
        callback(nil)
        return
    end

    local retries = cfg_value(cfg.timing and cfg.timing.selection_retries, 2)
    local delay = cfg_value(cfg.timing and cfg.timing.selection_delay, 0.3)

    local function attempt(n)
        hs.eventtap.keyStroke({ "cmd" }, "a")
        hs.timer.doAfter(delay, function()
            capture_selection_safe(function(text)
                if text and text ~= "" then
                    callback(text)
                    return
                end
                if n < retries then
                    hs.timer.doAfter(delay * (n + 1), function()
                        attempt(n + 1)
                    end)
                else
                    hs.printf("[whisper] 剪贴板未变化，可能无选区")
                    callback(nil)
                end
            end, { silent_no_change = true })
        end)
    end

    attempt(0)
end

-- ========================================
-- 口述数字规范化（中文数字 → 阿拉伯数字）
-- ========================================
local normalize_numbers = require("lib.normalize_numbers")
local function normalize_spoken_numbers(text)
    return normalize_numbers.normalize(text, cfg_value(cfg.features and cfg.features.normalize_spoken_numbers, false))
end

-- ========================================
-- 工具函数
-- ========================================

local ensure_dir = utils.ensure_dir

local function should_send_flomo(action)
    if not FLOMO_ENABLED or FLOMO_WEBHOOK == "" then
        return false
    end
    if type(FLOMO_ACTIONS) ~= "table" then
        return true
    end
    for _, item in ipairs(FLOMO_ACTIONS) do
        if item == action then
            return true
        end
    end
    return false
end

local function collect_tags(value, tags)
    if not value then
        return
    end
    if type(value) == "string" then
        for tag in value:gmatch("#%S+") do
            tags[tag] = true
        end
        return
    end
    if type(value) == "table" then
        for _, item in ipairs(value) do
            if type(item) == "string" then
                for tag in item:gmatch("#%S+") do
                    tags[tag] = true
                end
            end
        end
    end
end

local function build_flomo_content(entry)
    local content = entry.output or entry.input or ""
    if entry.action and entry.action ~= "" then
        content = "[" .. entry.action .. "] " .. content
    end
    if entry.app and entry.app ~= "" then
        content = entry.app .. "\n" .. content
    end
    local tags = {}
    if entry.action and FLOMO_TAGS_BY_ACTION and FLOMO_TAGS_BY_ACTION[entry.action] then
        collect_tags(FLOMO_TAGS_BY_ACTION[entry.action], tags)
    end
    if entry.app and FLOMO_TAGS_BY_APP and FLOMO_TAGS_BY_APP[entry.app] then
        collect_tags(FLOMO_TAGS_BY_APP[entry.app], tags)
    end
    if FLOMO_TAG and FLOMO_TAG ~= "" then
        collect_tags(FLOMO_TAG, tags)
    end
    local tag_list = {}
    for tag, _ in pairs(tags) do
        table.insert(tag_list, tag)
    end
    table.sort(tag_list)
    if #tag_list > 0 then
        content = content .. "\n" .. table.concat(tag_list, " ")
    end
    if #content > FLOMO_MAX_CHARS then
        content = content:sub(1, FLOMO_MAX_CHARS - 1) .. "…"
    end
    return content
end

local function send_to_flomo(entry)
    if not should_send_flomo(entry.action) then
        return
    end
    local payload = hs.json.encode({ content = build_flomo_content(entry) })
    hs.http.asyncPost(FLOMO_WEBHOOK, payload, { ["Content-Type"] = "application/json" }, function(status, body)
        if status ~= 200 and status ~= 201 then
            logf("[whisper] flomo failed: status=%s body=%s", tostring(status), tostring(body))
        end
    end)
end

local function append_transcript(entry)
    local date = os.date("%Y-%m-%d")
    local time = os.date("%H:%M:%S")
    local app_name, bundle_id = get_front_app_info()
    local action_name = tostring(entry.action or "UNKNOWN")
    local app_label = tostring(entry.app or app_name or "unknown")
    local hour_key = os.date("%H")
    RUNTIME_USAGE.total_events = RUNTIME_USAGE.total_events + 1
    RUNTIME_USAGE.actions[action_name] = (RUNTIME_USAGE.actions[action_name] or 0) + 1
    RUNTIME_USAGE.apps[app_label] = (RUNTIME_USAGE.apps[app_label] or 0) + 1
    RUNTIME_USAGE.hours[hour_key] = (RUNTIME_USAGE.hours[hour_key] or 0) + 1

    if not TRANSCRIPT_ENABLED then
        return
    end
    local row = {
        ts = date .. " " .. time,
        action = entry.action,
        app = entry.app or app_name,
        bundle = entry.bundle or bundle_id,
        prompt_key = entry.prompt_key,
        instruction = entry.instruction,
        input = entry.input,
        output = entry.output,
    }
    ensure_dir(TRANSCRIPT_DIR)
    if TRANSCRIPT_WRITE_JSONL then
        local jsonl_path = TRANSCRIPT_DIR .. "/" .. date .. ".jsonl"
        local f = io.open(jsonl_path, "a")
        if f then
            f:write(hs.json.encode(row), "\n")
            f:close()
        end
    end
    if TRANSCRIPT_WRITE_MD then
        local md_path = TRANSCRIPT_DIR .. "/" .. date .. ".md"
        local f = io.open(md_path, "a")
        if f then
            f:write("### ", time, " [", row.action or "-", "] ", row.app or "-", "\n")
            if TRANSCRIPT_MD_INCLUDE_INPUT and row.input and row.input ~= "" then
                f:write("原文: ", row.input, "\n")
            end
            if row.output and row.output ~= "" then
                f:write("结果: ", row.output, "\n")
            end
            f:write("\n")
            f:close()
        end
    end
    schedule_lexicon_update()
end

local function hide_hud()
    ui.hide_icon()
end

local function show_hud(kind, opts)
    ui.show_icon(kind, opts or {})
end

local function update_hud(opts)
    ui.update_icon(opts or {})
end

local function save_clipboard()
    if saved_clipboard == nil then
        saved_clipboard = hs.pasteboard.getContents()
    end
end

local function paste_output(text, opts)
    opts = opts or {}
    save_clipboard()
    hs.pasteboard.setContents(text or "")
    hs.eventtap.keyStroke({ "cmd" }, "v")
    if opts.show_hud ~= false then
        show_hud("success")
    end
    -- 根据配置决定是否恢复剪贴板
    if cfg_value(cfg.features and cfg.features.restore_clipboard_after_paste, false) then
        restore_clipboard()
    else
        -- 如果不恢复，手动清理 saved_clipboard 防止堆积
        saved_clipboard = nil
    end
end

busy_reason = function()
    if command_mode_active then
        return "语音命令模式运行中"
    end
    if dictation and dictation.is_active() then
        return "系统听写中"
    end
    if f6_recording then
        return "F6 正在录制指令"
    end
    if is_recording then
        return "正在录音"
    end
    if is_processing then
        return "处理中"
    end
    return nil
end

local function ensure_idle(task_label)
    local reason = busy_reason()
    if reason then
        hs.alert.show("⏳ " .. reason)
        if task_label then
            hs.printf("[whisper] %s blocked: %s", task_label, reason)
        else
            hs.printf("[whisper] action blocked: %s", reason)
        end
        return false
    end
    return true
end

local function toggle_input_mode()
    if not ENABLE_SYSTEM_DICTATION then
        hs.alert.show("⚙️ 系统听写已禁用（实验功能）", 2)
        hs.printf("[whisper] input mode switch blocked: system dictation disabled")
        return
    end
    if INPUT_MODE == "hammerspoon" then
        INPUT_MODE = "system"
        hs.alert.show("✅ 输入模式：系统听写\nF5/F6 直接听写（再次按键结束）", 2)
    else
        INPUT_MODE = "hammerspoon"
        hs.alert.show("✅ 输入模式：Hammerspoon 录音", 2)
    end
    hs.printf("[whisper] input mode switched: %s", INPUT_MODE)
end

-- 系统听写相关逻辑已迁移到 system_dictation.lua（按需加载）

-- 每 10 分钟清理临时文件（空闲时执行）
hs.timer.doEvery(600, function()
    local reason = busy_reason()
    if reason then
        hs.printf("[whisper] skip clean: %s", reason)
        return
    end
    hs.execute(record_script_command("clean"), true)
end)

-- ========================================
-- 流式输出 HUD 预览
-- ========================================
local LLM_STREAM_SCRIPT = SCRIPT_DIR .. "/llm_stream.sh"
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
local LLM_ENDPOINT = normalize_chat_endpoint(cfg_value(cfg.llm and cfg.llm.endpoint, "https://api.siliconflow.cn/v1/chat/completions"))
if not LLM_ENDPOINT then
    LLM_ENDPOINT = "https://api.siliconflow.cn/v1/chat/completions"
end
local STREAM_FILE = cfg_value(cfg.paths and cfg.paths.stream_file, tmp_path("llm_stream.txt"))
local STATUS_FILE = cfg_value(cfg.paths and cfg.paths.stream_status, tmp_path("llm_stream_status.txt"))
local STREAM_RR_INDEX_FILE = cfg_value(cfg.paths and cfg.paths.stream_rr_index, tmp_path("llm_stream_key_rr_index"))

local function hide_stream_hud()
    ui.hide_stream()
    if stream_timer then
        stream_timer:stop()
        stream_timer = nil
    end
end

local function show_stream_hud(content)
    ui.show_stream(content)
end

-- 流式 LLM 请求（用于 Alt+W 等）
local PROMPT_FILE = cfg_value(cfg.paths and cfg.paths.prompt_file, tmp_path("llm_stream_prompt.json"))

local function llm_stream(system_prompt, user_prompt, model_type, callback)
    if is_processing then
        hs.alert.show("⏳ 处理中，请稍候...")
        return
    end
    
    -- 选择模型（统一使用 config.lua 的配置）
    local llm_cfg = cfg.llm or {}
    local llm_models = llm_cfg.models or {}
    local model = llm_models[model_type or "fast"] or llm_cfg.default_model or "THUDM/GLM-4-9B-0414"
    hs.printf("[whisper] Stream using model: %s", model)
    
    -- 启动前清理临时文件
    os.remove(STREAM_FILE)
    os.remove(STATUS_FILE)
    os.remove(PROMPT_FILE)
    
    -- 应用场景风格（与服务层一致）
    if llm.apply_app_style then
        system_prompt = llm.apply_app_style(system_prompt)
    end

    -- 写入 prompt 到临时文件（避免 ARG_MAX 限制）
    local prompt_data = hs.json.encode({ system = system_prompt, user = user_prompt })
    local pf = io.open(PROMPT_FILE, "w")
    if not pf then
        hs.alert.show("❌ 无法创建 prompt 文件")
        return
    end
    pf:write(prompt_data)
    pf:close()

    start_processing()
    hide_hud()
    show_stream_hud("生成中...")
    
    -- 启动流式脚本（传 model + endpoint 参数）
    stream_task = hs.task.new(LLM_STREAM_SCRIPT, function(exitCode, stdout, stderr)
        hs.printf("[whisper] Stream script ended: exit=%d", exitCode)
        stream_task = nil
    end, { model, LLM_ENDPOINT, PROMPT_FILE, STREAM_FILE, STATUS_FILE, STREAM_RR_INDEX_FILE })
    
    local started = stream_task:start()
    if not started then
        hs.alert.show("❌ 流式脚本启动失败")
        finish_processing()
        stream_task = nil
        hide_stream_hud()
        return
    end
    
    -- 轮询读取流文件
    local last_content = ""
    local poll_count = 0
    local max_polls = cfg_value(cfg.limits and cfg.limits.stream_max_polls, 800)  -- 最多轮询 800 次 (0.15s * 800 = 120s)
    
    local poll_interval = cfg_value(cfg.timing and cfg.timing.stream_poll_interval, 0.15)
    stream_timer = hs.timer.doEvery(poll_interval, function()
        poll_count = poll_count + 1
        
        -- 超时保护
        if poll_count > max_polls then
            hs.printf("[whisper] Stream timeout after %d polls", poll_count)
            if stream_task then
                stream_task:terminate()
                stream_task = nil
            end
            hide_stream_hud()
            finish_processing()
            hs.alert.show("❌ 流式输出超时", 3)
            callback(nil)
            return
        end
        
        -- 检查状态
        local status_file = io.open(STATUS_FILE, "r")
        local status = status_file and status_file:read("*all"):gsub("%s+$", "") or ""
        if status_file then status_file:close() end
        
        -- 读取内容
        local content_file = io.open(STREAM_FILE, "r")
        local content = content_file and content_file:read("*all") or ""
        if content_file then content_file:close() end
        
        -- 更新 HUD
        if content ~= last_content then
            show_stream_hud(content)
            last_content = content
        end
        
        -- 检查是否完成
        if status == "done" or status == "error" then
            hide_stream_hud()
            finish_processing()

            if status == "done" then
                -- 允许空输出（某些场景可能返回空）
                callback(content)
            else
                -- 读取错误信息
                local err_msg = content ~= "" and content or "未知错误"
                hs.alert.show("❌ 流式生成失败: " .. err_msg, 3)
                callback(nil)
            end
        end
    end)
end

-- 流式 transform 入口（用于 Alt+W）
local function get_selection_and_stream_transform(system_prompt, task_name, model_type, prompt_key, opts)
    if not ensure_idle(task_name) then
        return
    end
    opts = opts or {}
    hs.printf("[whisper] %s (stream)", task_name)
    if opts.force_full then
        hs.printf("[whisper] 强制处理全文")
        capture_full_text(function(full_text)
            if not full_text or full_text == "" then
                hs.alert.show("未能获取全文，请确认光标在可编辑区域")
                return
            end
            local prompt = system_prompt
            if prompt_key then
                prompt = load_prompt(prompt_key) or system_prompt
            end
            llm_stream(prompt, full_text, model_type, function(result)
                if result then
                    hs.eventtap.keyStroke({ "cmd" }, "a")
                    hs.printf("[whisper] stream output: %d chars", #(result or ""))
                    output_text(result, {
                        show_hud = false,
                        log = {
                            action = task_name,
                            input = full_text,
                            prompt_key = prompt_key,
                        },
                    })
                    hs.alert.show("✅ 流式输出完成", 1)
                end
            end)
        end)
        return
    end
    capture_selection_safe(function(text)
        if text and text ~= "" then
            local prompt = system_prompt
            if prompt_key then
                prompt = load_prompt(prompt_key) or system_prompt
            end
            llm_stream(prompt, text, model_type, function(result)
                if result then
                    hs.eventtap.keyStroke({ "cmd" }, "a")
                    hs.printf("[whisper] stream output: %d chars", #(result or ""))
                    output_text(result, {
                        show_hud = false,
                        log = {
                            action = task_name,
                            input = text,
                            prompt_key = prompt_key,
                        },
                    })
                    hs.alert.show("✅ 流式输出完成", 1)
                end
            end)
            return
        end
        hs.printf("[whisper] 未检测到选区，将处理全文")
        capture_full_text(function(full_text)
            if not full_text or full_text == "" then
                hs.alert.show("未能获取全文，请确认光标在可编辑区域")
                return
            end
            local prompt = system_prompt
            if prompt_key then
                prompt = load_prompt(prompt_key) or system_prompt
            end
            llm_stream(prompt, full_text, model_type, function(result)
                if result then
                    hs.eventtap.keyStroke({ "cmd" }, "a")
                    hs.printf("[whisper] stream output: %d chars", #(result or ""))
                    output_text(result, {
                        show_hud = false,
                        log = {
                            action = task_name,
                            input = full_text,
                            prompt_key = prompt_key,
                        },
                    })
                    hs.alert.show("✅ 流式输出完成", 1)
                end
            end)
        end)
    end)
end

local function ensure_utf8(text)
    local value = tostring(text or "")
    local ok, len = pcall(utf8.len, value)
    if ok and type(len) == "number" then
        return value
    end
    local out = {}
    for ch in value:gmatch(utf8.charpattern) do
        table.insert(out, ch)
    end
    return table.concat(out)
end

output_text = function(text, opts)
    local raw_text = ensure_utf8(text or "")
    local ok, final_text = pcall(normalize_spoken_numbers, raw_text)
    if not ok then
        hs.printf("[whisper] normalize_spoken_numbers failed: %s", tostring(final_text))
        final_text = raw_text
    end
    final_text = ensure_utf8(final_text)
    hs.printf("[whisper] output: %d chars", #(final_text or ""))
    paste_output(final_text, opts)
    if opts and opts.log then
        local entry = opts.log
        entry.output = final_text
        append_transcript(entry)
        send_to_flomo(entry)
    end
end

-- ========================================
-- LLM 润色 (委托给 services/llm.lua)
-- ========================================

refine_with_llm = function(text, callback, opts)
    opts = opts or {}
    local fallback_label = tostring(opts.fallback_label or "input_text")

    -- HUD 显示（在服务层之外管理）
    show_hud("asr", { duration_sec = processing_timeout_sec })
    start_processing()

    -- 委托给服务层
    safe_llm_request({
        text = text,
        prompt_key = opts.prompt_key or "f7_polish",
        user_prompt = opts.user_prompt,
        use_glossary = opts.use_glossary,
        model_type = opts.model_type,  -- ✅ 修复：传递 model_type
        task_label = "润色",
        enable_retry = opts.enable_retry,
        request_timeout_sec = opts.request_timeout_sec,
        max_retries = opts.max_retries,
        retry_on_statuses = opts.retry_on_statuses,
    }, function(result, error)
        -- 服务层不管理状态，回调时清理
        finish_processing()

        if error then
            logf(
                "[whisper] llm_refine_failed prompt_key=%s model_type=%s error=%s fallback=%s",
                tostring(opts.prompt_key or "unknown"),
                tostring(opts.model_type or "default"),
                tostring(error),
                fallback_label
            )
            hide_hud()
            if not opts.suppress_error_alert then
                hs.alert.show("❌ " .. error, 3)
            end
            callback(text)
        else
            callback(result or text)
        end
    end)
end

apply_f7_polish = function(text, callback)
    if not text or text == "" then
        callback(text or "")
        return
    end
    refine_with_llm(text, function(polished)
        callback(polished)
    end, {
        prompt_key = "f7_polish",
        user_prompt = "【原文】\n" .. text,
        model_type = "strong",  -- 强模型用于高质量润色
    })
end

local function resolve_f5_pipeline_mode(text)
    local mode = tostring(F5_REFINER.pipeline or "balanced")
    local text_len = #(text or "")
    if not ENABLE_F5_QUICK_POLISH then
        if AUTO_F7_AFTER_F5 then
            return "f7_only"
        end
        return "quick_only"
    end
    if mode == "quick_only" or mode == "f7_only" or mode == "f7_then_quick" then
        return mode
    end
    if mode == "balanced" then
        if text_len >= tonumber(F5_REFINER.struct_min_chars or 120) then
            return "f7_then_quick"
        end
        return "quick_only"
    end
    -- 兼容旧开关行为
    if ENABLE_F5_QUICK_POLISH then
        return "quick_only"
    end
    if AUTO_F7_AFTER_F5 then
        return "f7_only"
    end
    return "quick_only"
end

-- ========================================
-- 录音和转录 (云端 ASR 版本)
-- ========================================

local function start_record_command()
    local cmd = record_script_command("start", RECORD_MAX_DURATION)
    local result = hs.execute(cmd, true)
    if result and result:match("missing_ffmpeg") then
        return "missing_ffmpeg"
    end
    return result
end

local function estimate_audio_seconds(path)
    local attr = hs.fs.attributes(path)
    if not attr or not attr.size then
        return nil
    end
    return math.floor(attr.size / ASR_BYTES_PER_SEC)
end

local function run_asr_transcribe(task_label, on_success, on_error, audio_path, opts)
    local request_started_ns = hs.timer.absoluteTime()
    local source_audio = audio_path or AUDIO_FILE
    -- 委托给 ASR 服务层
    asr.transcribe(source_audio, function(text, error_code, metrics)
        local elapsed_ms = math.floor((hs.timer.absoluteTime() - request_started_ns) / 1e6)
        local request_ms = tonumber(metrics and metrics.request_ms) or elapsed_ms
        local retry_count = tostring(metrics and metrics.retry_count or "0")
        local provider_name = tostring(metrics and metrics.provider or ASR_RUNTIME.provider_name)
        local asr_model = tostring(metrics and metrics.model or ASR_RUNTIME.model_name)
        local provider_status = tostring(metrics and metrics.provider_status or (error_code and ("error_" .. tostring(error_code)) or "ok"))
        logf("[whisper] asr_request provider=%s model=%s request_ms=%d retry_count=%s provider_status=%s", provider_name, asr_model, request_ms, retry_count, provider_status)
        local fallback_from = tostring(metrics and metrics.fallback_from or "")
        if fallback_from ~= "" then
            local fallback_reason = tostring(metrics and metrics.fallback_reason or "")
            logf("[whisper] asr_fallback from=%s to=%s reason=%s", fallback_from, provider_name, fallback_reason)
            hs.alert.show("ASR备用通道: " .. provider_name, 1)
        end
        if error_code then
            local msg = asr.format_error(error_code)
            if on_error then
                on_error(msg, error_code, metrics)
            else
                hs.alert.show(string.format("%s 转录失败: %s", task_label or "ASR", msg))
            end
        else
            on_success(text, metrics)
        end
    end, opts)
end

local function start_recording()
    if is_recording then return end
    if not ensure_idle("F5") then
        return
    end
    
    logf("[whisper] starting recording (cloud ASR mode)")
    local cmd = record_script_command("start", RECORD_MAX_DURATION)
    local result = hs.execute(cmd, true)
    
    if result and result:match("missing_ffmpeg") then
        hs.alert.show("❌ 缺少 ffmpeg，无法录音")
        return
    end
    
    if result and result:match("recording") then
        is_recording = true
        recording_start_time = os.time()
        recording_start_tick_ns = hs.timer.absoluteTime()
        show_hud("record", { duration_sec = RECORD_MAX_DURATION })
        logf("[whisper] recording started")
    else
        hs.alert.show("录音启动失败")
    end
end

local function stop_recording()
    if not is_recording then return end
    local capture_ms = 0
    if recording_start_tick_ns then
        capture_ms = math.max(0, math.floor((hs.timer.absoluteTime() - recording_start_tick_ns) / 1e6))
    elseif recording_start_time then
        capture_ms = math.max(0, (os.time() - recording_start_time) * 1000)
    end
    
    -- 最短录音检测
    local min_duration = cfg_value(cfg.timing and cfg.timing.min_record_duration, 1)
    if recording_start_time and (os.time() - recording_start_time) < min_duration then
        hs.alert.show("⚡ 录音时间太短")
        return
    end
    
    logf("[whisper] stopping recording")
    is_recording = false
    recording_start_time = nil
    recording_start_tick_ns = nil
    
    local result = hs.execute(record_script_command("stop"), true)
    if not result or result:match("no_audio") then
        hide_hud()
        hs.alert.show("没有录到声音")
        return
    end
    
    local est_sec = estimate_audio_seconds(AUDIO_FILE)
    local function compute_f5_timeout_seconds(audio_sec)
        if not audio_sec then
            return math.max(5, math.min(MAX_PROCESSING_TIMEOUT_SEC, F5_ASR_TIMEOUT_LONG_SEC))
        end
        if audio_sec < F5_CHUNK.threshold_sec then
            if audio_sec <= F5_ASR_SHORT_THRESHOLD_SEC then
                return math.max(5, math.min(MAX_PROCESSING_TIMEOUT_SEC, F5_ASR_TIMEOUT_SHORT_SEC))
            end
            return math.max(5, math.min(MAX_PROCESSING_TIMEOUT_SEC, F5_ASR_TIMEOUT_LONG_SEC))
        end
        local step = math.max(1, F5_CHUNK.len_sec - F5_CHUNK.overlap_sec)
        local total_chunks = math.max(1, math.ceil(audio_sec / step))
        local waves = math.max(1, math.ceil(total_chunks / math.max(1, F5_CHUNK.parallel)))
        local asr_budget = waves * math.max(F5_CHUNK.asr_timeout_sec, F5_ASR_TIMEOUT_LONG_SEC)
        local post_budget = math.max(20, math.floor(audio_sec * 0.08))
        local extra = 20
        local timeout = asr_budget + post_budget + extra
        return math.max(F5_ASR_TIMEOUT_LONG_SEC, math.min(MAX_PROCESSING_TIMEOUT_SEC, timeout))
    end
    if est_sec then
        local timeout = compute_f5_timeout_seconds(est_sec)
        set_processing_timeout(timeout)
        logf("[whisper] f5_metrics capture_ms=%d est_audio_sec=%d timeout_sec=%d", capture_ms, est_sec, timeout)
    else
        local timeout = compute_f5_timeout_seconds(nil)
        set_processing_timeout(timeout)
        logf("[whisper] f5_metrics capture_ms=%d est_audio_sec=unknown timeout_sec=%d", capture_ms, timeout)
    end
    
    show_hud("processing", { duration_sec = processing_timeout_sec })
    start_processing()

    local function run_f5_post_pipeline(transcribed_text, source_label)
        local text = transcribed_text or ""
        logf("[whisper] transcribed: %d chars", #text)
        local pipeline_mode = resolve_f5_pipeline_mode(text)
        local post_started_ns = hs.timer.absoluteTime()
        local function finalize(result, prompt_key, model_type, pipeline_label)
            local output = result or ""
            local elapsed_post_ms = math.floor((hs.timer.absoluteTime() - post_started_ns) / 1e6)
            local pipe = tostring(pipeline_label or pipeline_mode)
            if source_label and source_label ~= "" then
                pipe = pipe .. "+" .. source_label
            end
            logf(
                "[whisper] f5_post_metrics prompt_key=%s model_type=%s post_ms=%d input_chars=%d output_chars=%d pipeline=%s",
                tostring(prompt_key or "f5_quick_polish"),
                tostring(model_type or F5_QUICK_POLISH_MODEL_TYPE or "default"),
                elapsed_post_ms,
                #text,
                #output,
                pipe
            )
            output_text(result, {
                log = {
                    action = "F5",
                    input = text,
                    prompt_key = prompt_key or "f5_quick_polish",
                },
            })
            if _G.meeting_assistant and _G.meeting_assistant.on_f5_completed then
                _G.meeting_assistant.on_f5_completed({
                    text = text,
                    output = output,
                    capture_ms = capture_ms,
                    est_audio_sec = est_sec,
                    pipeline = pipe,
                })
            end
            reset_processing_timeout()
        end

        local function run_quick_polish(source_text, done)
            refine_with_llm(source_text, function(polished)
                done(polished, "f5_quick_polish", F5_QUICK_POLISH_MODEL_TYPE)
            end, {
                prompt_key = "f5_quick_polish",
                user_prompt = "【原文】\n" .. source_text,
                use_glossary = true,
                model_type = F5_QUICK_POLISH_MODEL_TYPE,
                request_timeout_sec = 18,
                max_retries = 0,
                retry_on_statuses = {},
                suppress_error_alert = true,
                fallback_label = "raw_transcript",
            })
        end

        local function run_structured_polish(source_text, done)
            local instruction = "请按“总-分-总”结构输出：第一段总述，主体分点分段展开，最后一段给出总结或行动建议；保持原意，不新增事实。"
            refine_with_llm(source_text, function(structured)
                done(structured, "f7_polish", F5_REFINER.struct_model_type)
            end, {
                prompt_key = "f7_polish",
                user_prompt = "【原文】\n" .. source_text .. "\n\n【用户指令】\n" .. instruction,
                use_glossary = true,
                model_type = F5_REFINER.struct_model_type,
            })
        end

        if pipeline_mode == "f7_only" then
            run_structured_polish(text, function(result, prompt_key, model_type)
                finalize(result, prompt_key, model_type, pipeline_mode)
            end)
            return
        end

        if pipeline_mode == "f7_then_quick" then
            run_structured_polish(text, function(structured)
                run_quick_polish(structured, function(final_text, _, _)
                    finalize(final_text, "f5_f7_plus_quick", string.format("%s+%s", tostring(F5_REFINER.struct_model_type), tostring(F5_QUICK_POLISH_MODEL_TYPE)), pipeline_mode)
                end)
            end)
            return
        end

        run_quick_polish(text, function(result, prompt_key, model_type)
            finalize(result, prompt_key, model_type, pipeline_mode)
        end)
    end

    local function handle_asr_error(msg)
        finish_processing()
        hide_hud()
        reset_processing_timeout()
        hs.alert.show("转录失败: " .. msg)
    end

    local function run_single_asr()
        logf("[whisper] using cloud ASR provider=%s model=%s", ASR_RUNTIME.provider_name, ASR_RUNTIME.model_name)
        run_asr_transcribe("F5", function(text)
            run_f5_post_pipeline(text, "single")
        end, function(msg)
            handle_asr_error(msg)
        end, AUDIO_FILE)
    end

    -- 长音频自动分段：先切片再并发 ASR，最后按顺序合并。
    if est_sec and est_sec >= F5_CHUNK.threshold_sec then
        local ffmpeg = "/opt/homebrew/bin/ffmpeg"
        local ff_attr = hs.fs.attributes(ffmpeg)
        if not (ff_attr and ff_attr.mode == "file") then
            ffmpeg = trim_text(hs.execute("command -v ffmpeg 2>/dev/null", true) or "")
        end
        if ffmpeg == "" then
            logf("[whisper] f5_chunk_plan skipped: ffmpeg missing")
            run_single_asr()
            return
        end

        local chunk_len = math.max(8, F5_CHUNK.len_sec)
        local overlap = math.max(0, math.min(chunk_len - 1, F5_CHUNK.overlap_sec))
        local step = math.max(1, chunk_len - overlap)
        local chunk_dir = tmp_path(string.format("whisper_f5_chunks_%d_%d", os.time(), math.random(1000, 9999)))
        ensure_dir(chunk_dir)

        local specs = {}
        local start_sec = 0
        while start_sec < est_sec and #specs < 240 do
            local dur = math.min(chunk_len, math.max(1, est_sec - start_sec))
            local out = string.format("%s/chunk_%03d.wav", chunk_dir, #specs + 1)
            table.insert(specs, { idx = #specs + 1, start_sec = start_sec, dur_sec = dur, path = out })
            start_sec = start_sec + step
        end

        logf(
            "[whisper] f5_chunk_plan total_sec=%d chunk_len=%d overlap=%d chunks=%d parallel=%d",
            est_sec,
            chunk_len,
            overlap,
            #specs,
            F5_CHUNK.parallel
        )

        local generated = {}
        for _, spec in ipairs(specs) do
            local cmd = string.format(
                "%s -y -i %s -ss %d -t %d -ar 16000 -ac 1 -c:a pcm_s16le %s >/dev/null 2>&1",
                sh_escape(ffmpeg),
                sh_escape(AUDIO_FILE),
                spec.start_sec,
                spec.dur_sec,
                sh_escape(spec.path)
            )
            local ok = hs.execute(cmd, true)
            local attr = hs.fs.attributes(spec.path)
            if ok and attr and tonumber(attr.size or 0) > 512 then
                table.insert(generated, spec)
            else
                logf("[whisper] f5_chunk_generate_failed idx=%d start=%d dur=%d", spec.idx, spec.start_sec, spec.dur_sec)
            end
        end

        if #generated <= 1 then
            logf("[whisper] f5_chunk_plan fallback: generated_chunks=%d", #generated)
            run_single_asr()
            return
        end

        local results = {}
        local next_idx = 1
        local active = 0
        local completed = 0
        local failed = 0
        local total_chunks = #generated
        local max_parallel = math.max(1, math.min(F5_CHUNK.parallel, total_chunks))

        local function merge_results()
            local merged = ""
            for i = 1, total_chunks do
                local part = trim_text(results[i] or "")
                if part ~= "" then
                    if merged == "" then
                        merged = part
                    else
                        local max_overlap = math.min(120, #merged, #part)
                        local cut = 0
                        for k = max_overlap, 8, -1 do
                            if merged:sub(-k) == part:sub(1, k) then
                                cut = k
                                break
                            end
                        end
                        if cut > 0 then
                            merged = merged .. part:sub(cut + 1)
                        else
                            merged = merged .. "\n" .. part
                        end
                    end
                end
            end
            logf("[whisper] f5_chunk_merge total_chars=%d chunk_count=%d failed_chunks=%d", #merged, total_chunks, failed)
            if merged == "" then
                handle_asr_error("分段转录为空")
                return
            end
            run_f5_post_pipeline(merged, "chunked")
        end

        local function launch_next()
            while active < max_parallel and next_idx <= total_chunks do
                local spec = generated[next_idx]
                local idx = next_idx
                local started_ns = hs.timer.absoluteTime()
                next_idx = next_idx + 1
                active = active + 1
                run_asr_transcribe("F5 Chunk", function(chunk_text, metrics)
                    local asr_ms = tonumber(metrics and metrics.request_ms) or math.floor((hs.timer.absoluteTime() - started_ns) / 1e6)
                    local text = trim_text(chunk_text or "")
                    results[idx] = text
                    logf("[whisper] f5_chunk_metrics idx=%d/%d asr_ms=%d post_ms=0 chars=%d", idx, total_chunks, asr_ms, #text)
                    if F5_CHUNK.emit_partial and text ~= "" then
                        show_command_status(string.format("F5 分段进度 %d/%d", idx, total_chunks), 0.5)
                    end
                    active = active - 1
                    completed = completed + 1
                    if completed >= total_chunks then
                        merge_results()
                        return
                    end
                    launch_next()
                end, function(msg)
                    failed = failed + 1
                    results[idx] = ""
                    logf("[whisper] f5_chunk_metrics idx=%d/%d asr_ms=0 post_ms=0 chars=0 error=%s", idx, total_chunks, tostring(msg))
                    active = active - 1
                    completed = completed + 1
                    if completed >= total_chunks then
                        merge_results()
                        return
                    end
                    launch_next()
                end, spec.path, {
                    timeout_sec = F5_CHUNK.asr_timeout_sec,
                })
            end
        end

        launch_next()
        return
    end

    run_single_asr()
end

local function toggle_recording()
    if is_recording then
        stop_recording()
    else
        start_recording()
    end
end

local function run_f5_system_dictation()
    if not ENABLE_SYSTEM_DICTATION then
        hs.alert.show("⚙️ 系统听写已禁用（实验功能）", 2)
        hs.printf("[whisper] F5 blocked: system dictation disabled")
        return
    end
    if not dictation then
        hs.alert.show("系统听写模块未加载")
        hs.printf("[whisper] F5 blocked: dictation module missing")
        return
    end
    if dictation.is_active() then
        if dictation.get_mode() ~= "f5" then
            hs.alert.show("系统听写进行中，请按对应功能键结束")
            return
        end
        dictation.stop()
        return
    end
    if not ensure_idle("F5") then
        return
    end
    local target_app = hs.application.frontmostApplication()
    dictation.start("f5", target_app, nil)
end

-- ========================================
-- 热键绑定
-- ========================================

hs.hotkey.bind({}, "f5", function()
    hs.printf("[whisper] F5 pressed, is_recording=%s", tostring(is_recording))
    if INPUT_MODE == "system" then
        run_f5_system_dictation()
        return
    end
    toggle_recording()
end)

-- F7 快速润色（全选文本）
local function run_f7_polish_action(task_label)
    hs.printf("[whisper] %s - polish selection", task_label or "F7")
    hs.eventtap.keyStroke({ "cmd" }, "a")
    hs.timer.doAfter(cfg_value(cfg.timing and cfg.timing.selection_delay, 0.3), function()
        capture_selection_safe(function(text)
            if not text or text == "" then
                hs.alert.show("没有选中文本")
                return
            end
            refine_with_llm(text, function(refined)
                hs.eventtap.keyStroke({ "cmd" }, "a")
                output_text(refined, {
                    log = {
                        action = "F7",
                        input = text,
                        prompt_key = "f7_polish",
                    },
                })
            end, {
                prompt_key = "f7_polish",
                user_prompt = "【原文】\n" .. text,
            })
        end)
    end)
end

hs.hotkey.bind({}, "f7", function()
    if not ensure_idle("F7") then
        return
    end
    run_f7_polish_action("F7")
end)

-- ========================================
-- F6 选区+语音指令模式
-- ========================================
local f6_selected_text = nil
local f6_target_app = nil

-- F6 专用 Prompt
local system_prompt_selection = [[你是文本改写执行助手。
任务：按用户指令修改原文，同时确保语法正确、逻辑完整。

基座规则（必须执行）：
1. 语法修正：确保无错别字、标点正确、主谓/动宾搭配正确、指代清晰
2. 逻辑补全：补全因执行指令可能产生的逻辑断裂，消除隐含矛盾

执行规则：
- 仅执行【用户指令】明确要求的修改
- 指令未涉及的内容严格保持原样
- 不回答指令本身，不解释原因

优先级：若指令与逻辑补全冲突，以执行用户指令为优先。

输出：直接返回修改后的完整文本，无标记。]]

run_f6_llm = function(selected_text, instruction, target_app)
    -- HUD 显示（在服务层之外管理）
    show_hud("processing", { duration_sec = processing_timeout_sec })
    start_processing()

    local user_prompt = string.format("【原文】\n%s\n\n【用户指令】\n%s", selected_text, instruction)

    -- 委托给服务层（新增重试能力）
    safe_llm_request({
        text = selected_text,
        prompt_key = "f6_selection",
        user_prompt = user_prompt,
        task_label = "F6",
        enable_retry = true,
    }, function(result, error)
        finish_processing()

        if error then
            hide_hud()
            hs.alert.show("❌ F6失败 " .. error, 3)
            return
        end

        if result then
            local function finalize(final_result)
                if target_app then
                    target_app:activate()
                end
                hs.timer.doAfter(0.1, function()
                    hs.eventtap.keyStroke({ "cmd" }, "a")
                    output_text(final_result, {
                        log = {
                            action = "F6",
                            input = selected_text,
                            instruction = instruction,
                            prompt_key = "f6_selection",
                        },
                    })
                end)
            end
            if AUTO_F7_AFTER_F6 then
                apply_f7_polish(result, finalize)
            else
                finalize(result)
            end
        else
            hide_hud()
            hs.alert.show("❌ F6 解析失败")
        end
    end)
end

if ENABLE_SYSTEM_DICTATION then
    local loader = dofile(SCRIPT_DIR .. "/system_dictation.lua")
    dictation = loader({
        show_hud = show_hud,
        hide_hud = hide_hud,
        output_text = output_text,
        refine_with_llm = refine_with_llm,
        apply_f7_polish = apply_f7_polish,
        run_f6_llm = run_f6_llm,
        auto_f7_after_f5 = AUTO_F7_AFTER_F5,
        start_processing = start_processing,
    })
end

local function run_f6_system_dictation()
    if not ENABLE_SYSTEM_DICTATION then
        hs.alert.show("⚙️ 系统听写已禁用（实验功能）", 2)
        hs.printf("[whisper] F6 blocked: system dictation disabled")
        return
    end
    if not dictation then
        hs.alert.show("系统听写模块未加载")
        hs.printf("[whisper] F6 blocked: dictation module missing")
        return
    end
    if dictation.is_active() then
        if dictation.get_mode() ~= "f6" then
            hs.alert.show("系统听写进行中，请按对应功能键结束")
            return
        end
        dictation.stop()
        return
    end
    if not ensure_idle("F6") then
        return
    end
    hs.printf("[whisper] F6 start - capture selection and dictation instruction")
    f6_target_app = hs.application.frontmostApplication()
    hs.eventtap.keyStroke({ "cmd" }, "a")
    hs.timer.doAfter(cfg_value(cfg.timing and cfg.timing.selection_delay, 0.3), function()
        capture_selection_safe(function(text)
            if not text or text == "" then
                hs.alert.show("没有选中文本")
                f6_target_app = nil
                return
            end
            dictation.start("f6", f6_target_app, text)
            f6_target_app = nil
        end)
    end)
end

hs.hotkey.bind({}, "f6", function()
    if INPUT_MODE == "system" then
        run_f6_system_dictation()
        return
    end
    if f6_recording then
        -- 停止录音，执行指令
        f6_recording = false
        hs.printf("[whisper] F6 stop - executing instruction")
        
        local result = hs.execute(record_script_command("stop"), true)
        if not result or result:match("no_audio") then
            hide_hud()
            hs.alert.show("没有录到指令")
            f6_selected_text = nil
            return
        end
        
        show_hud("asr", { duration_sec = processing_timeout_sec })
        start_processing()
        
        -- 使用云端 ASR 转录指令
        run_asr_transcribe("F6 指令", function(instruction)
            instruction = instruction:gsub("^%s*(.-)%s*$", "%1")
            hs.printf("[whisper] F6 instruction: %s", instruction)
            run_f6_llm(f6_selected_text, instruction, f6_target_app)
            f6_selected_text = nil
            f6_target_app = nil
        end, function(msg)
            finish_processing()
            hide_hud()
            hs.alert.show("指令识别失败: " .. msg)
            f6_selected_text = nil
            f6_target_app = nil
        end)
    else
        if not ensure_idle("F6") then
            return
        end
        -- 第一次按：捕获选区，开始录音
        hs.printf("[whisper] F6 start - capture selection and record instruction")
        f6_target_app = hs.application.frontmostApplication()
        hs.eventtap.keyStroke({ "cmd" }, "a")
        hs.timer.doAfter(0.1, function()
            capture_selection_safe(function(text)
                if not text or text == "" then
                    hs.alert.show("没有选中文本")
                    f6_target_app = nil
                    return
                end
                f6_selected_text = text
                
                -- 开始录音
                local result = start_record_command()
                if result == "missing_ffmpeg" then
                    hs.alert.show("❌ 缺少 ffmpeg，无法录音")
                    f6_selected_text = nil
                    f6_target_app = nil
                    return
                end
                if result and result:match("recording") then
                    f6_recording = true
                    show_hud("record", { duration_sec = COMMAND_RECORD_SEC })
                    hs.alert.show("🎤 说指令，再按 F6 执行")
                else
                    hs.alert.show("录音启动失败")
                    f6_selected_text = nil
                    f6_target_app = nil
                end
            end)
        end)
    end
end)

-- ========================================
-- 通用 LLM 处理函数（支持模型选择）
-- ========================================

function trim_text(s)
    return utils.trim(s)
end

local function keep_first_sentence(text)
    local line = text:gsub("\r\n", "\n"):match("([^\n]+)") or text
    local _, end_pos = line:find("[。！？!?]")
    if end_pos then
        return line:sub(1, end_pos)
    end
    return line
end

local function utf8_len_safe(text)
    local ok, len = pcall(utf8.len, text)
    if ok and type(len) == "number" then
        return len
    end
    return #text
end

local function utf8_prefix(text, chars)
    if chars <= 0 then
        return ""
    end
    local ok, offset = pcall(utf8.offset, text, chars + 1)
    if ok and offset then
        return text:sub(1, offset - 1)
    end
    return text
end

local function find_last_plain_end(text, needle)
    local start_at = 1
    local last_end = nil
    while true do
        local i = text:find(needle, start_at, true)
        if not i then
            break
        end
        last_end = i + #needle - 1
        start_at = i + 1
    end
    return last_end
end

local function soft_truncate(text, max_len)
    if utf8_len_safe(text) <= max_len then
        return text
    end
    local prefix = utf8_prefix(text, max_len)
    local lower_prefix = utf8_prefix(text, math.max(1, max_len - 40))
    local lower_byte = #lower_prefix
    local best_end = nil
    local sentence_enders = { "。", "！", "？", "!", "?" }
    for _, p in ipairs(sentence_enders) do
        local end_pos = find_last_plain_end(prefix, p)
        if end_pos and end_pos >= lower_byte then
            if not best_end or end_pos > best_end then
                best_end = end_pos
            end
        end
    end
    if not best_end then
        local safe_punctuations = { "；", ";" }
        for _, p in ipairs(safe_punctuations) do
            local end_pos = find_last_plain_end(prefix, p)
            if end_pos and end_pos >= lower_byte then
                if not best_end or end_pos > best_end then
                    best_end = end_pos
                end
            end
        end
    end
    local out
    if best_end then
        out = trim_text(prefix:sub(1, best_end))
    else
        out = trim_text(prefix)
    end
    -- Truncate 内部保证输出完整性，避免悬挂标点。
    out = out:gsub("[，,；;：:]+$", "")
    return trim_text(out)
end

local function clean_generated_text(text, profile)
    local output = trim_text(text)
    output = output:gsub("<[Tt][Hh][Ii][Nn][Kk][^>]->[\0-\255]-</[Tt][Hh][Ii][Nn][Kk]>", "")
    output = output:gsub("<[Tt][Hh][Ii][Nn][Kk][Ii][Nn][Gg][^>]->[\0-\255]-</[Tt][Hh][Ii][Nn][Kk][Ii][Nn][Gg]>", "")
    output = output:gsub("`", "")
    output = output:gsub("——", "，")
    output = output:gsub("^%s*[%*#>%-%d%.%s]+", "")
    output = output:gsub('^["“”\'`]+', ""):gsub('["“”\'`]+$', "")
    local labels = { "核心洞察", "分析", "结晶", "输出", "结果", "答案", "回复", "段子手", "逻辑锚点", "核心观点" }
    for _, label in ipairs(labels) do
        output = output:gsub("^%s*" .. label .. "%s*[：:]", "")
    end
    output = trim_text(output)

    if profile == "single_line" then
        output = keep_first_sentence(output)
        output = soft_truncate(output, 70)
    elseif profile == "critique" then
        output = output:gsub("首先[，,]?", "")
        output = output:gsub("其次[，,]?", "")
        output = output:gsub("最后[，,]?", "")
        output = output:gsub("综上[，,]?", "")
        output = output:gsub("\n+", "")
        output = soft_truncate(trim_text(output), 150)
    elseif profile == "philo" then
        output = output:gsub("\n+", "")
        output = soft_truncate(trim_text(output), 220)
    end
    -- 统一尾部完整性清理，避免出现悬挂逗号/分号。
    output = trim_text(output):gsub("[，,；;：:]+$", "")
    return trim_text(output)
end

local function split_nonempty_lines(text)
    local lines = {}
    for line in tostring(text or ""):gmatch("[^\r\n]+") do
        local v = trim_text(line)
        if v ~= "" then
            table.insert(lines, v)
        end
    end
    return lines
end

local function sentence_count(text)
    local count = 0
    for _ in tostring(text or ""):gmatch("[。！？!?]") do
        count = count + 1
    end
    if count == 0 and trim_text(text or "") ~= "" then
        count = 1
    end
    return count
end

local function has_markdown_noise(text)
    local value = tostring(text or "")
    return value:find("**", 1, true) ~= nil
        or value:find("```", 1, true) ~= nil
        or value:match("^%s*[%-%*#]") ~= nil
        or value:match("\n%s*[%-%*#]") ~= nil
        or value:match("\n%s*%d+%.") ~= nil
end

local function validate_quality_output(gate, text)
    local value = trim_text(text or "")
    if value == "" then
        return false, "empty"
    end

    if gate == "translate" then
        if value:find("译文", 1, true) or value:find("translation", 1, true) then
            return false, "contains_meta"
        end
        if value:find("请提供", 1, true) then
            return false, "unexpected_ask_for_input"
        end
        return true, nil
    end

    if gate == "summary" then
        if has_markdown_noise(value) then
            return false, "markdown_noise"
        end
        local n = sentence_count(value)
        if n > 4 then
            return false, "too_many_sentences"
        end
        return true, nil
    end

    if gate == "check" then
        if value == "未发现问题" then
            return true, nil
        end
        if has_markdown_noise(value) then
            return false, "markdown_noise"
        end
        local lines = split_nonempty_lines(value)
        if #lines == 0 then
            return false, "empty_lines"
        end
        for _, line in ipairs(lines) do
            if not line:find("：", 1, true) and not line:find(":", 1, true) then
                return false, "line_without_separator"
            end
        end
        return true, nil
    end

    return true, nil
end

-- model_type: "fast" 或 "strong"
local function llm_transform(system_prompt, user_prompt, fallback_text, model_type, task_label, opts)
    opts = opts or {}
    if is_processing and not opts.allow_busy then
        hs.alert.show("⏳ 处理中，请稍候...")
        return
    end

    -- HUD 显示（在服务层之外管理）
    show_hud("processing", { duration_sec = processing_timeout_sec })
    start_processing()

    local effective_model_type = model_type
    if model_type == "fast" and tonumber(opts.fast_upgrade_threshold) and tonumber(opts.fast_upgrade_threshold) > 0 then
        local input_len = utf8_len_safe(user_prompt or "")
        local threshold = math.floor(tonumber(opts.fast_upgrade_threshold))
        if input_len >= threshold then
            effective_model_type = opts.fast_upgrade_model or "strong"
            hs.printf("[whisper] fast task upgraded: %s -> %s (len=%d threshold=%d)", model_type, effective_model_type, input_len, threshold)
        end
    end

    -- 委托给服务层
    safe_llm_request({
        text = user_prompt,
        system_prompt = system_prompt,
        model_type = effective_model_type,
        task_label = task_label,
        enable_retry = true,
    }, function(result, error)
        if error then
            finish_processing()
            hide_hud()
            local label = task_label or "LLM"
            hs.alert.show("❌ " .. label .. " 失败 " .. error, 3)
            return
        end

        local function deliver_content(raw_content, final_model_type, fallback_reason)
            local content = raw_content or fallback_text
            if content and opts.post_profile then
                content = clean_generated_text(content, opts.post_profile)
            end
            if content then
                hs.eventtap.keyStroke({ "cmd" }, "a")
                local log = opts.log and {
                    action = opts.log.action,
                    input = opts.log.input,
                    prompt_key = opts.log.prompt_key,
                    model_type = final_model_type or effective_model_type,
                    quality_fallback = fallback_reason or "",
                } or nil
                finish_processing()
                output_text(content, { log = log })
            else
                finish_processing()
                hide_hud()
                local label = task_label or "LLM"
                hs.alert.show(label .. " 解析失败")
            end
        end

        local content = result or fallback_text
        local gate = opts.quality_gate
        local fallback_model_type = opts.quality_fallback_model
        if gate and fallback_model_type and content and effective_model_type == "fast" then
            local ok, reason = validate_quality_output(gate, content)
            if not ok then
                hs.printf("[whisper] quality gate failed: gate=%s reason=%s fallback=%s", gate, tostring(reason), fallback_model_type)
                safe_llm_request({
                    text = user_prompt,
                    system_prompt = system_prompt,
                    model_type = fallback_model_type,
                    task_label = task_label,
                    enable_retry = true,
                }, function(fallback_result, fallback_error)
                    if fallback_error then
                        hs.printf("[whisper] quality fallback request failed: %s", tostring(fallback_error))
                        deliver_content(content, effective_model_type, "fallback_request_failed")
                        return
                    end
                    local fallback_content = fallback_result or content
                    local ok2, reason2 = validate_quality_output(gate, fallback_content)
                    if not ok2 then
                        hs.printf("[whisper] quality fallback still failed: gate=%s reason=%s", gate, tostring(reason2))
                        deliver_content(fallback_content, fallback_model_type, "fallback_still_unqualified")
                        return
                    end
                    deliver_content(fallback_content, fallback_model_type, reason)
                end)
                return
            end
        end
        deliver_content(content, effective_model_type, nil)
    end)
end

-- model_type: "fast" 或 "strong"
-- prompt_key: 热加载 Prompt 的 key（可选，优先于 system_prompt）
local function get_selection_and_transform(system_prompt, task_name, model_type, prompt_key, opts)
    if not ensure_idle(task_name) then
        return
    end
    opts = opts or {}
    hs.printf("[whisper] %s", task_name)
    if opts.force_full then
        hs.printf("[whisper] 强制处理全文")
        capture_full_text(function(full_text)
            if not full_text or full_text == "" then
                hs.alert.show("未能获取全文，请确认光标在可编辑区域")
                return
            end
            local prompt = system_prompt
            if prompt_key then
                prompt = load_prompt(prompt_key) or system_prompt
            end
            llm_transform(prompt, full_text, full_text, model_type, task_name, {
                post_profile = opts.post_profile,
                quality_gate = opts.quality_gate,
                quality_fallback_model = opts.quality_fallback_model,
                log = {
                    action = task_name,
                    input = full_text,
                    prompt_key = prompt_key,
                },
            })
        end)
        return
    end
    capture_selection_safe(function(text)
        if text and text ~= "" then
            local prompt = system_prompt
            if prompt_key then
                prompt = load_prompt(prompt_key) or system_prompt
            end
            llm_transform(prompt, text, text, model_type, task_name, {
                post_profile = opts.post_profile,
                quality_gate = opts.quality_gate,
                quality_fallback_model = opts.quality_fallback_model,
                log = {
                    action = task_name,
                    input = text,
                    prompt_key = prompt_key,
                },
            })
            return
        end
        hs.printf("[whisper] 未检测到选区，将处理全文")
        capture_full_text(function(full_text)
            if not full_text or full_text == "" then
                hs.alert.show("未能获取全文，请确认光标在可编辑区域")
                return
            end
            local prompt = system_prompt
            if prompt_key then
                prompt = load_prompt(prompt_key) or system_prompt
            end
            llm_transform(prompt, full_text, full_text, model_type, task_name, {
                post_profile = opts.post_profile,
                quality_gate = opts.quality_gate,
                quality_fallback_model = opts.quality_fallback_model,
                log = {
                    action = task_name,
                    input = full_text,
                    prompt_key = prompt_key,
                },
            })
        end)
    end)
end

local function should_force_full_for_alt()
    return ALT_SELECTION_POLICY ~= "selected_first"
end

local function build_alt_opts(opts)
    local out = {}
    if type(opts) == "table" then
        for k, v in pairs(opts) do
            out[k] = v
        end
    end
    if out.force_full == nil then
        out.force_full = should_force_full_for_alt()
    end
    return out
end

-- ========================================
-- Alt+E 翻译（使用热加载）
-- ========================================
local prompt_translate = "请按要求处理以下文本，输出纯文本，不解释。"

local function run_alt_translate_action(task_name)
    get_selection_and_transform(prompt_translate, task_name or "Alt+E - 翻译", "fast", "alt_e_translate", build_alt_opts({
        quality_gate = "translate",
        quality_fallback_model = "strong",
        fast_upgrade_threshold = 1200,
        fast_upgrade_model = "strong",
    }))
end

hs.hotkey.bind({ "alt" }, "e", function()
    run_alt_translate_action("Alt+E - 翻译")
end)

-- ========================================
-- Alt+W 深度表达/意图补全（使用热加载）
-- ========================================
local prompt_articulate = "请按要求处理以下文本，输出纯文本，不解释。"

hs.hotkey.bind({ "alt" }, "w", function()
    if ALT_W_USE_STREAM then
        get_selection_and_stream_transform(prompt_articulate, "Alt+W - 深度表达", "strong", "alt_w_articulate", build_alt_opts())
    else
        get_selection_and_transform(prompt_articulate, "Alt+W - 深度表达", "strong", "alt_w_articulate", build_alt_opts())
    end
end)

-- ========================================
-- Alt+Q 结构化 Prompt（使用热加载）
-- ========================================
local prompt_struct = "请按要求处理以下文本，输出纯文本，不解释。"

hs.hotkey.bind({ "alt" }, "q", function()
    get_selection_and_transform(prompt_struct, "Alt+Q - 结构化 Prompt", "strong", "alt_q_struct", build_alt_opts())
end)

-- ========================================
-- Alt+A 快速摘要（使用热加载）
-- ========================================
local prompt_summary = "请按要求处理以下文本，输出纯文本，不解释。"

local function run_alt_summary_action(task_name)
    get_selection_and_transform(prompt_summary, task_name or "Alt+A - 快速摘要", "fast", "alt_a_summary", build_alt_opts({
        quality_gate = "summary",
        quality_fallback_model = "strong",
        fast_upgrade_threshold = 900,
        fast_upgrade_model = "strong",
    }))
end

hs.hotkey.bind({ "alt" }, "a", function()
    run_alt_summary_action("Alt+A - 快速摘要")
end)

-- ========================================
-- Rime 命令桥接（/hs <action>）
-- ========================================
local rime_bridge = require("services.rime_bridge")
rime_bridge.setup({
    get_busy_reason = busy_reason,
    actions = {
        polish = function()
            run_f7_polish_action("Rime /hs polish")
        end,
        translate = function()
            run_alt_translate_action("Rime /hs translate")
        end,
        summary = function()
            run_alt_summary_action("Rime /hs summary")
        end,
    },
})
_G.rime_dispatch = rime_bridge.dispatch

-- ========================================
-- Alt+C 纠错检查（使用热加载）
-- ========================================
local prompt_check = "请按要求处理以下文本，输出纯文本，不解释。"

hs.hotkey.bind({ "alt" }, "c", function()
    get_selection_and_transform(prompt_check, "Alt+C - 纠错检查", "fast", "alt_c_check", build_alt_opts({
        quality_gate = "check",
        quality_fallback_model = "strong",
        fast_upgrade_threshold = 700,
        fast_upgrade_model = "strong",
    }))
end)

-- ========================================
-- Alt+Z 步骤拆解（使用热加载）
-- ========================================
local prompt_steps = "请按要求处理以下文本，输出纯文本，不解释。"

if ENABLE_ALT_Z then
    hs.hotkey.bind({ "alt" }, "z", function()
        get_selection_and_transform(prompt_steps, "Alt+Z - 步骤拆解", "fast", "alt_z_steps", build_alt_opts())
    end)
else
    hs.printf("[whisper] Alt+Z disabled by config.features.enable_alt_z=false")
end

-- ========================================
-- Alt+X 批判性分析
-- ========================================
local prompt_critique = "请按要求处理以下文本，输出纯文本，不解释。"

hs.hotkey.bind({ "alt" }, "x", function()
    get_selection_and_transform(prompt_critique, "Alt+X - 批判性分析", "strong", "alt_x_critique", {
        post_profile = "critique",
        force_full = should_force_full_for_alt(),
    })
end)

-- ========================================
-- Alt+R 探赜索隐（创作流）
-- ========================================
local prompt_philo = "请按要求处理以下文本，输出纯文本，不解释。"

hs.hotkey.bind({ "alt" }, "r", function()
    get_selection_and_transform(prompt_philo, "Alt+R - 探赜索隐", "strong", "alt_r_philo", {
        force_full = should_force_full_for_alt(),
        post_profile = "philo",
    })
end)

-- ========================================
-- Alt+J 王兴饭否金句（创作流）
-- ========================================
local prompt_fanfou = "请按要求处理以下文本，输出纯文本，不解释。"

hs.hotkey.bind({ "alt" }, "j", function()
    get_selection_and_transform(prompt_fanfou, "Alt+J - 饭否金句", "strong", "alt_j_fanfou", {
        force_full = should_force_full_for_alt(),
        post_profile = "single_line",
    })
end)

-- ========================================
-- F8 一键助手模式（已提取至 services/f8.lua）
-- ========================================

local function hide_command_status()
    ui.hide_command_status()
end

local function show_command_status(text, timeout)
    ui.show_command_status(text, timeout)
end

local function has_active_work()
    if is_recording or f6_recording or command_mode_active or is_processing then
        return true
    end
    if dictation and dictation.is_active() then
        return true
    end
    if stream_timer or ui.has_stream() then
        return true
    end
    return false
end

local function is_recording_process()
    local status = hs.execute(record_script_command("status"), true) or ""
    return status:match("recording") ~= nil
end

local function cancel_all()
    local had_work = has_active_work() or is_recording_process()
    logf("[whisper] cancel_all triggered, had_work=%s", tostring(had_work))
    if dictation and dictation.is_active() then
        dictation.stop()
    end

    hs.execute(record_script_command("stop"), true)

    is_recording = false
    f6_recording = false
    command_mode_active = false
    recording_start_time = nil
    f6_selected_text = nil
    f6_target_app = nil

    llm.invalidate_requests()
    asr.invalidate_requests()
    pcall(function()
        if f8 and f8.cleanup then
            f8.cleanup()
        end
    end)
    finish_processing()
    reset_processing_timeout()

    hide_hud()
    hide_stream_hud()
    hide_command_status()
    if stream_task then
        stream_task:terminate()
        stream_task = nil
    end

    if had_work then
        hs.alert.show("已取消", 1)
    end
end

local esc_tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
    if event:getKeyCode() == hs.keycodes.map.escape then
        local busy = has_active_work()
        local recording = is_recording_process()
        if busy or recording then
            logf("[whisper] ESC pressed, busy=%s, recording_process=%s", tostring(busy), tostring(recording))
            cancel_all()
            return true
        end
    end
    return false
end)
esc_tap:start()

local f8 = require("services.f8")
f8.setup({
    config = cfg,
    llm = llm,
    logf = logf,
    append_transcript = append_transcript,
    send_to_flomo = send_to_flomo,
    ensure_idle = ensure_idle,
    show_hud = show_hud,
    hide_hud = hide_hud,
    update_hud = update_hud,
    show_command_status = show_command_status,
    soft_truncate = soft_truncate,
    get_front_app_info = get_front_app_info,
    set_processing_timeout = set_processing_timeout,
    reset_processing_timeout = reset_processing_timeout,
    set_processing = function(v) is_processing = v end,
    set_processing_start_time = function(v) processing_start_time = v end,
    set_command_mode = function(v) command_mode_active = v end,
    runtime_usage = RUNTIME_USAGE,
    script_dir = SCRIPT_DIR,
    transcript_dir = TRANSCRIPT_DIR,
    glossary_file = GLOSSARY_FILE,
    command_status_done_sec = COMMAND_STATUS_DONE_SEC,
    default_processing_timeout_sec = DEFAULT_PROCESSING_TIMEOUT_SEC,
    processing_timeout_sec = processing_timeout_sec,
})

if f8.get_mode() == "digest" then
    hs.hotkey.bind({}, "f8", function()
        hs.printf("[whisper] F8 pressed, mode=digest")
        f8.run_digest()
    end)
else
    hs.hotkey.bind({}, "f8", function()
        hs.printf("[whisper] F8 pressed, mode=workflow processing=%s", tostring(is_processing))
        f8.run_workflow()
    end)
end

_G.meeting_assistant = require("services.meeting_assistant")
_G.meeting_assistant.setup({
    config = cfg,
    script_dir = SCRIPT_DIR,
    transcript_dir = TRANSCRIPT_DIR,
    glossary_file = GLOSSARY_FILE,
    llm = llm,
    logf = logf,
    append_transcript = append_transcript,
    send_to_flomo = send_to_flomo,
    ensure_idle = ensure_idle,
    show_status = show_command_status,
})

-- 切换输入模式（系统听写 / Hammerspoon 录音）
if ENABLE_SYSTEM_DICTATION then
    hs.hotkey.bind({ "ctrl", "alt" }, "i", function()
        toggle_input_mode()
    end)
end

-- ========================================
-- 启动信息
-- ========================================
local function build_startup_message()
    local lines = { "Whisper 已加载" }
    if INPUT_MODE == "hammerspoon" then
        table.insert(lines, "输入：Hammerspoon 录音")
    else
        table.insert(lines, "输入：系统听写")
    end
    if not ENABLE_SYSTEM_DICTATION then
        table.insert(lines, "系统听写：已禁用（实验功能）")
    end
    local hotkeys = {}
    if INPUT_MODE == "hammerspoon" then
        table.insert(hotkeys, "F5录音")
        table.insert(hotkeys, "F6选区+指令")
    else
        table.insert(hotkeys, "F5听写(再按结束)")
        table.insert(hotkeys, "F6听写指令(再按结束)")
    end
    table.insert(hotkeys, "F7润色")
    if f8.get_mode() then
        if f8.get_mode() == "digest" then
            table.insert(hotkeys, "F8一键总结(兼容)")
        else
            table.insert(hotkeys, "F8项目情报")
        end
    end
    if cfg_value(cfg.meeting and cfg.meeting.enabled, false) then
        table.insert(hotkeys, "Alt+M纪要")
        table.insert(hotkeys, "Alt+N周月报")
        table.insert(hotkeys, "Ctrl+Alt+M全链路")
    end
    table.insert(hotkeys, "ESC取消")
    local alt_keys = { "E", "W", "Q", "A", "C" }
    if ENABLE_ALT_Z then
        table.insert(alt_keys, "Z")
    end
    table.insert(alt_keys, "X")
    table.insert(alt_keys, "R")
    table.insert(alt_keys, "J")
    table.insert(hotkeys, "Alt+" .. table.concat(alt_keys, "/"))
    table.insert(lines, table.concat(hotkeys, " "))
    return table.concat(lines, "\n")
end

hs.alert.show(build_startup_message(), 3)
logf(
    "[whisper] ui_mode primary=%s command_hud=%s",
    tostring(cfg_value(cfg.ui and cfg.ui.status_primary, "overlay")),
    tostring(cfg_value(cfg.ui and cfg.ui.command_hud_mode, "all"))
)
logf("[whisper] init.lua loaded - optimized version with cloud ASR")

-- ==================== 菜单栏内存监控 ====================
local memory_monitor = require("services.memory_monitor")
memory_monitor.start(cfg, RUNTIME_USAGE, logf)
-- ==================== 菜单栏内存监控结束 ====================

-- ==================== reload 前集中清理 ====================
cleanup_before_reload = function()
    pcall(function() if stream_task then stream_task:terminate(); stream_task = nil end end)
    pcall(function() asr.invalidate_requests() end)
    pcall(function() f8.cleanup() end)
    pcall(function() memory_monitor.stop() end)
end
