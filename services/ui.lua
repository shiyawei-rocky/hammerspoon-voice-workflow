local config = require("config")
local cfg_value = require("lib.utils").cfg_value

local M = {}
local UI_FONT = "PingFang SC"
local hud = nil
local stream_hud = nil
local command_hud = nil
local command_timer = nil
local status_menubar = nil
local status_reset_timer = nil
local status_error_hold_until = 0
local status_last_title = ""
local status_last_tooltip = ""
local status_last_update_sec = 0
local status_flow_hint = ""
local hud_kind = nil
local hud_state = {
    kind = nil,
    label = nil,
    started_ns = nil,
    duration_sec = nil,
    overall_range = nil,
    stage_progress = 0,
    overall_progress = 0,
    auto_progress = false,
    timer = nil,
}

local function get_hud_size()
    local size = cfg_value(config.ui and config.ui.hud_size, { w = 250, h = 64 })
    local w = tonumber(size.w) or 250
    local h = tonumber(size.h) or 64
    if w < 220 then w = 220 end
    if h < 60 then h = 60 end
    return { w = w, h = h }
end

local function get_stream_size()
    return cfg_value(config.ui and config.ui.stream_hud_size, { w = 400, h = 120 })
end

local function get_command_size()
    return cfg_value(config.ui and config.ui.command_hud_size, { w = 360, h = 90 })
end

local function get_status_done_sec()
    return cfg_value(config.timing and config.timing.status_done_sec, 1.2)
end

local function get_hud_progress_tick_sec()
    return cfg_value(config.timing and config.timing.hud_progress_tick_sec, 0.2)
end

local function get_status_primary()
    return tostring(cfg_value(config.ui and config.ui.status_primary, "overlay"))
end

local function get_command_hud_mode()
    return tostring(cfg_value(config.ui and config.ui.command_hud_mode, "all"))
end

local function get_menubar_min_refresh_sec()
    return tonumber(cfg_value(config.ui and config.ui.status_menubar_min_refresh_sec, 0.35)) or 0.35
end

local function hud_overlay_enabled()
    local raw = config.ui and config.ui.hud_overlay_enabled
    if raw ~= nil then
        return raw and true or false
    end
    return get_status_primary() ~= "menubar"
end

local function hud_follow_mouse()
    local raw = config.ui and config.ui.hud_follow_mouse
    if raw ~= nil then
        return raw and true or false
    end
    return false
end

local function command_is_error(text)
    local s = tostring(text or "")
    if s:find("❌", 1, true) or s:find("⚠️", 1, true) then
        return true
    end
    local lower = s:lower()
    return lower:find("error", 1, true) ~= nil
        or lower:find("failed", 1, true) ~= nil
        or s:find("失败", 1, true) ~= nil
end

local function status_kind_from_text(text)
    local s = tostring(text or "")
    local lower = s:lower()
    if s:find("🎤", 1, true) or s:find("录音", 1, true) or lower:find("record", 1, true) ~= nil then
        return "record"
    end
    if command_is_error(s) then
        return "error"
    end
    if s:find("⏳", 1, true) or s:find("进行中", 1, true) or s:find("处理中", 1, true) then
        return "progress"
    end
    if s:find("✅", 1, true) or s:find("已完成", 1, true) or lower:find("success", 1, true) ~= nil then
        return "success"
    end
    if s:find("⚠️", 1, true) or s:find("警告", 1, true) then
        return "warning"
    end
    return "info"
end

local function compact_text(text)
    local s = tostring(text or "")
    s = s:gsub("[%c]+", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

local function utf8_truncate(value, max_chars)
    local s = tostring(value or "")
    local limit = tonumber(max_chars) or 0
    if limit <= 0 then
        return ""
    end
    local ok, len = pcall(utf8.len, s)
    if not ok or type(len) ~= "number" then
        if #s <= limit then
            return s
        end
        return s:sub(1, limit)
    end
    if len <= limit then
        return s
    end
    local out = {}
    local count = 0
    for _, code in utf8.codes(s) do
        count = count + 1
        if count > limit then
            break
        end
        table.insert(out, utf8.char(code))
    end
    return table.concat(out)
end

local function detect_flow_code(text)
    local s = tostring(text or "")
    local code = s:match("([Ff]%d+)")
    if not code then
        return nil
    end
    return code:upper()
end

local function infer_flow_code(kind, node, text, flow_hint)
    local explicit = detect_flow_code(node) or detect_flow_code(text) or detect_flow_code(flow_hint)
    if explicit then
        return explicit
    end
    local n = tostring(node or "")
    if n:find("F8", 1, true) then
        return "F8"
    end
    if kind == "record" or kind == "asr" or kind == "processing" or kind == "success" then
        return "F5"
    end
    return "WS"
end

local function normalize_step(node, kind)
    local n = compact_text(node)
    if n == "" then
        if kind == "record" then
            return "录音"
        end
        if kind == "asr" then
            return "转录"
        end
        if kind == "success" then
            return "完成"
        end
        if kind == "error" then
            return "失败"
        end
        return "处理中"
    end
    n = n:gsub("^Whisper%s*[%-%·]*%s*", "")
    n = n:gsub("^F%d+%s*", "")
    if n:find("录音", 1, true) then return "录音" end
    if n:find("转录", 1, true) then return "转录" end
    if n:find("分段", 1, true) or n:find("进度", 1, true) then return "分段" end
    if n:find("汇总", 1, true) then return "汇总" end
    if n:find("统计", 1, true) then return "统计" end
    if n:find("构建", 1, true) then return "构建" end
    if n:find("总结", 1, true) then return "总结" end
    if n:find("分析", 1, true) then return "分析" end
    if n:find("处理", 1, true) then return "处理" end
    if n:find("完成", 1, true) then return "完成" end
    if n:find("失败", 1, true) then return "失败" end
    return utf8_truncate(n, 4)
end

local function menubar_title(kind, node, progress, text, flow_hint)
    local flow = infer_flow_code(kind, node, text, flow_hint)
    local step = normalize_step(node, kind)
    local pct = tonumber(progress)
    if pct ~= nil then
        if pct < 0 then
            pct = 0
        elseif pct > 100 then
            pct = 100
        end
        pct = math.floor(pct + 0.5)
    end
    if kind == "error" then
        return string.format("%s %s失败", flow, step ~= "" and step or "")
    end
    if kind == "warning" then
        if pct ~= nil then
            return string.format("%s %s %d%%", flow, step, pct)
        end
        return string.format("%s %s", flow, step)
    end
    if kind == "success" then
        return string.format("%s %s", flow, step ~= "" and step or "完成")
    end
    if kind == "progress" or kind == "asr" or kind == "record" or kind == "processing" then
        if pct ~= nil then
            return string.format("%s %s %d%%", flow, step, pct)
        end
        return string.format("%s %s", flow, step)
    end
    return string.format("%s %s", flow, step ~= "" and step or "就绪")
end

local function menubar_text_color(kind)
    if kind == "error" then
        return { red = 1.0, green = 0.35, blue = 0.34, alpha = 1.0 }
    end
    if kind == "warning" then
        return { red = 1.0, green = 0.62, blue = 0.0, alpha = 1.0 }
    end
    if kind == "success" then
        return { red = 0.20, green = 0.78, blue = 0.35, alpha = 1.0 }
    end
    if kind == "record" then
        return { red = 1.0, green = 0.27, blue = 0.23, alpha = 1.0 }
    end
    if kind == "progress" or kind == "asr" or kind == "processing" then
        return { red = 0.04, green = 0.52, blue = 1.0, alpha = 1.0 }
    end
    return nil
end

local function menubar_title_value(title_text, kind)
    local color = menubar_text_color(kind)
    if not color then
        return title_text
    end
    local ok, styled = pcall(function()
        return hs.styledtext.new(title_text, {
            color = color,
            font = { name = UI_FONT, size = 12 },
        })
    end)
    if ok and styled then
        return styled
    end
    return title_text
end

local function should_show_command_overlay(text)
    local mode = get_command_hud_mode()
    if mode == "off" then
        return false
    end
    if mode == "error_only" then
        return command_is_error(text)
    end
    return true
end

local function reset_status_menubar()
    if not status_menubar then
        return
    end
    status_menubar:setTitle("WS 就绪")
    status_menubar:setTooltip("Whisper 状态：就绪")
    status_last_title = "WS 就绪"
    status_last_tooltip = "Whisper 状态：就绪"
    status_last_update_sec = hs.timer.secondsSinceEpoch()
    status_flow_hint = ""
end

local function show_status_menubar(text, opts)
    opts = opts or {}
    if get_status_primary() ~= "menubar" then
        return
    end
    if not status_menubar then
        status_menubar = hs.menubar.new()
        if not status_menubar then
            return
        end
    end
    local display_text = compact_text(opts.text or text)
    local status_kind = opts.kind or status_kind_from_text(display_text)
    if opts.flow_code and tostring(opts.flow_code) ~= "" then
        status_flow_hint = tostring(opts.flow_code):upper()
    else
        local detected = detect_flow_code(display_text)
        if detected then
            status_flow_hint = detected
        end
    end
    local now_sec = hs.timer.secondsSinceEpoch()
    if opts.source == "hud" and now_sec < status_error_hold_until then
        return
    end
    if status_kind == "error" then
        status_error_hold_until = now_sec + 3
    end
    local resolved_progress = opts.progress
    if resolved_progress == nil then
        local p = display_text:match("(%d+)%%")
        if p then
            resolved_progress = tonumber(p)
        else
            local done, total = display_text:match("(%d+)%s*/%s*(%d+)")
            if done and total then
                local d = tonumber(done) or 0
                local t = tonumber(total) or 0
                if t > 0 then
                    resolved_progress = math.floor((d * 100) / t + 0.5)
                end
            end
        end
    end
    local title = opts.title or menubar_title(status_kind, opts.node or display_text, resolved_progress, display_text, status_flow_hint)
    local tooltip = tostring(opts.tooltip or display_text or "")
    if tooltip == "" then
        tooltip = "Whisper 状态：就绪"
    end
    local min_refresh = math.max(0, get_menubar_min_refresh_sec())
    if opts.source ~= "command" and status_kind ~= "error" and status_kind ~= "warning" then
        if title == status_last_title and tooltip == status_last_tooltip then
            return
        end
        if now_sec - status_last_update_sec < min_refresh then
            return
        end
    end
    status_menubar:setTitle(menubar_title_value(title, status_kind))
    status_menubar:setTooltip(tooltip)
    status_last_title = title
    status_last_tooltip = tooltip
    status_last_update_sec = now_sec
    if status_reset_timer then
        status_reset_timer:stop()
        status_reset_timer = nil
    end
    if status_kind ~= "error" and not opts.persistent then
        status_reset_timer = hs.timer.doAfter(3, reset_status_menubar)
    end
end

local function default_duration_sec(kind)
    local limits = config.limits or {}
    if kind == "record" then
        return tonumber(limits.record_max_duration) or 1800
    end
    if kind == "processing" then
        return tonumber(limits.processing_timeout_default) or 60
    end
    if kind == "asr" then
        return tonumber(limits.f5_asr_timeout_long_sec) or 25
    end
    return nil
end

local function stop_hud_timer()
    if hud_state.timer then
        hud_state.timer:stop()
        hud_state.timer = nil
    end
end

function M.hide_icon()
    stop_hud_timer()
    hud_state.kind = nil
    hud_state.label = nil
    hud_state.started_ns = nil
    hud_state.duration_sec = nil
    hud_state.overall_range = nil
    hud_state.stage_progress = 0
    hud_state.overall_progress = 0
    hud_state.auto_progress = false
    if hud then
        hud:delete()
        hud = nil
        hud_kind = nil
        collectgarbage("collect")
    end
    status_error_hold_until = 0
    reset_status_menubar()
end

local function clamp_progress(value)
    local v = tonumber(value) or 0
    if v < 0 then v = 0 end
    if v > 100 then v = 100 end
    return math.floor(v + 0.5)
end

local function default_label(kind)
    local labels = {
        record = "录音中",
        asr = "转录中",
        processing = "处理中",
        success = "已就绪",
    }
    return labels[kind] or "处理中"
end

local function auto_progress(kind, elapsed_sec, duration_sec)
    if kind == "record" then
        local total = math.max(1, tonumber(duration_sec) or 1800)
        return clamp_progress(math.min(99, elapsed_sec * 100 / total))
    end
    if kind == "processing" then
        local total = math.max(5, tonumber(duration_sec) or 60)
        return clamp_progress(math.min(95, elapsed_sec * 100 / total))
    end
    if kind == "asr" then
        local total = math.max(5, tonumber(duration_sec) or 25)
        local linear = math.min(92, elapsed_sec * 100 / total)
        local base = 8 + linear
        return clamp_progress(math.min(95, base))
    end
    return nil
end

local function default_overall_range(kind)
    local mapping = {
        record = { start = 0, finish = 18 },
        asr = { start = 18, finish = 58 },
        processing = { start = 58, finish = 95 },
        success = { start = 95, finish = 100 },
    }
    return mapping[kind] or mapping.processing
end

local function normalize_overall_range(kind, range)
    local base = default_overall_range(kind)
    if type(range) ~= "table" then
        return base
    end
    local s = tonumber(range.start)
    local f = tonumber(range.finish)
    if not s or not f then
        return base
    end
    if s < 0 then s = 0 end
    if f > 100 then f = 100 end
    if f < s then
        f = s
    end
    return { start = s, finish = f }
end

local function resolve_overall_progress(kind, stage_progress, explicit_overall, overall_range)
    if explicit_overall ~= nil then
        return clamp_progress(explicit_overall)
    end
    if kind == "success" then
        return 100
    end
    local range = normalize_overall_range(kind, overall_range)
    local ratio = clamp_progress(stage_progress) / 100
    local value = range.start + (range.finish - range.start) * ratio
    return clamp_progress(value)
end

local function ensure_hud_frame()
    local size = get_hud_size()
    if hud_follow_mouse() then
        local pos = hs.mouse.absolutePosition()
        return { x = pos.x + 18, y = pos.y + 22, w = size.w, h = size.h }, size
    end
    local screen = hs.screen.mainScreen():frame()
    local frame = {
        x = screen.x + screen.w - size.w - 18,
        y = screen.y + 38,
        w = size.w,
        h = size.h,
    }
    return frame, size
end

local function render_hud(kind, opts)
    opts = opts or {}
    local overlay_enabled = hud_overlay_enabled()
    local frame, size = ensure_hud_frame()
    local stage_track_h = 6
    local overall_track_h = 4
    local stage_y = size.h - 19
    local overall_y = size.h - 10
    local title_y = 7
    local subtitle_y = stage_y - 15
    local progress = clamp_progress(opts.progress or (kind == "success" and 100 or 0))
    local label = tostring(opts.label or default_label(kind))
    local range = normalize_overall_range(kind, opts.overall_range or hud_state.overall_range)
    local overall_progress = resolve_overall_progress(kind, progress, opts.overall_progress, range)
    hud_state.stage_progress = progress
    hud_state.overall_progress = overall_progress
    hud_kind = kind
    show_status_menubar(label, {
        node = label,
        kind = kind == "record" and "record" or (kind == "asr" and "asr" or (kind == "success" and "success" or "progress")),
        progress = progress,
        persistent = true,
        source = "hud",
        tooltip = string.format("节点: %s\n阶段进度: %d%%\n总进度: %d%%", label, progress, overall_progress),
    })

    if not overlay_enabled then
        if hud then
            hud:delete()
            hud = nil
        end
        if kind == "success" then
            hs.timer.doAfter(get_status_done_sec(), M.hide_icon)
        end
        return
    end

    if not hud then
        hud = hs.canvas.new(frame)
        hud:appendElements({
            type = "rectangle",
            action = "fill",
            frame = { x = 0, y = 0, w = size.w, h = size.h },
            fillColor = { red = 0.12, green = 0.13, blue = 0.16, alpha = 0.84 },
            roundedRectRadii = { xRadius = 12, yRadius = 12 },
            strokeColor = { alpha = 0 },
        }, {
            type = "rectangle",
            action = "stroke",
            frame = { x = 0.5, y = 0.5, w = size.w - 1, h = size.h - 1 },
            strokeColor = { white = 1, alpha = 0.18 },
            strokeWidth = 1,
            roundedRectRadii = { xRadius = 12, yRadius = 12 },
        }, {
            type = "circle",
            action = "fill",
            frame = { x = 14, y = 13, w = 10, h = 10 },
            fillColor = { red = 0.04, green = 0.52, blue = 1, alpha = 0.92 },
            strokeColor = { alpha = 0 },
        }, {
            type = "text",
            frame = { x = 32, y = title_y, w = size.w - 42, h = 18 },
            text = "",
            textFont = UI_FONT,
            textSize = 13,
            textColor = { white = 1, alpha = 0.98 },
        }, {
            type = "text",
            frame = { x = 32, y = subtitle_y, w = size.w - 42, h = 14 },
            text = "",
            textFont = UI_FONT,
            textSize = 11,
            textColor = { white = 1, alpha = 0.72 },
        }, {
            type = "rectangle",
            action = "fill",
            frame = { x = 12, y = stage_y, w = size.w - 24, h = stage_track_h },
            fillColor = { white = 1, alpha = 0.12 },
            roundedRectRadii = { xRadius = 3, yRadius = 3 },
            strokeColor = { alpha = 0 },
        }, {
            type = "rectangle",
            action = "fill",
            frame = { x = 12, y = stage_y, w = 0, h = stage_track_h },
            fillColor = { red = 0.2, green = 0.6, blue = 1, alpha = 0.95 },
            roundedRectRadii = { xRadius = 3, yRadius = 3 },
            strokeColor = { alpha = 0 },
        }, {
            type = "rectangle",
            action = "fill",
            frame = { x = 12, y = overall_y, w = size.w - 24, h = overall_track_h },
            fillColor = { white = 1, alpha = 0.08 },
            roundedRectRadii = { xRadius = 2, yRadius = 2 },
            strokeColor = { alpha = 0 },
        }, {
            type = "rectangle",
            action = "fill",
            frame = { x = 12, y = overall_y, w = 0, h = overall_track_h },
            fillColor = { red = 0.2, green = 0.6, blue = 1, alpha = 0.7 },
            roundedRectRadii = { xRadius = 2, yRadius = 2 },
            strokeColor = { alpha = 0 },
        })
        hud:show()
    else
        hud:frame(frame)
    end

    local colors = {
        record = { red = 1.00, green = 0.27, blue = 0.23, alpha = 0.96 },
        asr = { red = 0.04, green = 0.52, blue = 1.00, alpha = 0.96 },
        processing = { red = 1.00, green = 0.62, blue = 0.00, alpha = 0.96 },
        success = { red = 0.20, green = 0.78, blue = 0.35, alpha = 0.96 },
    }

    local fill = colors[kind] or colors.processing
    local stage_bar_w = size.w - 24
    local stage_fill_w = math.floor(stage_bar_w * progress / 100)
    local overall_fill_w = math.floor(stage_bar_w * overall_progress / 100)

    hud[3].fillColor = fill
    hud[4].text = string.format("Whisper · %s", label)
    hud[5].text = string.format("节点 %s · 阶段 %d%% · 总 %d%%", utf8_truncate(label, 8), progress, overall_progress)
    hud[7].frame = { x = 12, y = stage_y, w = stage_fill_w, h = stage_track_h }
    hud[7].fillColor = fill
    hud[9].frame = { x = 12, y = overall_y, w = overall_fill_w, h = overall_track_h }
    hud[9].fillColor = { red = fill.red, green = fill.green, blue = fill.blue, alpha = 0.70 }

    if kind == "success" then
        hs.timer.doAfter(get_status_done_sec(), M.hide_icon)
    end
end

local function ensure_hud_timer()
    if hud_state.timer then
        return
    end
    hud_state.timer = hs.timer.doEvery(get_hud_progress_tick_sec(), function()
        if not hud_state.auto_progress or not hud_state.kind then
            stop_hud_timer()
            return
        end
        if hud_overlay_enabled() and not hud then
            stop_hud_timer()
            return
        end
        local started = hud_state.started_ns or hs.timer.absoluteTime()
        local elapsed_sec = math.max(0, (hs.timer.absoluteTime() - started) / 1e9)
        local progress = auto_progress(hud_state.kind, elapsed_sec, hud_state.duration_sec)
        if progress then
            render_hud(hud_state.kind, {
                label = hud_state.label or default_label(hud_state.kind),
                progress = progress,
                overall_range = hud_state.overall_range,
            })
        end
    end)
end

function M.show_icon(kind, opts)
    local target_kind = kind or "processing"
    opts = opts or {}
    local label = tostring(opts.label or default_label(target_kind))
    local progress = opts.progress
    if progress == nil then
        progress = target_kind == "success" and 100 or 0
    end

    hud_state.kind = target_kind
    hud_state.label = label
    hud_state.started_ns = hs.timer.absoluteTime()
    hud_state.duration_sec = tonumber(opts.duration_sec) or default_duration_sec(target_kind)
    hud_state.overall_range = normalize_overall_range(target_kind, opts.overall_range)
    hud_state.auto_progress = (opts.auto_progress ~= false)
        and (target_kind == "record" or target_kind == "asr" or target_kind == "processing")

    render_hud(target_kind, {
        label = label,
        progress = progress,
        overall_progress = opts.overall_progress,
        overall_range = hud_state.overall_range,
    })

    if hud_state.auto_progress then
        ensure_hud_timer()
    else
        stop_hud_timer()
    end
end

function M.update_icon(opts)
    if not hud and hud_overlay_enabled() then
        return
    end
    opts = opts or {}
    local target_kind = opts.kind or hud_state.kind or hud_kind or "processing"
    local target_label = opts.label or hud_state.label or default_label(target_kind)
    local target_progress = opts.progress
    local target_overall = opts.overall_progress

    if opts.duration_sec ~= nil then
        hud_state.duration_sec = tonumber(opts.duration_sec) or hud_state.duration_sec
    end
    if opts.overall_range ~= nil then
        hud_state.overall_range = normalize_overall_range(target_kind, opts.overall_range)
    elseif not hud_state.overall_range then
        hud_state.overall_range = normalize_overall_range(target_kind, nil)
    end
    if opts.auto_progress ~= nil then
        hud_state.auto_progress = opts.auto_progress and true or false
    end
    if opts.restart_clock then
        hud_state.started_ns = hs.timer.absoluteTime()
    end

    if target_progress == nil and hud_state.auto_progress then
        local started = hud_state.started_ns or hs.timer.absoluteTime()
        local elapsed_sec = math.max(0, (hs.timer.absoluteTime() - started) / 1e9)
        target_progress = auto_progress(target_kind, elapsed_sec, hud_state.duration_sec)
    end

    hud_state.kind = target_kind
    hud_state.label = target_label
    render_hud(target_kind, {
        label = target_label,
        progress = target_progress,
        overall_progress = target_overall,
        overall_range = hud_state.overall_range,
    })

    if hud_state.auto_progress then
        ensure_hud_timer()
    else
        stop_hud_timer()
    end
end

function M.has_icon()
    return hud ~= nil
end

function M.hide_stream()
    if stream_hud then
        stream_hud:delete()
        stream_hud = nil
    end
end

function M.show_stream(content)
    local display_text = content or ""
    if #display_text > 200 then
        display_text = "..." .. display_text:sub(-197)
    end
    
    if not stream_hud then
        local screen = hs.screen.mainScreen():frame()
        local size = get_stream_size()
        stream_hud = hs.canvas.new({ x = screen.x + 50, y = screen.y + 50, w = size.w, h = size.h })
        stream_hud:appendElements({
            type = "rectangle",
            action = "fill",
            frame = { x = 0, y = 0, w = size.w, h = size.h },
            fillColor = { red = 0.1, green = 0.1, blue = 0.1, alpha = 0.9 },
            roundedRectRadii = { xRadius = 10, yRadius = 10 },
        })
        stream_hud:appendElements({
            type = "text",
            frame = { x = 10, y = 10, w = size.w - 20, h = size.h - 20 },
            text = display_text,
            textColor = { white = 1, alpha = 1 },
            textFont = UI_FONT,
            textSize = 13,
        })
        stream_hud:show()
    else
        stream_hud[2].text = display_text
    end
end

function M.hide_command_status()
    if command_timer then
        command_timer:stop()
        command_timer = nil
    end
    if command_hud then
        command_hud:delete()
        command_hud = nil
    end
end

function M.show_command_status(text, timeout)
    show_status_menubar(text, { source = "command" })
    if get_status_primary() == "menubar" and not should_show_command_overlay(text) then
        return
    end
    if not should_show_command_overlay(text) then
        return
    end
    if command_timer then
        command_timer:stop()
        command_timer = nil
    end
    if not command_hud then
        local screen = hs.screen.mainScreen():frame()
        local size = get_command_size()
        command_hud = hs.canvas.new({ x = screen.x + 50, y = screen.y + 50, w = size.w, h = size.h })
        command_hud:appendElements({
            type = "rectangle",
            action = "fill",
            frame = { x = 0, y = 0, w = size.w, h = size.h },
            fillColor = { red = 0.12, green = 0.13, blue = 0.16, alpha = 0.88 },
            roundedRectRadii = { xRadius = 10, yRadius = 10 },
        }, {
            type = "rectangle",
            action = "stroke",
            frame = { x = 0.5, y = 0.5, w = size.w - 1, h = size.h - 1 },
            strokeColor = { white = 1, alpha = 0.2 },
            strokeWidth = 1,
            roundedRectRadii = { xRadius = 10, yRadius = 10 },
        })
        command_hud:appendElements({
            type = "text",
            frame = { x = 12, y = 10, w = size.w - 24, h = size.h - 20 },
            textColor = { white = 1, alpha = 1 },
            textFont = UI_FONT,
            textSize = 13,
        })
    end
    local kind = status_kind_from_text(text)
    local palette = {
        error = {
            fill = { red = 0.30, green = 0.12, blue = 0.12, alpha = 0.90 },
            stroke = { red = 1.00, green = 0.36, blue = 0.33, alpha = 0.65 },
        },
        warning = {
            fill = { red = 0.28, green = 0.20, blue = 0.08, alpha = 0.90 },
            stroke = { red = 1.00, green = 0.62, blue = 0.00, alpha = 0.65 },
        },
        success = {
            fill = { red = 0.10, green = 0.24, blue = 0.14, alpha = 0.90 },
            stroke = { red = 0.20, green = 0.78, blue = 0.35, alpha = 0.65 },
        },
        progress = {
            fill = { red = 0.10, green = 0.16, blue = 0.29, alpha = 0.90 },
            stroke = { red = 0.04, green = 0.52, blue = 1.00, alpha = 0.65 },
        },
        info = {
            fill = { red = 0.12, green = 0.13, blue = 0.16, alpha = 0.88 },
            stroke = { white = 1, alpha = 0.2 },
        },
    }
    local style = palette[kind] or palette.info
    command_hud[1].fillColor = style.fill
    command_hud[2].strokeColor = style.stroke
    command_hud[3].text = text or ""
    command_hud:show()
    if timeout and timeout > 0 then
        command_timer = hs.timer.doAfter(timeout, M.hide_command_status)
    end
end

function M.has_stream()
    return stream_hud ~= nil
end

function M.hide_all()
    M.hide_icon()
    M.hide_stream()
    M.hide_command_status()
end

return M
