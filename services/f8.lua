-- F8 一键助手模式（项目级总结 + 分析 + 统计）
local cfg_value = require("lib.utils").cfg_value
local sh_escape = require("lib.utils").sh_escape
local trim = require("lib.utils").trim
local ensure_dir = require("lib.utils").ensure_dir

local function safe_llm_request(llm, opts, callback)
    local ok, err = pcall(llm.request, opts, callback)
    if not ok then callback(nil, "llm_throw: " .. tostring(err)) end
end

local M = {}
local deps = nil
local settings = nil

function M.setup(opts)
    deps = opts or {}
    local cfg = deps.config or {}

    settings = {
        mode = cfg_value(cfg.features and cfg.features.f8_mode, "workflow"),
        digest_days = math.max(1, math.floor(cfg_value(cfg.limits and cfg.limits.f8_digest_days, 1))),
        digest_max_items = math.max(20, math.floor(cfg_value(cfg.limits and cfg.limits.f8_digest_max_items, 120))),
        digest_max_source_chars = math.max(1000, math.floor(cfg_value(cfg.limits and cfg.limits.f8_digest_max_source_chars, 12000))),
        summary_model_type = cfg_value(cfg.features and cfg.features.f8_summary_model_type, "fast"),
        analysis_model_type = cfg_value(cfg.features and cfg.features.f8_analysis_model_type, "strong"),
        output_dir = cfg_value(cfg.paths and cfg.paths.f8_output_dir, deps.script_dir .. "/knowledge/f8"),
        backup_dir = cfg_value(cfg.paths and cfg.paths.f8_backup_dir, deps.script_dir .. "/knowledge/f8/backup"),
        icloud_dir = cfg_value(cfg.paths and cfg.paths.f8_icloud_dir, os.getenv("HOME") .. "/Library/Mobile Documents/com~apple~CloudDocs/Hammerspoon/F8"),
        sync_to_icloud = cfg_value(cfg.features and cfg.features.f8_sync_to_icloud, true),
        copy_to_clipboard = cfg_value(cfg.features and cfg.features.f8_copy_to_clipboard, true),
        enable_f8 = cfg_value(cfg.features and cfg.features.enable_f8_commands, true),
        command_status_done_sec = deps.command_status_done_sec or 1.2,
        default_processing_timeout_sec = deps.default_processing_timeout_sec or 120,
        processing_timeout_sec = deps.processing_timeout_sec or 120,
    }
end

local function ensure_f8_enabled()
    if not settings.enable_f8 then
        hs.alert.show("⚙️ F8 命令已禁用", 2)
        hs.printf("[whisper] F8 blocked: disabled")
        return false
    end
    return true
end

local function parse_json_line(line)
    if not line or line == "" then
        return nil
    end
    local ok, row = pcall(hs.json.decode, line)
    if not ok or type(row) ~= "table" then
        return nil
    end
    return row
end

local function collect_digest_entries(days)
    local window_days = math.max(1, math.floor(tonumber(days or settings.digest_days) or settings.digest_days))
    local entries = {}
    for i = window_days - 1, 0, -1 do
        local date = os.date("%Y-%m-%d", os.time() - i * 86400)
        local path = deps.transcript_dir .. "/" .. date .. ".jsonl"
        local f = io.open(path, "r")
        if f then
            for line in f:lines() do
                local row = parse_json_line(line)
                if row then
                    local action = tostring(row.action or "")
                    local output = tostring(row.output or "")
                    if action ~= "F8_DIGEST" and action ~= "F8_WORKFLOW" and output ~= "" then
                        table.insert(entries, {
                            ts = tostring(row.ts or ""),
                            action = action,
                            app = tostring(row.app or ""),
                            output = output,
                        })
                        if #entries > settings.digest_max_items then
                            table.remove(entries, 1)
                        end
                    end
                end
            end
            f:close()
        end
    end
    return entries
end

local function build_digest_source(entries)
    if not entries or #entries == 0 then
        return "", 0
    end
    local lines = {}
    local total_chars = 0
    for _, row in ipairs(entries) do
        local text = tostring(row.output or "")
        text = text:gsub("[%c]+", " "):gsub("%s+", " ")
        local line = string.format("[%s][%s][%s] %s", row.ts ~= "" and row.ts or "-", row.action ~= "" and row.action or "-", row.app ~= "" and row.app or "-", text)
        local projected = total_chars + #line + 1
        if projected > settings.digest_max_source_chars then
            break
        end
        table.insert(lines, line)
        total_chars = projected
    end
    return table.concat(lines, "\n"), #lines
end

local function run_f8_digest()
    if not ensure_f8_enabled() then
        return
    end
    if not deps.ensure_idle("F8_Digest") then
        return
    end
    local entries = collect_digest_entries()
    local source, used = build_digest_source(entries)
    if used == 0 or source == "" then
        deps.show_command_status("ℹ️ 无可汇总记录（最近 " .. tostring(settings.digest_days) .. " 天）", settings.command_status_done_sec)
        return
    end

    deps.show_hud("processing", { duration_sec = settings.processing_timeout_sec })
    deps.show_command_status("🧠 汇总中...\n范围：" .. tostring(used) .. " 条记录")
    deps.set_processing(true)
    deps.set_processing_start_time(os.time())

    local digest_prompt = [[你是工作记录总结助手。
任务：根据输入的多条工作文本记录，输出一份简洁中文总结。
要求：
1. 只输出最终总结正文，不要标题和解释。
2. 先给 1 段总体进展，再给 3-5 条要点（每条单行，以"1. 2. 3."编号）。
3. 保留关键动作、关键对象、关键风险；不要编造事实。
4. 总长度控制在 220-400 字。]]
    safe_llm_request(deps.llm, {
        text = source,
        user_prompt = source,
        system_prompt = digest_prompt,
        model_type = "fast",
        task_label = "F8 Digest",
        enable_retry = true,
    }, function(result, error)
        deps.set_processing(false)
        deps.set_processing_start_time(nil)
        deps.hide_hud()

        if error then
            deps.show_command_status("❌ 汇总失败: " .. tostring(error), settings.command_status_done_sec)
            return
        end

        local summary = trim(result or "")
        if summary == "" then
            deps.show_command_status("❌ 汇总为空，请重试", settings.command_status_done_sec)
            return
        end

        local entry = {
            action = "F8_DIGEST",
            app = "Hammerspoon",
            prompt_key = "f8_digest_summary",
            input = source,
            output = summary,
        }
        deps.append_transcript(entry)
        deps.send_to_flomo(entry)
        local status_text = "✅ 已汇总并发送"
        if settings.copy_to_clipboard then
            hs.pasteboard.setContents(summary)
            status_text = status_text .. "（已复制到剪贴板）"
        end

        deps.show_command_status(status_text, settings.command_status_done_sec)
    end)
end

local function write_text_file(path, content)
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

local function top_action_snapshot(entries, max_items)
    local counts = {}
    local out = {}
    local n = max_items or 5
    for _, row in ipairs(entries or {}) do
        local action = tostring(row.action or "")
        if action ~= "" then
            counts[action] = (counts[action] or 0) + 1
        end
    end
    for action, count in pairs(counts) do
        table.insert(out, { action = action, count = count })
    end
    table.sort(out, function(a, b)
        if a.count == b.count then
            return a.action < b.action
        end
        return a.count > b.count
    end)
    local lines = {}
    for i = 1, math.min(n, #out) do
        table.insert(lines, string.format("- %s: %d", out[i].action, out[i].count))
    end
    if #lines == 0 then
        table.insert(lines, "- 无")
    end
    return table.concat(lines, "\n")
end

local function build_f8_report(payload)
    payload = payload or {}
    local now = os.date("%Y-%m-%d %H:%M:%S")
    local app_name, bundle_id = deps.get_front_app_info()
    local entries = payload.entries or {}
    local used = tonumber(payload.context_used or 0) or 0
    local context_days = tonumber(payload.context_days or settings.digest_days) or settings.digest_days
    local summary_text = trim(payload.summary or "")
    local analysis_text = trim(payload.analysis or "")
    local source_excerpt = deps.soft_truncate(trim(payload.recent_source or ""), 2400)
    local reliability = payload.reliability or {}
    local scores = reliability.scores or {}
    local log_stats = reliability.log_stats or {}
    local window = reliability.window or {}
    local script_status = payload.script_status or {}
    local f5_report_text = trim(payload.f5_report or "")
    local assets_report_text = trim(payload.assets_report or "")
    local terms_excerpt = deps.soft_truncate(trim(payload.terms_excerpt or ""), 1200)
    local profile_excerpt = deps.soft_truncate(trim(payload.profile_excerpt or ""), 1200)
    local memory_excerpt = deps.soft_truncate(trim(payload.memory_excerpt or ""), 1200)
    local runtime_usage = deps.runtime_usage or {}
    local total_events = tonumber(runtime_usage.total_events or 0) or 0
    local started_at = tonumber(runtime_usage.started_at or os.time()) or os.time()
    local uptime_min = math.max(0, math.floor((os.time() - started_at) / 60))

    local function score(v)
        local n = tonumber(v)
        if not n then
            return "N/A"
        end
        return string.format("%.2f", n)
    end

    local function status_text(key)
        local value = trim(script_status[key] or "")
        if value == "" then
            return "unknown"
        end
        return value
    end

    local lines = {
        "# F8 项目情报报告",
        "",
        string.format("- 生成时间: %s", now),
        string.format("- 前台应用: %s (%s)", tostring(app_name or "unknown"), tostring(bundle_id or "unknown")),
        string.format("- 最近 %d 天上下文条目: %d", context_days, tonumber(used or 0) or 0),
        string.format("- 运行总事件数: %d", total_events),
        string.format("- 运行时长: %d 分钟", uptime_min),
        "",
        "## 采集状态",
        string.format("- reliability_score.py: %s", status_text("reliability")),
        string.format("- f5_report.py: %s", status_text("f5_report")),
        string.format("- build_knowledge_assets.py: %s", status_text("assets")),
        "",
        "## 统计快照",
        string.format(
            "- Reliability 分数: overall=%s completeness=%s stability=%s quality=%s",
            score(scores.overall),
            score(scores.completeness),
            score(scores.stability),
            score(scores.quality)
        ),
        string.format(
            "- Reliability 覆盖: covered=%s/%s ratio=%s",
            tostring(scores.covered_actions or "N/A"),
            tostring(scores.required_actions or "N/A"),
            score(tonumber(scores.coverage_ratio or 0) * 100) .. "%%"
        ),
        string.format(
            "- Log 异常: utf8=%s normalize=%s clipboard=%s asr_failed=%s llm_failed=%s",
            tostring(log_stats.utf8_invalid or 0),
            tostring(log_stats.normalize_failed or 0),
            tostring(log_stats.clipboard_pollution or 0),
            tostring(log_stats.asr_failed or 0),
            tostring(log_stats.llm_failed or 0)
        ),
        string.format(
            "- Reliability 时间窗: %s -> %s (%s 天)",
            tostring(window.start or "N/A"),
            tostring(window["end"] or "N/A"),
            tostring(window.days or "N/A")
        ),
        "- 高频动作（最近上下文窗口）:",
        top_action_snapshot(entries, 6),
        "",
        "## 系统总结",
        summary_text ~= "" and summary_text or "（空）",
        "",
        "## 系统分析（PDCA）",
        analysis_text ~= "" and analysis_text or "（空）",
        "",
        "## F5 指标原始输出",
        f5_report_text ~= "" and f5_report_text or "（无）",
        "",
        "## 知识资产构建输出",
        assets_report_text ~= "" and assets_report_text or "（无）",
        "",
        "## 最近上下文摘要源",
        source_excerpt ~= "" and source_excerpt or "（无）",
        "",
        "## 术语热词（节选）",
        terms_excerpt ~= "" and terms_excerpt or "（无）",
        "",
        "## 用户画像（节选）",
        profile_excerpt ~= "" and profile_excerpt or "（无）",
        "",
        "## 关键记忆（节选）",
        memory_excerpt ~= "" and memory_excerpt or "（无）",
    }
    return table.concat(lines, "\n")
end

local function persist_f8_report(report_markdown, payload)
    local stamp = os.date("%Y%m%d-%H%M%S")
    local day = os.date("%Y-%m-%d")
    local base_name = "f8-" .. stamp
    local local_dir = settings.output_dir .. "/" .. day
    local backup_dir = settings.backup_dir .. "/" .. day
    local local_md = local_dir .. "/" .. base_name .. ".md"
    local local_json = local_dir .. "/" .. base_name .. ".json"
    local backup_md = backup_dir .. "/" .. base_name .. ".md"

    local payload_json = hs.json.encode(payload)
    if not payload_json or payload_json == "" then
        payload_json = hs.json.encode({
            ts = os.date("%Y-%m-%d %H:%M:%S"),
            encode_error = "payload_json_encode_failed",
            summary = tostring(payload and payload.summary or ""),
            analysis = tostring(payload and payload.analysis or ""),
        }) or "{}"
    end

    local ok_local_md = write_text_file(local_md, report_markdown)
    local ok_local_json = write_text_file(local_json, payload_json)
    local ok_backup_md = write_text_file(backup_md, report_markdown)

    local icloud_md = ""
    local icloud_json = ""
    local ok_icloud = false
    if settings.sync_to_icloud and settings.icloud_dir and settings.icloud_dir ~= "" then
        local cloud_dir = settings.icloud_dir .. "/" .. day
        icloud_md = cloud_dir .. "/" .. base_name .. ".md"
        icloud_json = cloud_dir .. "/" .. base_name .. ".json"
        local ok_cloud_md = write_text_file(icloud_md, report_markdown)
        local ok_cloud_json = write_text_file(icloud_json, payload_json)
        ok_icloud = ok_cloud_md and ok_cloud_json
    end

    return {
        ok = ok_local_md and ok_local_json and ok_backup_md,
        ok_icloud = ok_icloud,
        local_md = local_md,
        local_json = local_json,
        backup_md = backup_md,
        icloud_md = icloud_md,
        icloud_json = icloud_json,
    }
end

local function run_f8_workflow()
    if not ensure_f8_enabled() then
        return
    end
    if not deps.ensure_idle("F8") then
        return
    end

    deps.set_command_mode(true)
    deps.set_processing_timeout(math.max(settings.default_processing_timeout_sec, 240))
    deps.set_processing(true)
    deps.set_processing_start_time(os.time())
    deps.logf("[whisper] f8_stage=start mode=project_intel")

    deps.show_hud("processing", {
        duration_sec = settings.processing_timeout_sec,
        label = "F8采集中",
        progress = 12,
        overall_progress = 16,
        auto_progress = true,
        restart_clock = true,
    })
    deps.show_command_status("🧠 F8 正在执行项目级汇总与分析...")

    local lookback_days = math.max(7, settings.digest_days)
    local entries = collect_digest_entries(lookback_days)
    local recent_source, used = build_digest_source(entries)
    local scripts_dir = deps.script_dir .. "/scripts"
    local knowledge_dir = deps.script_dir .. "/knowledge"
    local script_status = {
        reliability = "not_run",
        f5_report = "not_run",
        assets = "not_run",
    }
    local reliability = {}
    local reliability_raw_text = "{}"
    local f5_report_text = ""
    local assets_report_text = ""
    local running_tasks = {}
    M._running_tasks = running_tasks

    local function done_success(summary, analysis, terms_excerpt, profile_excerpt, memory_excerpt)
        local report_payload = {
            ts = os.date("%Y-%m-%d %H:%M:%S"),
            summary = summary,
            analysis = analysis,
            entries = entries,
            context_days = lookback_days,
            context_used = used,
            recent_source = recent_source,
            reliability = reliability,
            f5_report = f5_report_text,
            assets_report = assets_report_text,
            script_status = script_status,
            terms_excerpt = terms_excerpt,
            profile_excerpt = profile_excerpt,
            memory_excerpt = memory_excerpt,
        }
        local report = build_f8_report(report_payload)
        local saved = persist_f8_report(report, report_payload)
        deps.logf(
            "[whisper] f8_stage=persist status_local=%s status_icloud=%s local_md=%s",
            tostring(saved.ok),
            tostring(saved.ok_icloud),
            tostring(saved.local_md or "")
        )
        local flomo_output = "【F8系统总结】\n" .. summary .. "\n\n【F8系统分析】\n" .. analysis
        local entry = {
            action = "F8_WORKFLOW",
            app = "Hammerspoon",
            prompt_key = "f8_project_intel",
            input = deps.soft_truncate(recent_source, 1200),
            output = flomo_output,
        }
        deps.append_transcript(entry)
        deps.send_to_flomo(entry)
        if settings.copy_to_clipboard then
            hs.pasteboard.setContents(flomo_output)
        end

        deps.set_processing(false)
        deps.set_processing_start_time(nil)
        deps.set_command_mode(false)
        deps.show_hud("success", {
            label = "F8已完成",
            progress = 100,
            overall_progress = 100,
            auto_progress = false,
        })
        deps.reset_processing_timeout()

        local hint = "✅ F8 已完成：本地归档"
        if saved.ok_icloud then
            hint = hint .. " + iCloud 同步"
        end
        deps.logf("[whisper] f8_stage=done context_used=%d", tonumber(used or 0) or 0)
        deps.show_command_status(hint .. "\n" .. tostring(saved.local_md or ""), settings.command_status_done_sec)
    end

    local function run_script(cmd, callback)
        local task
        task = hs.task.new("/bin/bash", function(exitCode, stdout, stderr)
            running_tasks[task] = nil
            callback(
                exitCode == 0,
                trim(stdout or ""),
                trim(stderr or "")
            )
        end, { "-lc", cmd })
        if not task then
            callback(false, "", "task_new_failed")
            return
        end
        running_tasks[task] = true
        local ok = task:start()
        if not ok then
            running_tasks[task] = nil
            callback(false, "", "task_start_failed")
        end
    end

    local function read_excerpt(path, max_chars)
        local f = io.open(path, "r")
        if not f then
            return ""
        end
        local content = f:read("*all") or ""
        f:close()
        return deps.soft_truncate(trim(content), max_chars or 1200)
    end

    local reliability_cmd = string.format(
        "python3 %s --days %d --json",
        sh_escape(scripts_dir .. "/reliability_score.py"),
        lookback_days
    )
    deps.logf("[whisper] f8_stage=collect context_entries=%d lookback_days=%d", #entries, lookback_days)
    local f5_cmd = string.format(
        "python3 %s --days %d",
        sh_escape(scripts_dir .. "/f5_report.py"),
        lookback_days
    )
    local assets_cmd = string.format(
        "python3 %s --days %d --transcripts-dir %s --glossary %s --config %s --out-dir %s",
        sh_escape(scripts_dir .. "/build_knowledge_assets.py"),
        math.max(lookback_days, 14),
        sh_escape(deps.transcript_dir),
        sh_escape(deps.glossary_file),
        sh_escape(deps.script_dir .. "/config.lua"),
        sh_escape(knowledge_dir)
    )

    deps.update_hud({
        kind = "processing",
        label = "F8统计中",
        progress = 24,
        overall_progress = 32,
        duration_sec = 50,
        restart_clock = true,
        auto_progress = true,
    })

    run_script(reliability_cmd, function(ok_rel, out_rel, err_rel)
        deps.logf("[whisper] f8_stage=reliability status=%s", ok_rel and "ok" or "failed")
        if ok_rel then
            reliability_raw_text = out_rel ~= "" and out_rel or "{}"
            local ok_json, parsed = pcall(hs.json.decode, out_rel)
            if ok_json and type(parsed) == "table" then
                reliability = parsed
                script_status.reliability = "ok"
            else
                script_status.reliability = "decode_failed"
            end
        else
            script_status.reliability = "failed: " .. (err_rel ~= "" and err_rel or out_rel)
            reliability = {}
            reliability_raw_text = "{}"
        end

        deps.update_hud({
            kind = "processing",
            label = "F8统计中",
            progress = 38,
            overall_progress = 48,
            duration_sec = 50,
            restart_clock = true,
            auto_progress = true,
        })

        run_script(f5_cmd, function(ok_f5, out_f5, err_f5)
            deps.logf("[whisper] f8_stage=f5_report status=%s", ok_f5 and "ok" or "failed")
            if ok_f5 then
                script_status.f5_report = "ok"
                f5_report_text = out_f5
            else
                script_status.f5_report = "failed: " .. (err_f5 ~= "" and err_f5 or out_f5)
                f5_report_text = out_f5 ~= "" and out_f5 or err_f5
            end

            deps.update_hud({
                kind = "processing",
                label = "F8构建中",
                progress = 52,
                overall_progress = 62,
                duration_sec = 55,
                restart_clock = true,
                auto_progress = true,
            })

            run_script(assets_cmd, function(ok_assets, out_assets, err_assets)
                deps.logf("[whisper] f8_stage=knowledge_assets status=%s", ok_assets and "ok" or "failed")
                if ok_assets then
                    script_status.assets = "ok"
                    assets_report_text = out_assets
                else
                    script_status.assets = "failed: " .. (err_assets ~= "" and err_assets or out_assets)
                    assets_report_text = out_assets ~= "" and out_assets or err_assets
                end

                local terms_excerpt = read_excerpt(knowledge_dir .. "/terms_hotlist.txt", 1200)
                local profile_excerpt = read_excerpt(knowledge_dir .. "/user_profile.md", 1200)
                local memory_excerpt = read_excerpt(knowledge_dir .. "/key_memory.md", 1200)

                local summary_prompt = [[你是项目情报总结助手。
任务：基于输入中的项目日志、统计结果、知识资产与上下文，输出一份"可执行"的中文总结。
要求：
1. 先写 1 段总体判断（2-4句）。
2. 输出 4-6 条关键发现，使用"1. 2. 3."编号，每条独占一行。
3. 输出 3-5 条优先行动项（同样编号），明确"做什么/为什么"。
4. 不编造事实，不输出 Markdown 标题。]]
                local summary_input = "【近期上下文摘要源】\n" .. deps.soft_truncate(recent_source, settings.digest_max_source_chars)
                    .. "\n\n【Reliability(JSON)】\n" .. deps.soft_truncate(reliability_raw_text, 3500)
                    .. "\n\n【F5报表输出】\n" .. deps.soft_truncate(f5_report_text, 3200)
                    .. "\n\n【知识资产构建输出】\n" .. deps.soft_truncate(assets_report_text, 2200)
                    .. "\n\n【术语热词节选】\n" .. terms_excerpt
                    .. "\n\n【用户画像节选】\n" .. profile_excerpt
                    .. "\n\n【关键记忆节选】\n" .. memory_excerpt

                deps.update_hud({
                    kind = "processing",
                    label = "F8总结中",
                    progress = 70,
                    overall_progress = 80,
                    duration_sec = 32,
                    restart_clock = true,
                    auto_progress = true,
                })

                safe_llm_request(deps.llm, {
                    text = summary_input,
                    user_prompt = summary_input,
                    system_prompt = summary_prompt,
                    model_type = settings.summary_model_type,
                    task_label = "F8 Summary",
                    enable_retry = true,
                }, function(summary_result, summary_error)
                    local summary = trim(summary_result or "")
                    if summary_error then
                        deps.logf("[whisper] f8_stage=summary status=failed error=%s", tostring(summary_error))
                        summary = "总结阶段失败：" .. tostring(summary_error)
                    else
                        deps.logf("[whisper] f8_stage=summary status=ok")
                    end
                    if summary == "" then
                        summary = "总结阶段无输出。"
                    end
                    local analysis_prompt = [[你是 PDCA 分析助手。
任务：基于项目统计与总结，输出可执行改进方案。
格式要求（必须遵守）：
P: 用 2-4 句描述目标与关键假设。
D: 用 2-4 句描述已执行动作与证据。
C: 用 2-4 句指出偏差、风险、瓶颈。
A: 给出 3-5 条下一步动作，使用"1. 2. 3."编号。
约束：语言简洁，不编造事实。]]
                    local runtime_usage = deps.runtime_usage or {}
                    local analysis_input = "【系统总结】\n" .. deps.soft_truncate(summary, 3600)
                        .. "\n\n【Reliability(JSON)】\n" .. deps.soft_truncate(reliability_raw_text, 2600)
                        .. "\n\n【F5报表】\n" .. deps.soft_truncate(f5_report_text, 2000)
                        .. "\n\n【脚本状态】\n"
                        .. string.format(
                            "reliability=%s\nf5_report=%s\nassets=%s\nruntime_total_events=%d\ncontext_used=%d",
                            script_status.reliability,
                            script_status.f5_report,
                            script_status.assets,
                            tonumber(runtime_usage.total_events or 0),
                            tonumber(used or 0)
                        )

                    deps.update_hud({
                        kind = "processing",
                        label = "F8分析中",
                        progress = 86,
                        overall_progress = 93,
                        duration_sec = 34,
                        restart_clock = true,
                        auto_progress = true,
                    })
                    safe_llm_request(deps.llm, {
                        text = analysis_input,
                        user_prompt = analysis_input,
                        system_prompt = analysis_prompt,
                        model_type = settings.analysis_model_type,
                        task_label = "F8 Analysis",
                        enable_retry = true,
                    }, function(analysis_result, analysis_error)
                        local analysis = trim(analysis_result or "")
                        if analysis_error then
                            deps.logf("[whisper] f8_stage=analysis status=failed error=%s", tostring(analysis_error))
                            analysis = "分析阶段失败：" .. tostring(analysis_error)
                        else
                            deps.logf("[whisper] f8_stage=analysis status=ok")
                        end
                        if analysis == "" then
                            analysis = "分析阶段无输出。"
                        end

                        done_success(summary, analysis, terms_excerpt, profile_excerpt, memory_excerpt)
                    end)
                end)
            end)
        end)
    end)
end

function M.run_digest()
    run_f8_digest()
end

function M.run_workflow()
    run_f8_workflow()
end

function M.get_mode()
    return settings and settings.mode or "workflow"
end

function M.cleanup()
    if M._running_tasks then
        for task in pairs(M._running_tasks) do
            pcall(function() task:terminate() end)
        end
        M._running_tasks = {}
    end
end

return M
