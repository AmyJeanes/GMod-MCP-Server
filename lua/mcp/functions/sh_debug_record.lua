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

local MAX_SECONDS = 30      -- window hard cap; keep <= the per-tool request timeout below
local RAW_CEILING = 5000    -- hard memory cap on raw samples, independent of max_samples
local SAMPLE_DEPTH = 4      -- per-sample serialization caps so one fat sample can't blow up
local SAMPLE_NODES = 80     -- (the whole-response node cap is the ultimate backstop)

-- Compile a caller snippet as a function body receiving the hook's args as `...`.
-- Returns the function, or nil + the compile error string.
local function compileBody(src, name)
    local chunk = CompileString("return function(...)\n" .. src .. "\nend", name, false)
    if type(chunk) == "string" then return nil, chunk end
    return chunk()
end

-- Evenly downsample to `target` points, always keeping the first and last. Returns the
-- (possibly unchanged) array and whether it was downsampled.
local function downsample(arr, target)
    local n = #arr
    if n <= target then return arr, false end
    local out = {}
    for i = 0, target - 1 do
        out[#out + 1] = arr[math.floor(1 + i * (n - 1) / (target - 1) + 0.5)]
    end
    return out, true
end

MCP:AddFunction({
    id = "debug_record",
    description = "Record a value each time a hook fires, for a bounded window, then return the time series -- a managed sampling probe that owns the hook lifecycle (unique namespaced hook, duration cap, auto-remove on end/stop/error) so you never hand-roll hook.Add/poll/hook.Remove. Blocks until the window ends. `hook` is the event to attach to (server: Think, Tick, StartCommand, PhysicsCollide; client: CreateMove, Think, HUDPaint -- any hook name works; one that never fires just yields an empty series at the cap). `sample` is a Lua function body that receives the hook's arguments as `...` and `return`s the value to record -- return a table for several values (e.g. \"return LocalPlayer():GetVelocity():Length()\" or \"local ply, cmd = ... return cmd:GetForwardMove()\"); prefer scalar/small values, as large per-sample tables may be truncated by the response size cap. `seconds` is the window and hard safety cap (max 30). Optional `stop` (a Lua body with the same `...` args) ends recording early when it returns truthy -- checked every fire, so e.g. record cmd state until a jump. `interval` throttles sampling to at most once per that many seconds (default: every fire). `max_samples` caps the returned series (default 100, max 500); more are recorded and evenly downsampled on return (downsampled=true), so a duration window comes back evenly spread. Each row is {t = seconds since start, v = the sampled value}. A per-fire error stops and auto-removes the hook and returns the partial series with reason \"error\"; other reasons are \"stop\", \"duration\", \"overflow\" (hit the raw ceiling). Server or client realm -- pick the realm whose hooks you need.",
    requires = { "unsafe" },
    -- Blocking past the host's 10s default; declare the window + slack (host clamps to its max).
    timeout = MAX_SECONDS + 3,
    schema = {
        type = "object",
        properties = {
            hook = {
                type = "string",
                description = "Hook event to attach to (e.g. \"Think\", \"StartCommand\", \"CreateMove\"). Any name; a never-firing hook yields an empty series at the cap.",
            },
            sample = {
                type = "string",
                description = "Lua function body run each fire; receives the hook's arguments as `...`. Use `return` to record a value (a table for several). E.g. \"return LocalPlayer():GetVelocity():Length()\".",
            },
            seconds = {
                type = "number",
                description = "Recording window in seconds (max 30). Also the hard safety cap, so it can never hang.",
            },
            stop = {
                type = "string",
                description = "Optional Lua function body (same `...` args) checked every fire; recording ends early when it returns truthy (reason \"stop\").",
            },
            interval = {
                type = "number",
                description = "Throttle: minimum seconds between samples. Default 0 (record every fire). The stop condition is still checked every fire.",
            },
            max_samples = {
                type = "integer", minimum = 2, maximum = 500,
                description = "Max points in the returned series (default 100). More are recorded and evenly downsampled on return.",
            },
        },
        required = { "hook", "sample", "seconds" },
    },
    handler = function(args, ctx)
        args = args or {}

        if type(args.hook) ~= "string" or args.hook == "" then
            return { ok = false, error = "`hook` must be a non-empty hook event name (e.g. \"Think\", \"StartCommand\")" }
        end
        if type(args.sample) ~= "string" or args.sample == "" then
            return { ok = false, error = "`sample` must be a non-empty Lua snippet (use `return` to record a value)" }
        end
        local seconds = tonumber(args.seconds)
        if not seconds then return { ok = false, error = "`seconds` is required (the recording window and safety cap)" } end
        seconds = math.Clamp(seconds, 0.05, MAX_SECONDS)
        local interval = math.max(tonumber(args.interval) or 0, 0)
        local maxSamples = math.Clamp(math.floor(tonumber(args.max_samples) or 100), 2, 500)

        local sampleFn, serr = compileBody(args.sample, "mcp_debug_sample")
        if not sampleFn then return { ok = false, error = "`sample` compile error: " .. serr } end
        local stopFn
        if args.stop ~= nil then
            if type(args.stop) ~= "string" then return { ok = false, error = "`stop` must be a Lua string" } end
            local sf, e2 = compileBody(args.stop, "mcp_debug_stop")
            if not sf then return { ok = false, error = "`stop` compile error: " .. e2 } end
            stopFn = sf
        end

        local hookPoint = args.hook
        MCP._debugSeq = (MCP._debugSeq or 0) + 1
        local hookId = "mcp_debug_" .. MCP._debugSeq

        local buffer = {}
        local start = RealTime()
        local lastSampleT
        local doneReason, doneErr

        hook.Add(hookPoint, hookId, function(...)
            if doneReason then return end -- finished; await RunFor teardown
            local now = RealTime()

            -- Stop is checked every fire so an event is caught promptly; only sampling
            -- is throttled by `interval`. The stop moment always records a final sample.
            local stopHit = false
            if stopFn then
                local sok, sres = pcall(stopFn, ...)
                if not sok then doneReason, doneErr = "error", tostring(sres) return end
                stopHit = sres and true or false
            end

            if stopHit or interval <= 0 or not lastSampleT or (now - lastSampleT) >= interval then
                lastSampleT = now
                local ok, val = pcall(sampleFn, ...)
                if not ok then doneReason, doneErr = "error", tostring(val) return end
                buffer[#buffer + 1] = {
                    t = math.Round(now - start, 3),
                    v = MCP.util.Serialize(val, { max_depth = SAMPLE_DEPTH, max_nodes = SAMPLE_NODES }),
                }
                if #buffer >= RAW_CEILING then doneReason = "overflow" return end
            end

            -- Never return a value from the hook: don't perturb CreateMove/StartCommand etc.
            if stopHit then doneReason = "stop" end
        end)

        MCP:RunFor({
            seconds = seconds,
            stop = function() return doneReason ~= nil end,
        }, function(r)
            hook.Remove(hookPoint, hookId)
            local reason = doneReason or "duration"
            local samples, down = downsample(buffer, maxSamples)
            local result = {
                ok = reason ~= "error",
                realm = MCP.util.RealmName(),
                hook = hookPoint,
                reason = reason,
                seconds_elapsed = math.Round(r.elapsed, 3),
                sample_count = #buffer,
                returned = #samples,
                downsampled = down,
                samples = samples,
            }
            if doneErr then result.error = doneErr end
            ctx.respond(result)
        end)

        return ctx.deferred
    end,
})
