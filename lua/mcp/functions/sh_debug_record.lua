-- debug_record: anchor of the debug_* family. A managed sampling probe -- record a value
-- each time a hook fires, for a bounded window, then return the time series. The tool owns
-- the hook lifecycle (unique namespaced id, duration cap, auto-remove on end/stop/error) so
-- callers never hand-roll the hook.Add / poll / hook.Remove boilerplate that the scan found
-- recurring ~30x just developing player_walk and the bots.
--
-- Caller Lua runs every fire (== lua_run power), so the whole tool rides the `unsafe` gate.
-- Blocking/deferred: the handler installs the sample hook, then uses MCP:RunFor (the shared
-- bounded-wait core, on Think) purely as the duration backstop -- so even a hook that NEVER
-- fires still ends cleanly at `seconds`, and resolution happens exactly once.
--
-- A shared `state` table (first arg of every snippet) persists across fires, so a sample can
-- carry data frame-to-frame (e.g. state.lastz for teleport-detect). `init` seeds it before the
-- hook installs; `trigger` runs once right after, so you can arm the recorder and fire the thing
-- you want to record in one atomic call (no round-trip gap where the event slips past).
--
-- The per-fire recording / downsample / stats-histogram logic lives in MCP.sampler
-- (libraries/sh_sampler.lua), shared with the interactive on-screen recorder; this handler owns
-- only the hook install, the RunFor duration backstop, and the response envelope.

local MAX_SECONDS = 30      -- window hard cap; keep <= the per-tool request timeout below

MCP:AddFunction({
    id = "debug_record",
    description = "Record a value each time a hook fires, for a bounded window, then return the time series -- a managed sampling probe that owns the hook lifecycle (unique namespaced hook, duration cap, auto-remove on end/stop/error) so you never hand-roll hook.Add/poll/hook.Remove. Blocks until the window ends. `hook` is the event to attach to (server: Think, Tick, StartCommand, PhysicsCollide, EntityTakeDamage; client: CreateMove, Think, HUDPaint, PreDrawOpaqueRenderables -- any hook name works; one that never fires just yields an empty series at the cap). `sample` is a Lua function body that receives a shared `state` table then the hook's arguments as `...`, and `return`s the value to record (a table or string is fine, not just a number; prefer small values, as large ones may be truncated by the response cap) -- e.g. \"return LocalPlayer():GetVelocity():Length()\" or \"local ply, cmd = ... return cmd:GetForwardMove()\". Return nothing to SKIP that fire, so you record only when a condition holds (sparse/conditional recording). The `state` table (first arg of every snippet) persists across fires, so a sample can compare against earlier frames -- e.g. \"local z = LocalPlayer():GetPos().z local dz = z - (state.lastz or z) state.lastz = z return dz\" to catch teleports. `init` (optional Lua body, same `state`) runs once before the hook installs to seed state; `trigger` (optional, same `state`) runs once right AFTER it installs, so you can arm the recorder and fire the thing you want to record in one atomic call (no gap where the event slips past). `seconds` is the window and hard safety cap (max 30). Optional `stop` (a Lua body with `state` + the same `...`) ends recording early when it returns truthy -- checked every fire. `interval` throttles sampling to at most once per that many seconds (default: every fire). `stats` true also returns an `aggregate` block (numeric_count/min/max/sum/avg) over the numeric samples at FULL resolution -- computed before downsampling, so the true min/max survive. `histogram` true instead returns a `histogram` -- a distinct-value tally of the samples ({value, count}, most-frequent first) plus distinct_count, for counting CATEGORICAL outcomes rather than numeric stats (have `sample` return a short string key); computed at full resolution too. `max_samples` caps the returned series (default 100, max 500); more are recorded and evenly downsampled on return (downsampled=true). Each row is {t = seconds since start, v = the sampled value}. A per-fire error stops and auto-removes the hook and returns the partial series with reason \"error\"; other reasons are \"stop\", \"duration\", \"overflow\" (hit the raw ceiling). Server or client realm -- pick the realm whose hooks you need.",
    requires = { "unsafe" },
    -- Blocking past the host's 10s default; declare the window + slack (host clamps to its max).
    timeout = MAX_SECONDS + 3,
    schema = {
        type = "object",
        properties = {
            hook = {
                type = "string",
                description = "Hook event to attach to (e.g. \"Think\", \"StartCommand\", \"CreateMove\", \"PreDrawOpaqueRenderables\"). Any name; a never-firing hook yields an empty series at the cap.",
            },
            sample = {
                type = "string",
                description = "Lua function body run each fire; receives the shared `state` table then the hook's arguments as `...`. Use `return` to record a value (a table/string is fine); return nothing to skip that fire. E.g. \"return LocalPlayer():GetVelocity():Length()\".",
            },
            seconds = {
                type = "number",
                description = "Recording window in seconds (max 30). Also the hard safety cap, so it can never hang.",
            },
            stop = {
                type = "string",
                description = "Optional Lua function body (`state` + the same `...` args) checked every fire; recording ends early when it returns truthy (reason \"stop\").",
            },
            init = {
                type = "string",
                description = "Optional Lua body run once (with the shared `state` table) BEFORE the hook installs -- seed state for the sample, e.g. \"state.startpos = LocalPlayer():GetPos()\".",
            },
            trigger = {
                type = "string",
                description = "Optional Lua body run once (with `state`) right AFTER the hook installs -- fire the action you want to record, atomically with the arm so no event slips past.",
            },
            interval = {
                type = "number",
                description = "Throttle: minimum seconds between samples. Default 0 (record every fire). The stop condition is still checked every fire.",
            },
            stats = {
                type = "boolean",
                description = "When true, also return an `aggregate` block (numeric_count/min/max/sum/avg) over the numeric samples at full resolution (before downsampling).",
            },
            histogram = {
                type = "boolean",
                description = "When true, also return a `histogram` -- a distinct-value tally of the samples (each value as a string key -> count), sorted most-frequent first, at full resolution. Distinct from `stats` (numeric min/max/avg): use this to count categorical outcomes, e.g. how many times each render-context/state string occurred. Have `sample` return a short string key. Capped at 100 distinct values (distinct_count is the true total).",
            },
            max_samples = {
                type = "integer", minimum = 2, maximum = 500,
                description = "Max points in the returned series (default 100). More are recorded and evenly downsampled on return.",
            },
        },
        required = { "hook", "sample", "seconds" },
    },
    ---@param args table
    handler = function(args, ctx)
        args = args or {}

        if type(args.hook) ~= "string" or args.hook == "" then
            return { ok = false, error = "`hook` must be a non-empty hook event name (e.g. \"Think\", \"StartCommand\")" }
        end
        if type(args.sample) ~= "string" or args.sample == "" then
            return { ok = false, error = "`sample` must be a non-empty Lua snippet (use `return` to record a value; return nothing to skip a fire)" }
        end
        local seconds = tonumber(args.seconds)
        if not seconds then return { ok = false, error = "`seconds` is required (the recording window and safety cap)" } end
        seconds = math.Clamp(seconds, 0.05, MAX_SECONDS)

        local sampleFn, serr = MCP.sampler.Compile(args.sample, "mcp_debug_sample")
        if not sampleFn then return { ok = false, error = "`sample` compile error: " .. serr } end

        -- Compile the optional snippets, each with a precise chunk name for runtime errors.
        ---@type table<string, function>
        local optional = {}
        for _, spec in ipairs({
            { key = "stop", name = "mcp_debug_stop" },
            { key = "init", name = "mcp_debug_init" },
            { key = "trigger", name = "mcp_debug_trigger" },
        }) do
            local src = args[spec.key]
            if src ~= nil then
                if type(src) ~= "string" then return { ok = false, error = "`" .. spec.key .. "` must be a Lua string" } end
                local fn, e = MCP.sampler.Compile(src, spec.name)
                if not fn then return { ok = false, error = "`" .. spec.key .. "` compile error: " .. e } end
                optional[spec.key] = fn
            end
        end
        local stopFn, initFn, triggerFn = optional.stop, optional.init, optional.trigger

        local sampler = MCP.sampler.New({
            sample = sampleFn,
            stop = stopFn,
            interval = args.interval,
            max_samples = args.max_samples,
            want_stats = args.stats,
            want_histogram = args.histogram,
        })

        -- `state` (sampler.state) is shared across init/sample/stop/trigger.
        if initFn then
            local iok, ierr = pcall(initFn, sampler.state)
            if not iok then return { ok = false, error = "`init` error: " .. tostring(ierr) } end
        end

        local hookPoint = args.hook
        MCP._debugSeq = (MCP._debugSeq or 0) + 1
        local hookId = "mcp_debug_" .. MCP._debugSeq

        hook.Add(hookPoint, hookId, function(...)
            if sampler.doneReason then return end -- finished; await RunFor teardown
            sampler:Fire(...)
            -- Never return a value from the hook: don't perturb CreateMove/StartCommand etc.
        end)

        -- Fire-after-install: the hook is already live, so anything trigger causes is recorded.
        if triggerFn then
            local tok, terr = pcall(triggerFn, sampler.state)
            if not tok then
                hook.Remove(hookPoint, hookId)
                return { ok = false, error = "`trigger` error: " .. tostring(terr) }
            end
        end

        MCP:RunFor({
            seconds = seconds,
            stop = function() return sampler.doneReason ~= nil end,
        }, function(r)
            hook.Remove(hookPoint, hookId)
            local block = sampler:Result()
            ---@type table
            local result = {
                ok = block.reason ~= "error",
                realm = MCP.util.RealmName(),
                hook = hookPoint,
                seconds_elapsed = math.Round(r.elapsed, 3),
            }
            for k, v in pairs(block) do result[k] = v end
            ctx.respond(result)
        end)

        return ctx.deferred
    end,
})
