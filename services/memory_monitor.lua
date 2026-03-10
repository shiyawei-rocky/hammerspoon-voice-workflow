-- Memory Monitor: 菜单栏内存/CPU 监控模块
local cfg_value = require("lib.utils").cfg_value

local M = {}

function M.start(cfg, runtime_usage, logf)
    logf = logf or function(fmt, ...) hs.printf(fmt, ...) end

    local MEMORY_MONITOR = {
        enabled = cfg_value(cfg.memory and cfg.memory.enabled, true),
        update_interval_sec = cfg_value(cfg.memory and cfg.memory.update_interval_sec, 3),
        warn_percent = cfg_value(cfg.memory and cfg.memory.warn_percent, 75),
        critical_percent = cfg_value(cfg.memory and cfg.memory.critical_percent, 85),
        gc_cooldown_sec = cfg_value(cfg.memory and cfg.memory.gc_cooldown_sec, 90),
        auto_guard = cfg_value(cfg.memory and cfg.memory.auto_guard, true),
        compact_title = cfg_value(cfg.memory and cfg.memory.compact_title, true),
        history_size = cfg_value(cfg.memory and cfg.memory.history_size, 120),
        policy_mode = cfg_value(cfg.memory and cfg.memory.policy_mode, "balanced"),
    }
    local state = {
        menubar = nil,
        timer = nil,
        visible = true,
        auto_guard = MEMORY_MONITOR.auto_guard,
        last_gc_at = 0,
        last_used_bytes = 0,
        last_total_bytes = 0,
        last_mem_percent = 0,
        last_cpu_percent = 0,
        history = {},
        policy = {
            warn_percent = MEMORY_MONITOR.warn_percent,
            critical_percent = MEMORY_MONITOR.critical_percent,
            gc_cooldown_sec = MEMORY_MONITOR.gc_cooldown_sec,
            mode = MEMORY_MONITOR.policy_mode,
        },
    }

    local function read_memory()
        local ok, stats = pcall(hs.host.vmStat)
        if not ok or type(stats) ~= "table" then
            return nil
        end
        local page_size = tonumber(stats.pageSize or 0)
        local total = tonumber(stats.memSize or 0)
        local pages_active = tonumber(stats.pagesActive or 0)
        local pages_wired = tonumber(stats.pagesWiredDown or 0)
        local pages_compressor = tonumber(stats.pagesUsedByVMCompressor or 0)
        if page_size <= 0 or total <= 0 then
            return nil
        end
        local used = (pages_active + pages_wired + pages_compressor) * page_size
        local percent = math.floor((used / total) * 100)
        if percent < 0 then
            percent = 0
        elseif percent > 100 then
            percent = 100
        end
        return used, total, percent
    end

    local function read_cpu()
        local ok, usage = pcall(hs.host.cpuUsage)
        if not ok or type(usage) ~= "table" then
            return nil
        end
        local overall = usage.overall
        if type(overall) ~= "table" then
            overall = usage
        end
        local active = tonumber(overall.active)
        if not active then
            local user_v = tonumber(overall.user or 0) or 0
            local system_v = tonumber(overall.system or 0) or 0
            active = user_v + system_v
        end
        if not active then
            return nil
        end
        if active < 0 then
            active = 0
        elseif active > 100 then
            active = 100
        end
        return math.floor(active + 0.5)
    end

    local function top_counter(tbl)
        local best_key = nil
        local best_value = 0
        for k, v in pairs(tbl) do
            if tonumber(v) and v > best_value then
                best_key = k
                best_value = v
            end
        end
        return best_key, best_value
    end

    local function level_of(percent)
        if percent >= state.policy.critical_percent then
            return "CRIT"
        elseif percent >= state.policy.warn_percent then
            return "WARN"
        end
        return "OK"
    end

    local function apply_policy(mode)
        state.policy.mode = mode
        if mode == "aggressive" then
            state.policy.warn_percent = 70
            state.policy.critical_percent = 80
            state.policy.gc_cooldown_sec = 45
            return
        end
        if mode == "conservative" then
            state.policy.warn_percent = 80
            state.policy.critical_percent = 90
            state.policy.gc_cooldown_sec = 150
            return
        end
        state.policy.warn_percent = MEMORY_MONITOR.warn_percent
        state.policy.critical_percent = MEMORY_MONITOR.critical_percent
        state.policy.gc_cooldown_sec = MEMORY_MONITOR.gc_cooldown_sec
    end

    local function ensure_menubar()
        if state.menubar then
            return true
        end
        state.menubar = hs.menubar.new()
        if not state.menubar then
            logf("[whisper] memory monitor menubar init failed")
            return false
        end
        return true
    end

    local function strategy_hint(mem_percent, cpu_percent, avg_mem, avg_cpu)
        local f5_count = tonumber(runtime_usage.actions["F5"] or 0) or 0
        if mem_percent >= state.policy.critical_percent then
            return "当前内存临界：建议保留自动守卫，关闭重型后台应用。"
        end
        if avg_mem >= state.policy.warn_percent and avg_cpu >= 75 then
            return "持续高压：建议切换激进策略并减少并发任务。"
        end
        if runtime_usage.total_events >= 40 and f5_count >= math.max(10, math.floor(runtime_usage.total_events * 0.3)) and avg_cpu >= 60 then
            return "F5 使用密集：建议保持平衡策略，缩短单次录音时长。"
        end
        if cpu_percent >= 85 then
            return "CPU 突发偏高：优先停止高负载任务后再做长文本处理。"
        end
        return "负载平稳：维持当前策略即可。"
    end

    local function render()
        local used, total, percent = read_memory()
        if not used then
            return
        end
        local cpu_percent = read_cpu() or 0
        local level = level_of(percent)
        state.last_mem_percent = percent
        state.last_cpu_percent = cpu_percent
        state.last_used_bytes = used
        state.last_total_bytes = total
        table.insert(state.history, { mem = percent, cpu = cpu_percent })
        if #state.history > MEMORY_MONITOR.history_size then
            table.remove(state.history, 1)
        end
        local mem_sum = 0
        local cpu_sum = 0
        local sample_count = 0
        for _, sample in ipairs(state.history) do
            mem_sum = mem_sum + (sample.mem or 0)
            cpu_sum = cpu_sum + (sample.cpu or 0)
            sample_count = sample_count + 1
        end
        local avg_mem = sample_count > 0 and math.floor(mem_sum / sample_count + 0.5) or percent
        local avg_cpu = sample_count > 0 and math.floor(cpu_sum / sample_count + 0.5) or cpu_percent

        if state.auto_guard and level == "CRIT" then
            local now = os.time()
            if now - state.last_gc_at >= state.policy.gc_cooldown_sec then
                collectgarbage("collect")
                state.last_gc_at = now
                logf("[whisper] memory_guard triggered gc percent=%d", percent)
            end
        end

        if not state.visible then
            return
        end
        if not ensure_menubar() then
            return
        end
        local title = MEMORY_MONITOR.compact_title and string.format("M%02d", percent) or string.format("M%02d C%02d", percent, cpu_percent)
        state.menubar:setTitle(title)
        state.menubar:setTooltip(string.format(
            "内存: %d%% (%.1f GB / %.1f GB)\nCPU: %d%%\n策略: %s (warn=%d%% critical=%d%% cooldown=%ds)\n自动守卫: %s",
            percent,
            used / 1024 / 1024 / 1024,
            total / 1024 / 1024 / 1024,
            cpu_percent,
            state.policy.mode,
            state.policy.warn_percent,
            state.policy.critical_percent,
            state.policy.gc_cooldown_sec,
            state.auto_guard and "ON" or "OFF"
        ))
        local top_action, top_action_count = top_counter(runtime_usage.actions)
        local top_app, top_app_count = top_counter(runtime_usage.apps)
        local top_hour, top_hour_count = top_counter(runtime_usage.hours)
        local hint = strategy_hint(percent, cpu_percent, avg_mem, avg_cpu)
        state.menubar:setMenu({
            { title = string.format("系统快照: 内存 %d%% / CPU %d%%", percent, cpu_percent), disabled = true },
            { title = string.format("滚动均值: 内存 %d%% / CPU %d%%（%d 样本）", avg_mem, avg_cpu, sample_count), disabled = true },
            { title = string.format("策略: %s (warn=%d%% critical=%d%% cooldown=%ds)", state.policy.mode, state.policy.warn_percent, state.policy.critical_percent, state.policy.gc_cooldown_sec), disabled = true },
            { title = string.format("习惯: Top Action=%s(%d) Top App=%s(%d) Peak=%s点(%d)", tostring(top_action or "-"), tonumber(top_action_count or 0), tostring(top_app or "-"), tonumber(top_app_count or 0), tostring(top_hour or "-"), tonumber(top_hour_count or 0)), disabled = true },
            { title = string.format("策略建议: %s", hint), disabled = true },
            { title = "-" },
            { title = "切换策略: 平衡", fn = function() apply_policy("balanced"); render() end },
            { title = "切换策略: 激进", fn = function() apply_policy("aggressive"); render() end },
            { title = "切换策略: 保守", fn = function() apply_policy("conservative"); render() end },
            {
                title = state.auto_guard and "关闭自动内存守卫" or "开启自动内存守卫",
                fn = function()
                    state.auto_guard = not state.auto_guard
                    render()
                end
            },
            {
                title = "立即执行 Lua GC",
                fn = function()
                    collectgarbage("collect")
                    state.last_gc_at = os.time()
                    render()
                end
            },
            {
                title = "隐藏内存监控",
                fn = function()
                    state.visible = false
                    if state.menubar then
                        state.menubar:delete()
                        state.menubar = nil
                    end
                end
            },
        })
    end

    apply_policy(MEMORY_MONITOR.policy_mode)
    if MEMORY_MONITOR.enabled then
        render()
        state.timer = hs.timer.doEvery(MEMORY_MONITOR.update_interval_sec, render)
    end
    M._state = state
end

function M.stop()
    if M._state then
        if M._state.timer then M._state.timer:stop(); M._state.timer = nil end
        if M._state.menubar then M._state.menubar:delete(); M._state.menubar = nil end
    end
end

return M
