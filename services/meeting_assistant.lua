local M = {}

local utils = require("lib.utils")
local cfg_value = utils.cfg_value
local trim = utils.trim
local sh_escape = utils.sh_escape
local ensure_dir = utils.ensure_dir

local settings = nil
local deps = nil

local LEVEL_ORDER = {
    L0 = 0,
    L1 = 1,
    L2 = 2,
    L3 = 3,
}

local function write_text(path, content)
    local parent = path:match("(.+)/[^/]+$")
    if parent then
        ensure_dir(parent)
    end
    local f = io.open(path, "w")
    if not f then
        return false
    end
    f:write(content or "")
    f:close()
    return true
end

local function append_csv_row(path, row)
    local parent = path:match("(.+)/[^/]+$")
    if parent then
        ensure_dir(parent)
    end
    local exists = io.open(path, "r")
    if exists then
        exists:close()
    else
        local h = io.open(path, "w")
        if h then
            h:write("ts,meeting_id,source,owner,due,status,task\n")
            h:close()
        end
    end
    local function esc(v)
        local s = tostring(v or "")
        s = s:gsub('"', '""')
        return '"' .. s .. '"'
    end
    local f = io.open(path, "a")
    if not f then
        return false
    end
    f:write(table.concat({
        esc(row.ts),
        esc(row.meeting_id),
        esc(row.source),
        esc(row.owner),
        esc(row.due),
        esc(row.status),
        esc(row.task),
    }, ","), "\n")
    f:close()
    return true
end

local function read_json_file(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local raw = f:read("*all") or ""
    f:close()
    local ok, data = pcall(hs.json.decode, raw)
    if not ok or type(data) ~= "table" then
        return nil
    end
    return data
end

local function write_json_file(path, payload)
    local raw = hs.json.encode(payload)
    if not raw then
        return false
    end
    return write_text(path, raw .. "\n")
end

local function read_jsonl(path)
    local out = {}
    local f = io.open(path, "r")
    if not f then
        return out
    end
    for line in f:lines() do
        local s = trim(line)
        if s ~= "" then
            local ok, row = pcall(hs.json.decode, s)
            if ok and type(row) == "table" then
                table.insert(out, row)
            end
        end
    end
    f:close()
    return out
end

local function write_jsonl(path, rows)
    local parent = path:match("(.+)/[^/]+$")
    if parent then
        ensure_dir(parent)
    end
    local f = io.open(path, "w")
    if not f then
        return false
    end
    for _, row in ipairs(rows or {}) do
        local line = hs.json.encode(row)
        if line then
            f:write(line, "\n")
        end
    end
    f:close()
    return true
end

local function append_jsonl(path, row)
    local parent = path:match("(.+)/[^/]+$")
    if parent then
        ensure_dir(parent)
    end
    local f = io.open(path, "a")
    if not f then
        return false
    end
    local line = hs.json.encode(row)
    if not line then
        f:close()
        return false
    end
    f:write(line, "\n")
    f:close()
    return true
end

local function policy_signature()
    local g = settings.governance
    return table.concat({
        tostring(g.level),
        tostring(g.review_capacity_per_hour),
        tostring(g.queue_warn_ratio),
        tostring(g.review_ttl_hours),
        tostring(g.require_change_ticket),
    }, "|")
end

local function load_change_ticket()
    local ticket = read_json_file(settings.governance.ticket_file)
    if type(ticket) ~= "table" then
        return { ok = false, reason = "ticket_missing" }
    end
    if ticket.approved ~= true then
        return { ok = false, reason = "ticket_not_approved" }
    end
    if trim(ticket.policy_signature or "") ~= policy_signature() then
        return { ok = false, reason = "ticket_signature_mismatch" }
    end
    local expires_at = tonumber(ticket.expires_at or 0) or 0
    if expires_at > 0 and os.time() > expires_at then
        return { ok = false, reason = "ticket_expired" }
    end
    return { ok = true, reason = "ticket_ok", ticket = ticket }
end

local function load_freeze_state()
    local state = read_json_file(settings.governance.freeze_flag_file)
    if type(state) ~= "table" then
        return { active = false, reason = "", owner = "" }
    end
    return {
        active = state.active == true,
        reason = tostring(state.reason or ""),
        owner = tostring(state.owner or ""),
        ts = tostring(state.ts or ""),
    }
end

local function collect_queue_stats()
    local now = os.time()
    local ttl_sec = math.max(3600, settings.governance.review_ttl_hours * 3600)
    local rows = read_jsonl(settings.governance.queue_file)
    local changed = false
    local pending = 0
    local expired = 0
    local reviewed = 0

    for _, row in ipairs(rows) do
        local status = tostring(row.status or "PENDING")
        local created_at = tonumber(row.created_at or 0) or 0
        local expires_at = tonumber(row.expires_at or 0) or 0
        if created_at <= 0 then
            created_at = now
            row.created_at = created_at
            changed = true
        end
        if expires_at <= 0 then
            expires_at = created_at + ttl_sec
            row.expires_at = expires_at
            changed = true
        end

        if status == "PENDING" and now > expires_at then
            row.status = "EXPIRED"
            row.expired_at = now
            status = "EXPIRED"
            changed = true
        end

        if status == "PENDING" then
            pending = pending + 1
        elseif status == "EXPIRED" then
            expired = expired + 1
        elseif status == "REVIEWED" then
            reviewed = reviewed + 1
        end
    end

    if changed then
        write_jsonl(settings.governance.queue_file, rows)
    end

    return {
        pending = pending,
        expired = expired,
        reviewed = reviewed,
        total = #rows,
    }
end

local function ingress_last_hour()
    local now = os.time()
    local rows = read_jsonl(settings.governance.events_file)
    local count = 0
    for _, row in ipairs(rows) do
        if tostring(row.event or "") == "ingress" then
            local ts = tonumber(row.ts_epoch or 0) or 0
            if ts > 0 and now - ts <= 3600 then
                count = count + 1
            end
        end
    end
    return count
end

local function log_event(name, payload)
    append_jsonl(settings.governance.events_file, {
        ts = os.date("%Y-%m-%d %H:%M:%S"),
        ts_epoch = os.time(),
        event = name,
        payload = payload or {},
    })
end

local function level_at_most(target, cap)
    local t = LEVEL_ORDER[target] or LEVEL_ORDER.L1
    local c = LEVEL_ORDER[cap] or LEVEL_ORDER.L1
    if t > c then
        return cap
    end
    return target
end

local function determine_effective_level()
    local g = settings.governance
    local desired = tostring(g.level or "L1")
    if not LEVEL_ORDER[desired] then
        desired = "L1"
    end

    local reasons = {}
    local effective = desired
    local queue_stats = collect_queue_stats()
    local ingress = ingress_last_hour()
    local freeze = load_freeze_state()

    if freeze.active then
        effective = level_at_most(effective, "L1")
        table.insert(reasons, "freeze_active")
    end

    local warn_limit = math.max(1, math.floor(g.review_capacity_per_hour * g.queue_warn_ratio + 0.5))
    if ingress > warn_limit or queue_stats.pending >= g.review_capacity_per_hour then
        effective = level_at_most(effective, "L1")
        table.insert(reasons, "queue_pressure")
    end

    local ticket_state = { ok = true, reason = "ticket_not_required" }
    if g.require_change_ticket and (effective == "L2" or effective == "L3" or desired == "L2" or desired == "L3") then
        ticket_state = load_change_ticket()
        if not ticket_state.ok then
            effective = level_at_most(effective, "L1")
            table.insert(reasons, ticket_state.reason)
        end
    end

    return effective, {
        desired = desired,
        queue = queue_stats,
        ingress_last_hour = ingress,
        warn_limit = warn_limit,
        freeze = freeze,
        ticket = ticket_state,
        reasons = reasons,
        policy_signature = policy_signature(),
    }
end

local function front_context()
    local app = hs.application.frontmostApplication()
    local win = hs.window.frontmostWindow()
    local app_name = app and app:name() or ""
    local title = win and win:title() or ""
    local lower = (app_name .. " " .. title):lower()
    local in_teams = lower:match("teams") ~= nil
    return {
        app = app_name,
        title = title,
        in_teams = in_teams,
    }
end

local function load_name_hints(limit)
    local names = {}
    local seen = {}
    local glossary = deps.glossary_file
    if not glossary then
        return names
    end
    local f = io.open(glossary, "r")
    if not f then
        return names
    end
    for line in f:lines() do
        local s = trim(line)
        if s ~= "" and not s:match("^#") then
            local right = s:match("=(.+)$")
            if right then
                right = trim(right)
                if right:match("^[\228-\233][\128-\191]+[\228-\233][\128-\191]+") and not seen[right] then
                    table.insert(names, right)
                    seen[right] = true
                    if #names >= (limit or 30) then
                        break
                    end
                end
            end
        end
    end
    f:close()
    return names
end

local function extract_action_items(markdown)
    local actions = {}
    local in_actions = false
    for line in tostring(markdown or ""):gmatch("[^\r\n]+") do
        if line:match("^##%s*行动") then
            in_actions = true
        elseif in_actions and line:match("^##%s+") then
            break
        elseif in_actions then
            local item = trim(line:match("^%s*%d+[%.、)%]]%s*(.+)$") or line:match("^%s*[-*]%s*(.+)$") or "")
            if item ~= "" then
                table.insert(actions, item)
            end
        end
    end
    return actions
end

local function validate_actions(actions)
    local valid = {}
    local seen = {}
    local invalid = 0
    for _, raw in ipairs(actions or {}) do
        local item = trim(raw)
        local key = item:lower()
        if item == "" or #item < 6 then
            invalid = invalid + 1
        elseif item:match("待确认") or item:match("TBD") or item:match("unknown") then
            invalid = invalid + 1
        elseif not seen[key] then
            table.insert(valid, item)
            seen[key] = true
        end
    end
    return valid, invalid
end

local function read_latest_f5_entry(days)
    local window_days = math.max(1, math.floor(tonumber(days or 3) or 3))
    local best = nil
    for i = 0, window_days - 1 do
        local date = os.date("%Y-%m-%d", os.time() - i * 86400)
        local path = deps.transcript_dir .. "/" .. date .. ".jsonl"
        local f = io.open(path, "r")
        if f then
            for line in f:lines() do
                local ok, row = pcall(hs.json.decode, line)
                if ok and type(row) == "table" and tostring(row.action or "") == "F5" then
                    local ts = tostring(row.ts or "")
                    if ts ~= "" and (not best or ts > tostring(best.ts or "")) then
                        best = row
                    end
                end
            end
            f:close()
        end
    end
    return best
end

local function persist_minutes(payload, meeting_md)
    local stamp = os.date("%Y%m%d-%H%M%S")
    local day = os.date("%Y-%m-%d")
    local meeting_id = "meeting-" .. stamp
    local base = settings.output_dir .. "/" .. day
    local md_path = base .. "/" .. meeting_id .. ".md"
    local json_path = base .. "/" .. meeting_id .. ".json"

    local ok_md = write_text(md_path, meeting_md)
    local payload_json = hs.json.encode(payload or {}) or "{}"
    local ok_json = write_text(json_path, payload_json)

    return {
        ok = ok_md and ok_json,
        meeting_id = meeting_id,
        md_path = md_path,
        json_path = json_path,
    }
end

local function queue_review(meeting_id, md_path, reason)
    local now = os.time()
    append_jsonl(settings.governance.queue_file, {
        id = meeting_id,
        created_at = now,
        expires_at = now + settings.governance.review_ttl_hours * 3600,
        status = "PENDING",
        reason = tostring(reason or "manual_review_required"),
        md_path = md_path,
    })
end

local function run_reports()
    local cmd = string.format(
        "python3 %s --meetings-dir %s --actions-csv %s --out-dir %s --period both",
        sh_escape(deps.script_dir .. "/scripts/meeting_reports.py"),
        sh_escape(settings.output_dir),
        sh_escape(settings.actions_csv),
        sh_escape(settings.reports_dir)
    )
    local task = hs.task.new("/bin/bash", function(exitCode, stdout, stderr)
        deps.logf("[whisper] meeting_reports status=%s", exitCode == 0 and "ok" or "failed")
        if exitCode ~= 0 then
            deps.logf("[whisper] meeting_reports error=%s", trim(stderr or stdout))
        end
    end, { "-lc", cmd })
    if task then
        task:start()
    end
end

local function do_minutes(text, meta, trigger_name)
    local context = front_context()
    local names = load_name_hints(40)
    local names_hint = table.concat(names, "、")
    local source_text = trim(text or "")
    if source_text == "" then
        deps.show_status("⚠️ 无可用文本生成纪要", 1.2)
        return
    end

    log_event("ingress", {
        trigger = trigger_name or "manual",
        capture_ms = tonumber(meta and meta.capture_ms or 0) or 0,
    })

    local effective_level, gstate = determine_effective_level()
    local speaker_mode = settings.speaker_mode
    local model_cfg = settings.model_relay

    deps.logf(
        "[whisper] meeting_stage=start trigger=%s level=%s desired=%s ingress=%d pending=%d reasons=%s",
        tostring(trigger_name or "manual"),
        tostring(effective_level),
        tostring(gstate.desired),
        tonumber(gstate.ingress_last_hour or 0) or 0,
        tonumber(gstate.queue and gstate.queue.pending or 0) or 0,
        table.concat(gstate.reasons or {}, ",")
    )

    if effective_level == "L0" then
        local raw_md = table.concat({
            "# 会议原文（L0）",
            "",
            "- 生成时间: " .. os.date("%Y-%m-%d %H:%M:%S"),
            "- trigger: " .. tostring(trigger_name or "manual"),
            "- governance: L0",
            "",
            source_text,
            "",
        }, "\n")
        local saved = persist_minutes({
            ts = os.date("%Y-%m-%d %H:%M:%S"),
            trigger = trigger_name,
            level = "L0",
            governance = gstate,
            transcript = source_text,
        }, raw_md)
        if saved.ok then
            queue_review(saved.meeting_id, saved.md_path, "l0_raw_output")
            deps.show_status("📝 已生成 L0 草稿（待复核）", 1.5)
        else
            deps.show_status("❌ L0 落盘失败", 1.5)
        end
        return
    end

    local summary_prompt = [[你是会议纪要助手。请根据输入内容输出高质量中文会议纪要。
必须输出以下结构：
## 会议概览
## 关键讨论
## 决策结论
## 风险与阻塞
## 行动项（请编号 1.2.3，尽量包含负责人/截止时间；未知写待确认）
## 发言人线索（注明 speaker_mode 与可信度；若无法确定请明确写“未可靠识别”）
要求：内容真实、可执行、简洁，不编造。]]

    local source = "【转录文本】\n" .. source_text
        .. "\n\n【Teams上下文】\n应用=" .. tostring(context.app or "")
        .. " 标题=" .. tostring(context.title or "")
        .. " in_teams=" .. tostring(context.in_teams)
        .. "\n\n【人名/术语线索】\n" .. (names_hint ~= "" and names_hint or "无")
        .. "\n\n【speaker_mode】" .. speaker_mode

    deps.show_status("🧾 会议纪要生成中...", 1.0)

    deps.llm.request({
        text = source,
        user_prompt = source,
        system_prompt = summary_prompt,
        model_type = model_cfg.summary_model_type,
        model = model_cfg.summary_model,
        task_label = "Meeting Minutes",
        enable_retry = true,
    }, function(summary_result, summary_error)
        if summary_error then
            deps.logf("[whisper] meeting_stage=summary status=failed error=%s", tostring(summary_error))
            deps.show_status("❌ 纪要生成失败: " .. tostring(summary_error), 1.5)
            return
        end
        deps.logf("[whisper] meeting_stage=summary status=ok")
        local minutes_md = trim(summary_result or "")
        if minutes_md == "" then
            deps.show_status("❌ 纪要为空", 1.2)
            return
        end

        local analysis_prompt = [[你是项目行动分析助手。基于会议纪要，补充一段“执行建议”，格式：
## 执行建议
1. ...
2. ...
3. ...
要求：只给可执行项，不重复纪要原文。]]

        deps.llm.request({
            text = minutes_md,
            user_prompt = minutes_md,
            system_prompt = analysis_prompt,
            model_type = model_cfg.analysis_model_type,
            model = model_cfg.analysis_model,
            task_label = "Meeting Analysis",
            enable_retry = true,
        }, function(analysis_result, analysis_error)
            local analysis_md = trim(analysis_result or "")
            if analysis_error then
                deps.logf("[whisper] meeting_stage=analysis status=failed error=%s", tostring(analysis_error))
                analysis_md = "## 执行建议\n1. 待分析（模型失败：" .. tostring(analysis_error) .. "）"
            else
                deps.logf("[whisper] meeting_stage=analysis status=ok")
            end

            local actions = extract_action_items(minutes_md)
            local valid_actions, invalid_actions = validate_actions(actions)
            local rules_ok = invalid_actions == 0 and #valid_actions > 0

            local final_level = effective_level
            local level_reasons = {}
            for _, r in ipairs(gstate.reasons or {}) do
                table.insert(level_reasons, r)
            end
            if (final_level == "L2" or final_level == "L3") and not rules_ok then
                final_level = "L1"
                table.insert(level_reasons, "action_rule_gate_failed")
            end

            local final_md = table.concat({
                "# 会议纪要",
                "",
                "- 生成时间: " .. os.date("%Y-%m-%d %H:%M:%S"),
                "- 触发方式: " .. tostring(trigger_name or "manual"),
                "- 时长(秒): " .. tostring(math.floor((tonumber(meta and meta.capture_ms or 0) or 0) / 1000)),
                "- speaker_mode: " .. speaker_mode,
                "- Teams上下文: " .. tostring(context.app or "") .. " | " .. tostring(context.title or ""),
                "- governance_level: " .. tostring(final_level),
                "- governance_reasons: " .. table.concat(level_reasons, ","),
                "",
                minutes_md,
                "",
                analysis_md,
                "",
            }, "\n")

            local saved = persist_minutes({
                ts = os.date("%Y-%m-%d %H:%M:%S"),
                trigger = trigger_name or "manual",
                capture_ms = tonumber(meta and meta.capture_ms or 0) or 0,
                speaker_mode = speaker_mode,
                teams = context,
                level = final_level,
                governance = gstate,
                governance_reasons = level_reasons,
                policy_signature = policy_signature(),
                summary_model = model_cfg.summary_model ~= "" and model_cfg.summary_model or model_cfg.summary_model_type,
                analysis_model = model_cfg.analysis_model ~= "" and model_cfg.analysis_model or model_cfg.analysis_model_type,
                transcript = source_text,
                minutes = minutes_md,
                analysis = analysis_md,
                action_candidates = valid_actions,
                invalid_action_count = invalid_actions,
            }, final_md)

            if not saved.ok then
                deps.show_status("❌ 纪要落盘失败", 1.5)
                return
            end

            local action = "MEETING_MINUTES_DRAFT"
            if final_level == "L3" then
                action = "MEETING_MINUTES"
                for _, item in ipairs(valid_actions) do
                    append_csv_row(settings.actions_csv, {
                        ts = os.date("%Y-%m-%d %H:%M:%S"),
                        meeting_id = saved.meeting_id,
                        source = "minutes",
                        owner = "",
                        due = "",
                        status = "TODO",
                        task = item,
                    })
                end
                if settings.auto_reports then
                    run_reports()
                end
            else
                queue_review(saved.meeting_id, saved.md_path, table.concat(level_reasons, ","))
            end

            local entry = {
                action = action,
                app = "Hammerspoon",
                prompt_key = "meeting_minutes",
                input = source_text,
                output = final_md,
            }
            deps.append_transcript(entry)
            if final_level == "L3" then
                deps.send_to_flomo(entry)
            end
            if settings.copy_to_clipboard then
                hs.pasteboard.setContents(final_md)
            end

            deps.logf("[whisper] meeting_stage=done id=%s level=%s actions=%d invalid_actions=%d", saved.meeting_id, final_level, #valid_actions, invalid_actions)
            if final_level == "L3" then
                deps.show_status("✅ 会议纪要已归档: " .. saved.md_path, 1.6)
            else
                deps.show_status("📝 会议纪要草稿（待复核）: " .. saved.md_path, 1.6)
            end
        end)
    end)
end

function M.on_f5_completed(payload)
    if not settings.enabled then
        return
    end
    if not settings.auto_minutes then
        return
    end
    local capture_ms = tonumber(payload and payload.capture_ms or 0) or 0
    if capture_ms < settings.long_record_threshold_sec * 1000 then
        return
    end
    do_minutes(payload.output or payload.text or "", payload, "auto_long_f5")
end

function M.run_minutes_from_latest()
    if deps.ensure_idle and not deps.ensure_idle("Meeting Minutes") then
        return
    end
    local row = read_latest_f5_entry(3)
    if not row or trim(row.output or "") == "" then
        deps.show_status("⚠️ 未找到最近 F5 文本", 1.2)
        return
    end
    do_minutes(row.output or "", { capture_ms = 0 }, "manual_latest_f5")
end

function M.run_reports_only()
    if deps.ensure_idle and not deps.ensure_idle("Meeting Reports") then
        return
    end
    run_reports()
    deps.show_status("📊 周报/月报生成中...", 1.2)
end

function M.run_full_pipeline()
    if deps.ensure_idle and not deps.ensure_idle("Meeting Full") then
        return
    end
    local row = read_latest_f5_entry(3)
    if not row or trim(row.output or "") == "" then
        deps.show_status("⚠️ 未找到最近 F5 文本", 1.2)
        return
    end
    do_minutes(row.output or "", { capture_ms = 0 }, "manual_full_pipeline")
end

function M.setup(opts)
    deps = opts or {}
    local cfg = deps.config or {}
    local meeting_cfg = cfg.meeting or {}
    local gov_cfg = meeting_cfg.governance or {}

    settings = {
        enabled = cfg_value(meeting_cfg.enabled, true),
        auto_minutes = cfg_value(meeting_cfg.auto_minutes, true),
        auto_reports = cfg_value(meeting_cfg.auto_reports, true),
        copy_to_clipboard = cfg_value(meeting_cfg.copy_to_clipboard, true),
        long_record_threshold_sec = math.max(60, math.floor(cfg_value(meeting_cfg.long_record_threshold_sec, 600))),
        speaker_mode = tostring(cfg_value(meeting_cfg.speaker_mode, "teams_context+text_heuristic")),
        output_dir = tostring(cfg_value(meeting_cfg.output_dir, deps.script_dir .. "/knowledge/meetings")),
        actions_csv = tostring(cfg_value(meeting_cfg.actions_csv, deps.script_dir .. "/knowledge/actions/action_items.csv")),
        reports_dir = tostring(cfg_value(meeting_cfg.reports_dir, deps.script_dir .. "/knowledge/reports")),
        hotkeys = meeting_cfg.hotkeys or {},
        model_relay = {
            summary_model_type = cfg_value(meeting_cfg.model_relay and meeting_cfg.model_relay.summary_model_type, "fast"),
            summary_model = tostring(cfg_value(meeting_cfg.model_relay and meeting_cfg.model_relay.summary_model, "")),
            analysis_model_type = cfg_value(meeting_cfg.model_relay and meeting_cfg.model_relay.analysis_model_type, "strong"),
            analysis_model = tostring(cfg_value(meeting_cfg.model_relay and meeting_cfg.model_relay.analysis_model, "")),
        },
        governance = {
            level = tostring(cfg_value(gov_cfg.level, "L1")),
            review_capacity_per_hour = math.max(1, math.floor(cfg_value(gov_cfg.review_capacity_per_hour, 12))),
            queue_warn_ratio = tonumber(cfg_value(gov_cfg.queue_warn_ratio, 0.7)) or 0.7,
            review_ttl_hours = math.max(1, math.floor(cfg_value(gov_cfg.review_ttl_hours, 24))),
            queue_file = tostring(cfg_value(gov_cfg.queue_file, deps.script_dir .. "/knowledge/meetings/review_queue.jsonl")),
            events_file = tostring(cfg_value(gov_cfg.events_file, deps.script_dir .. "/knowledge/meetings/governance_events.jsonl")),
            freeze_flag_file = tostring(cfg_value(gov_cfg.freeze_flag_file, deps.script_dir .. "/knowledge/meetings/governance_freeze.json")),
            require_change_ticket = cfg_value(gov_cfg.require_change_ticket, true),
            ticket_file = tostring(cfg_value(gov_cfg.ticket_file, deps.script_dir .. "/knowledge/meetings/threshold_change_ticket.json")),
        },
    }

    ensure_dir(settings.output_dir)
    ensure_dir(settings.reports_dir)
    ensure_dir(settings.actions_csv:match("(.+)/[^/]+$") or "")
    ensure_dir(settings.governance.queue_file:match("(.+)/[^/]+$") or "")

    if not settings.enabled then
        return
    end

    local hk = settings.hotkeys
    local minutes_mods = hk.minutes_mods or { "alt" }
    local reports_mods = hk.reports_mods or { "alt" }
    local full_mods = hk.full_mods or { "ctrl", "alt" }
    local minutes_key = tostring(cfg_value(hk.minutes_key, "m"))
    local reports_key = tostring(cfg_value(hk.reports_key, "n"))
    local full_key = tostring(cfg_value(hk.full_key, "m"))

    hs.hotkey.bind(minutes_mods, minutes_key, function()
        M.run_minutes_from_latest()
    end)
    hs.hotkey.bind(reports_mods, reports_key, function()
        M.run_reports_only()
    end)
    hs.hotkey.bind(full_mods, full_key, function()
        M.run_full_pipeline()
    end)
end

return M
