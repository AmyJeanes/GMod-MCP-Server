-- Bounded per-frame loops for deferred handlers. Two layers:
--
--   MCP:RunFor -- the generic base. Runs `on_each` and/or polls a `stop` condition
--                 each GM:Think frame, up to a `seconds` cap. Non-blocking; resolves
--                 exactly once via onDone. This is the windowed-loop core that
--                 debug_record (sample-per-frame) and lua_run's wait args reuse.
--
--   MCP:Settle -- layered on RunFor. Resolves once a `check` predicate has held
--                 CONTINUOUSLY for `stable_for` (the dwell) -- so a transient blip
--                 (a bounce apex, a one-frame velocity dip) can't false-settle.
--                 For "apply a mutation, then wait until it comes to rest before
--                 reporting." The harness can't know what "settled" means (velocity
--                 for poses, existence for removes), so the caller supplies `check`.
--
-- Timing is RealTime + GM:Think, never timer.Simple (see timing rules). The .NET
-- per-tool request `timeout` is the real ceiling -- a tool's `seconds` must sit
-- under it, or the host gives up on the call before this loop finishes.

MCP._runForSeq = MCP._runForSeq or 0

local HARD_MAX_SECONDS = 60 -- backstop so a misconfigured loop can't sample forever

-- opts: { seconds (required, >0), on_each = function(elapsed)?, stop = function(elapsed) -> truthy?, interval? }
-- onDone({ reason = "stop" | "duration" | "error", elapsed, ticks, error? })
--   stop     -> the stop condition fired (ended early)
--   duration -> hit the seconds cap
--   error    -> on_each/stop threw (caught); `error` holds the message
function MCP:RunFor(opts, onDone)
    opts = opts or {}
    local seconds = tonumber(opts.seconds)
    if not seconds or seconds <= 0 then
        error("MCP:RunFor requires opts.seconds > 0", 2)
    end
    seconds = math.min(seconds, HARD_MAX_SECONDS)

    local onEach = opts.on_each
    local stop = opts.stop
    local interval = math.max(tonumber(opts.interval) or 0, 0)

    MCP._runForSeq = MCP._runForSeq + 1
    local hookId = "MCP_RunFor_" .. MCP._runForSeq

    local start = RealTime()
    local lastTick
    local ticks = 0
    local done = false

    local function finish(reason, err)
        if done then return end
        done = true
        hook.Remove("Think", hookId)
        if onDone then
            onDone({ reason = reason, elapsed = RealTime() - start, ticks = ticks, error = err })
        end
    end

    hook.Add("Think", hookId, function()
        if done then return end
        local now = RealTime()
        local elapsed = now - start

        -- Throttle to `interval`, but never skip the tick that crosses the deadline.
        if interval > 0 and lastTick and (now - lastTick) < interval and elapsed < seconds then
            return
        end
        lastTick = now
        ticks = ticks + 1

        if onEach then
            local ok, err = pcall(onEach, elapsed)
            if not ok then return finish("error", err) end
        end

        if stop then
            local ok, res = pcall(stop, elapsed)
            if not ok then return finish("error", res) end
            if res then return finish("stop") end
        end

        if elapsed >= seconds then return finish("duration") end
    end)
end

-- opts: { check (required, function(elapsed) -> truthy = "settled now"), stable_for?, seconds (required), on_each?, interval? }
-- onDone({ settled, reason, elapsed, ticks, error? })
--   settled is true only when `check` held continuously for `stable_for` (reason "stop");
--   a timeout (reason "duration") or a `check` error (reason "error") reports settled = false.
function MCP:Settle(opts, onDone)
    opts = opts or {}
    if type(opts.check) ~= "function" then
        error("MCP:Settle requires opts.check to be a function", 2)
    end
    local check = opts.check
    local stableFor = math.max(tonumber(opts.stable_for) or 0, 0)
    local stableSince

    self:RunFor({
        seconds = opts.seconds,
        on_each = opts.on_each,
        interval = opts.interval,
        stop = function(elapsed)
            if not check(elapsed) then
                stableSince = nil -- flapped false: restart the dwell
                return false
            end
            if not stableSince then stableSince = elapsed end
            return (elapsed - stableSince) >= stableFor
        end,
    }, function(r)
        r.settled = r.reason == "stop"
        if onDone then onDone(r) end
    end)
end
