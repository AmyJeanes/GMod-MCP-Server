-- MVP tool: execute arbitrary Lua source in the current realm.
-- Gated behind the `unsafe` capability (mcp_allow_unsafe).
--
-- Optional wait args make it blocking: run `code` (the setup/arm), then wait either a fixed
-- `wait_seconds` or until `wait_until` (a Lua expression) goes truthy, then optionally read
-- post-wait state via `capture`. This replaces the arm -> _G.global -> poll -> read splits and
-- the timer.Simple workarounds that the wait would otherwise force. The whole tool is already
-- `unsafe` (it runs caller Lua), so wait_until/capture need no extra gate. The wait reuses the
-- bounded-wait core (MCP:RunFor, RealTime + Think, never timer.Simple).

local MAX_WAIT = 30 -- safety cap on the wait; keep <= the declared per-tool timeout below

-- GMod is Lua 5.1 (no table.pack), so capture the return count via select —
-- this stays correct even when the call ends in trailing nils.
local function packResults(ok, ...)
    return ok, select("#", ...), { ... }
end

local function buildResult(count, rets)
    if count == 1 then return rets[1] end
    if count > 1 then
        local r = {}
        for i = 1, count do r[i] = rets[i] end
        return r
    end
    return nil
end

MCP:AddFunction({
    id = "lua_run",
    -- Blocking when wait args are present; declare the window + slack so the host waits for it
    -- instead of its 10s default. Harmless for the common synchronous call (it returns at once).
    timeout = MAX_WAIT + 3,
    description = "Compile and execute Lua source in this realm. Use `return <expr>` to get a value back. Optionally make it blocking: `wait_seconds` waits a fixed time after running `code`; `wait_until` is a Lua expression polled each frame that ends the wait as soon as it returns truthy (with `wait_seconds`, or a 30s default, as the safety cap). `capture` is a Lua expression evaluated AFTER the wait whose value becomes `result` -- use it to read the state the wait was waiting for; without `capture`, `result` is `code`'s own return. When waiting it reports `reason` (\"until\" = wait_until fired, \"timeout\" = wait_until never fired within the cap, \"duration\" = a plain wait_seconds elapsed) and `seconds_elapsed`. Use this instead of arming a _G global and polling, or timer.Simple. A wait_until that errors ends the call with that error.",
    schema = {
        type = "object",
        properties = {
            code = {
                type = "string",
                description = "Lua source to execute. Use `return <expr>` to capture a value.",
            },
            wait_seconds = {
                type = "number", minimum = 0.05, maximum = MAX_WAIT,
                description = "After running `code`, block for this many seconds (max 30). With `wait_until`, this is the timeout cap instead of a fixed delay.",
            },
            wait_until = {
                type = "string",
                description = "A Lua expression polled each frame after `code` runs; the wait ends when it returns truthy (reason \"until\"). Capped by `wait_seconds` or 30s (then reason \"timeout\"). E.g. \"IsValid(ents.GetByIndex(5)) and ents.GetByIndex(5):GetVelocity():Length() < 5\".",
            },
            capture = {
                type = "string",
                description = "A Lua expression evaluated AFTER the wait; its value becomes `result`. Requires wait_seconds or wait_until. E.g. \"ents.GetByIndex(5):GetPos()\".",
            },
        },
        required = { "code" },
    },
    requires = { "unsafe" },
    handler = function(args, ctx)
        local code = args.code
        if type(code) ~= "string" then
            return { ok = false, error = "missing or non-string `code` argument" }
        end

        local fn = CompileString(code, "mcp_lua_run", false)
        if type(fn) == "string" then
            return { ok = false, error = "compile error: " .. fn }
        end

        local waitSeconds = tonumber(args.wait_seconds)
        local waiting = waitSeconds ~= nil or args.wait_until ~= nil
        local hasCapture = args.capture ~= nil

        if hasCapture and not waiting then
            return { ok = false, error = "`capture` only applies after a wait; add `wait_seconds` or `wait_until`" }
        end

        -- Compile the wait/capture expressions before running code, so a typo fails fast.
        local untilFn, captureFn
        if args.wait_until ~= nil then
            if type(args.wait_until) ~= "string" then return { ok = false, error = "`wait_until` must be a Lua expression string" } end
            local c = CompileString("return (" .. args.wait_until .. ")", "mcp_lua_run_until", false)
            if type(c) == "string" then return { ok = false, error = "`wait_until` compile error: " .. c } end
            untilFn = c
        end
        if hasCapture then
            if type(args.capture) ~= "string" then return { ok = false, error = "`capture` must be a Lua expression string" } end
            local c = CompileString("return (" .. args.capture .. ")", "mcp_lua_run_capture", false)
            if type(c) == "string" then return { ok = false, error = "`capture` compile error: " .. c } end
            captureFn = c
        end

        -- Run code now (the setup/arm). The bridge serializes raw return values, so a returned
        -- table/Entity/Vector comes back structured.
        local ok, count, rets = packResults(pcall(fn))
        if not ok then
            return { ok = false, error = "runtime error: " .. tostring(rets[1]) }
        end

        -- Synchronous path (no wait args) -- byte-identical to the original behaviour.
        if not waiting then
            return { ok = true, returns = count, result = buildResult(count, rets) }
        end

        local cap = waitSeconds and math.Clamp(waitSeconds, 0.05, MAX_WAIT) or MAX_WAIT
        local runForOpts = { seconds = cap }
        if untilFn then
            -- RunFor pcall's stop, so a throw in the expression ends the wait as reason "error".
            runForOpts.stop = function() return untilFn() and true or false end
        end

        MCP:RunFor(runForOpts, function(r)
            if r.reason == "error" then
                ctx.respond({ ok = false, error = "`wait_until` error: " .. tostring(r.error), seconds_elapsed = math.Round(r.elapsed, 3) })
                return
            end

            local reason
            if r.reason == "stop" then
                reason = "until"
            elseif untilFn then
                reason = "timeout"
            else
                reason = "duration"
            end

            local returns, result = count, buildResult(count, rets)
            if captureFn then
                local cok, ccount, crets = packResults(pcall(captureFn))
                if not cok then
                    ctx.respond({ ok = false, error = "`capture` error: " .. tostring(crets[1]), reason = reason, seconds_elapsed = math.Round(r.elapsed, 3) })
                    return
                end
                returns, result = ccount, buildResult(ccount, crets)
            end

            ctx.respond({
                ok = true,
                waited = true,
                reason = reason,
                seconds_elapsed = math.Round(r.elapsed, 3),
                returns = returns,
                result = result,
            })
        end)

        return ctx.deferred
    end,
})
