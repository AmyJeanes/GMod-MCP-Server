-- debug_record_interactive (client realm): a player-driven front-end to the debug_record sampling
-- core, for repros the USER must physically perform (walk a path, time a crossing, mash a seam).
-- Where debug_record blocks on a blind fixed window the instant it fires, this shows the whole flow
-- in-game -- a Start confirm popup, a 3-2-1 countdown, a live "REC" HUD (seconds remaining, sample
-- count, an optional red flag counter, and a live readout of what you're measuring), then a
-- Done / Retry gate so a botched attempt can be re-run without a round-trip to the agent.
--
-- Two-call, so the human's timing is unbounded (the .NET host caps a single blocking call at 60s):
-- `debug_record_interactive` ARMS the recorder and returns immediately with a handle;
-- `debug_record_read` collects the series once the user clicks Done (it blocks up to `wait`, else
-- reports the current phase so the agent can poll again). Derma and HUDPaint are clientside, so the
-- UI lives here; the sampling core (MCP.sampler) is shared verbatim with debug_record.
--
-- PAIRED SERVER CAPTURE: pass a `link_id` (any unique string) to also drive a debug_record_interactive
-- on the SERVER realm (armed separately through the bridge with the same link_id). On Start this side
-- fires a non-code, host-gated "go at CurTime X" signal (sh_irec_net.lua); the server records the same
-- window and is read back separately. Both samplers tag each row with `ct` (CurTime), the shared tick
-- clock, so the two series align on `ct`. With a link_id, `sample` is optional -- omit it for a
-- SERVER-ONLY capture, where this side is UI-only (it still shows the Start button + countdown and
-- fires the go-signal, it just doesn't record locally).

local MAX_SECONDS = 30        -- recording-window cap (matches debug_record)
local DEFAULT_COUNTDOWN = 3   -- seconds; time to move hands to the keyboard after clicking Start
local MAX_COUNTDOWN = 10
local FLAGGED_CAP = 200       -- max flagged-fire context rows kept for the dump
local DEFAULT_READ_WAIT = 45  -- debug_record_read default block, under the host's 60s ceiling
local READ_MAX_WAIT = 55
local RECORD_TTL = 300        -- reap a terminal (finished/cancelled) record left unread this long

MCP._irec = MCP._irec or {}       -- handle -> record; one interactive recorder at a time (one screen)
MCP._irecByLink = MCP._irecByLink or {} -- link_id -> record, so a linked read resolves by link_id

-- Fire the non-code "go at CurTime X" signal to the paired server recorder (linked sessions only),
-- timed a countdown into the future so the server starts recording exactly as this countdown ends.
local function sendGo(r)
    if r.linkId and MCP.irec and MCP.irec.SendGo then
        MCP.irec.SendGo(r.linkId, CurTime() + r.countdown)
    end
end

-- Fonts are created lazily on first arm, never at file-load -- keeps registration bare for the
-- headless tool-list generator (which has no `surface`). Idempotent to recreate.
local fontsReady = false
local function ensureFonts()
    if fontsReady then return end
    surface.CreateFont("mcp_rec_huge", { font = "Roboto", size = 150, weight = 800 })
    surface.CreateFont("mcp_rec_big",  { font = "Roboto", size = 34,  weight = 700 })
    surface.CreateFont("mcp_rec_med",  { font = "Roboto", size = 26,  weight = 600 })
    fontsReady = true
end

local function forget(r)
    MCP._irec[r.handle] = nil
    if r.linkId then MCP._irecByLink[r.linkId] = nil end
end

local function removeHooks(r)
    if r.hookPoint then hook.Remove(r.hookPoint, r.sampleId) end -- no sample hook in UI-only mode
    hook.Remove("Think", r.thinkId)
    hook.Remove("HUDPaint", r.hudId)
end

-- Cancel (Start popup cancelled, or superseded by a new arm): stop the live hooks and mark the
-- record cancelled. Left in the registry so a pending read resolves as "cancelled" rather than
-- "unknown"; reaped later by TTL.
local function cancelRecord(r)
    if r.phase == "finished" or r.phase == "cancelled" then return end
    r.phase = "cancelled"
    r.finishedAt = RealTime()
    removeHooks(r)
    if IsValid(r.query) then r.query:Remove() end
    notification.AddLegacy("Recording cancelled", NOTIFY_ERROR, 3)
end

-- User clicked Done: snapshot this attempt, stop the live hooks, keep the record for the read to
-- collect. UI-only (server-only) sessions have no local series -- just the ct window + status.
local function finishRecord(r)
    if r.sampler then
        r.result = r.sampler:Result()
        r.result.flags = r.flags
        r.result.flagged = r.flagged
        if r.flags > #r.flagged then r.result.flagged_truncated = true end
        notification.AddLegacy("Recording accepted (" .. #r.sampler.buffer .. " samples) -- returned to agent", NOTIFY_GENERIC, 4)
    else
        r.result = { ui_only = true, reason = "duration", samples = {}, sample_count = 0, returned = 0, downsampled = false }
        notification.AddLegacy("Window done -- server capture returned to agent", NOTIFY_GENERIC, 4)
    end
    r.result.attempts = r.attempts
    r.result.ct_start = r.ctStart
    r.result.ct_end = r.ctEnd
    r.phase = "finished"
    r.finishedAt = RealTime()
    removeHooks(r)
end

-- User clicked Retry: discard this attempt and re-run the countdown -> record cycle (re-firing the
-- go-signal for a linked server side). Fresh buffers/state happen at the countdown -> record boundary.
local function retryRecord(r)
    r.armedAt = SysTime()
    r.phase = "countdown"
    sendGo(r)
end

local function openReview(r)
    local head
    if r.sampler then
        local n = #r.sampler.buffer
        if r.sampler.doneReason == "error" then
            -- A crashing sample/stop ends recording at once; say so, or the popup looks like a
            -- mysterious instant exit. The full error still rides back through debug_record_read.
            head = "SAMPLE ERROR -- recording aborted after " .. n .. " samples:\n" .. tostring(r.sampler.doneErr)
        else
            local flagLine = r.flagFn and ("\n" .. r.flags .. " flags.") or ""
            head = "Recorded " .. n .. " samples." .. flagLine
        end
    else
        head = "Server-capture window complete."
    end
    r.query = Derma_Query(
        head .. "\n\nAccept this recording, or retry?",
        r.title or "MCP interactive recorder",
        "Done",  function() finishRecord(r) end,
        "Retry", function() retryRecord(r) end)
end

-- Reap terminal records left unread past their TTL, and cancel any still-live recorder (only one
-- makes sense on a single screen) before a new arm.
local function sweep()
    for _, r in pairs(MCP._irec) do
        local terminal = r.phase == "finished" or r.phase == "cancelled"
        if terminal then
            if r.finishedAt and (RealTime() - r.finishedAt) > RECORD_TTL then
                removeHooks(r)
                forget(r)
            end
        else
            cancelRecord(r)
        end
    end
end

MCP:AddFunction({
    id = "debug_record_interactive",
    requires = { "unsafe" },
    description = "ARM an on-screen, player-driven recorder for a repro the user must physically perform (walk a path, time a portal crossing, mash a seam) -- the interactive sibling of debug_record. Returns a `handle` IMMEDIATELY; the whole flow then plays out in-game: a Start/Cancel confirm popup, a 3-2-1 countdown (time to grab the keyboard), a live \"REC\" HUD showing seconds-remaining + sample count + an optional red flag counter + a live readout of the value you're measuring, then a Done/Retry gate so a botched attempt is re-run in-game with no round-trip. Collect the series afterwards with debug_record_read (it blocks until the user clicks Done). Two-call by design: the human's timing on the popup is unbounded, and a single blocking tool call is capped at 60s. The sampling core is shared verbatim with debug_record, so all its args behave identically: `hook` is the client event to sample (CreateMove, SetupMove, Think, HUDPaint, PreDrawOpaqueRenderables, any hook name); `sample` is a Lua function body receiving a shared `state` table then the hook args as `...`, returning the value to record (number/string/table; return nothing to skip a fire); `stop`, `init`, `interval`, `stats`, `histogram`, `max_samples` all match debug_record. `seconds` is the recording window AFTER the countdown (max 30). Each row is auto-tagged with `ct` (CurTime, the shared tick clock). Interactive-only knobs: `countdown` (default 3; 0 skips it), `confirm` (default true; false skips the Start popup and begins the countdown at once, for an agent-driven \"go now\"), `title` and `ready_text` (the popup title and the on-screen \"get ready\" instruction -- tell the user what to do, e.g. \"WASD only, no mouse\"), `flag` (an extra Lua body like `sample`; every fire it returns truthy increments a live red flag counter and its return is stored as that fire's context in `flagged`, for watching pass/fail happen in real time -- e.g. \"angle flipped this crossing\"), and `hud` (a Lua body returning a short string rendered live under the REC bar each fire; omit to show the last sampled value). PAIRED SERVER CAPTURE (for a bug that lives in the client/server DISAGREEMENT, e.g. a one-tick predicted-teleport divergence): pass a `link_id` (any unique string) and arm debug_record_interactive on the SERVER realm with the SAME link_id (its `sample` code is armed there through the bridge -- never networked from here). On Start this side fires a non-code, host-gated \"go\" signal so the server records the same window; read the two sides back separately (client first -- it blocks until Done -- then server) and align their rows on `ct`. THREE MODES: (1) client-only = `sample`, no `link_id` (this default); (2) shared = `sample` + `link_id` (both realms record); (3) server-only = `link_id` and NO `sample` -- this side is UI-only (still shows the Start button + countdown + fires the go-signal, records nothing locally). Rides `unsafe` because `sample`/`flag`/`hud`/`stop`/`init` are caller Lua.",
    -- Returns immediately after arming, so the default request timeout is plenty.
    schema = {
        type = "object",
        properties = {
            hook = {
                type = "string",
                description = "Hook event to sample each fire (client realm, e.g. \"CreateMove\", \"SetupMove\", \"Think\", \"HUDPaint\"). Required when `sample` is set. Any name; a never-firing hook just yields an empty series.",
            },
            sample = {
                type = "string",
                description = "Lua function body run each fire; receives the shared `state` table then the hook's arguments as `...`. `return` a value to record (number/string/table); return nothing to skip that fire. Optional only when `link_id` is set (a server-only capture -- omit for a UI-only client).",
            },
            seconds = {
                type = "number",
                description = "Recording window in seconds AFTER the countdown (max 30). Also the hard safety cap. Should match the paired server arm's `seconds`.",
            },
            link_id = {
                type = "string",
                description = "A unique id YOU generate to pair this with a SERVER-realm debug_record_interactive arm (same link_id). Drives a paired server capture: on Start this side fires the go-signal. With a link_id, `sample` may be omitted for a server-only (UI-only) capture. Read the server side back by the same link_id.",
            },
            countdown = {
                type = "number",
                description = "Countdown seconds shown before recording (default 3; 0 skips it). Gives the user time to move hands to the keys after clicking Start, and the paired server the slack to receive the go-signal.",
            },
            confirm = {
                type = "boolean",
                description = "Show the Start/Cancel popup so the user begins when ready (default true). false skips it and starts the countdown immediately (agent-driven \"go now\").",
            },
            title = {
                type = "string",
                description = "Title for the confirm and review popups (e.g. \"Portal crossing recorder\").",
            },
            ready_text = {
                type = "string",
                description = "The \"get ready\" instruction shown in the popup and during the countdown -- tell the user exactly what to do, e.g. \"MOVEMENT KEYS ONLY - no mouse\".",
            },
            flag = {
                type = "string",
                description = "Optional Lua body (like `sample`: `state` then the hook args) evaluated every fire; a truthy return increments a live red \"flags: N\" counter and its value is stored as that fire's context in the returned `flagged` list. For live pass/fail detection (e.g. an angle flip).",
            },
            hud = {
                type = "string",
                description = "Optional Lua body (like `sample`) returning a short string rendered live under the REC bar each fire -- the readout of what you're measuring. Omit to display the last sampled value.",
            },
            stop = {
                type = "string",
                description = "Optional Lua body (`state` + the hook args) checked every fire; recording ends early when it returns truthy.",
            },
            init = {
                type = "string",
                description = "Optional Lua body (with the shared `state` table) run once at the start of each recording attempt (including retries) to seed state.",
            },
            interval = {
                type = "number",
                description = "Throttle: minimum seconds between samples. Default 0 (record every fire). `stop` and `flag` are still evaluated every fire.",
            },
            stats = {
                type = "boolean",
                description = "When true, also return an `aggregate` block (numeric_count/min/max/sum/avg) over the numeric samples at full resolution.",
            },
            histogram = {
                type = "boolean",
                description = "When true, also return a `histogram` -- a distinct-value tally of the samples, for counting categorical outcomes (have `sample` return a short string key).",
            },
            max_samples = {
                type = "integer", minimum = 2, maximum = 500,
                description = "Max points in the returned series (default 100). More are recorded and evenly downsampled on return.",
            },
        },
        required = { "seconds" },
    },
    ---@param args table
    handler = function(args, ctx)
        args = args or {}

        local linkId = (type(args.link_id) == "string" and args.link_id ~= "") and args.link_id or nil
        local hasSample = type(args.sample) == "string" and args.sample ~= ""
        if not hasSample and not linkId then
            return { ok = false, error = "provide `sample` (to record locally) and/or `link_id` (to drive a paired server capture); with neither there's nothing to do" }
        end
        if hasSample and (type(args.hook) ~= "string" or args.hook == "") then
            return { ok = false, error = "`hook` is required when `sample` is set (the client event to sample)" }
        end
        local seconds = tonumber(args.seconds)
        if not seconds then return { ok = false, error = "`seconds` is required (the recording window and safety cap)" } end
        seconds = math.Clamp(seconds, 0.05, MAX_SECONDS)

        local countdown = math.Clamp(tonumber(args.countdown) or DEFAULT_COUNTDOWN, 0, MAX_COUNTDOWN)
        local confirm = args.confirm == nil or (args.confirm and true or false)

        -- Compile the local-capture snippets only when this side records (UI-only skips them).
        local sampler
        ---@type table<string, function>
        local compiled = {}
        if hasSample then
            local sampleFn, serr = MCP.sampler.Compile(args.sample, "mcp_irec_sample")
            if not sampleFn then return { ok = false, error = "`sample` compile error: " .. serr } end
            for _, spec in ipairs({
                { key = "stop", name = "mcp_irec_stop" },
                { key = "init", name = "mcp_irec_init" },
                { key = "flag", name = "mcp_irec_flag" },
                { key = "hud",  name = "mcp_irec_hud" },
            }) do
                local src = args[spec.key]
                if src ~= nil then
                    if type(src) ~= "string" then return { ok = false, error = "`" .. spec.key .. "` must be a Lua string" } end
                    local fn, e = MCP.sampler.Compile(src, spec.name)
                    if not fn then return { ok = false, error = "`" .. spec.key .. "` compile error: " .. e } end
                    compiled[spec.key] = fn
                end
            end
            sampler = MCP.sampler.New({
                sample = sampleFn,
                stop = compiled.stop,
                interval = args.interval,
                max_samples = args.max_samples,
                want_stats = args.stats,
                want_histogram = args.histogram,
                tag_curtime = true,
                decimate_on_full = true, -- time-bounded: keep the whole window, don't end early
            })
        end

        ensureFonts()
        sweep() -- reap old records + cancel any still-live recorder before this one

        MCP._irecSeq = (MCP._irecSeq or 0) + 1
        local handle = "mcp_irec_" .. MCP._irecSeq
        local r = {
            handle = handle,
            linkId = linkId,
            phase = "arming",
            sampler = sampler,
            initFn = compiled.init,
            flagFn = compiled.flag,
            hudFn = compiled.hud,
            seconds = seconds,
            countdown = countdown,
            title = type(args.title) == "string" and args.title or nil,
            readyText = type(args.ready_text) == "string" and args.ready_text or nil,
            hookPoint = hasSample and args.hook or nil,
            sampleId = "mcp_irec_s_" .. MCP._irecSeq,
            thinkId = "mcp_irec_t_" .. MCP._irecSeq,
            hudId = "mcp_irec_h_" .. MCP._irecSeq,
            flags = 0,
            flagged = {},
            attempts = 0,
            readout = nil,
        }
        MCP._irec[handle] = r
        if linkId then MCP._irecByLink[linkId] = r end

        -- Sample hook (local capture only): active while recording. Records via the shared sampler,
        -- then updates the live flag counter and HUD readout off the freshly-updated state.
        if r.sampler then
            hook.Add(r.hookPoint, r.sampleId, function(...)
                if r.phase ~= "recording" then return end
                local reason = r.sampler:Fire(...)
                if reason ~= "error" then
                    if r.flagFn then
                        local ok, res = pcall(r.flagFn, r.sampler.state, ...)
                        if ok and res then
                            r.flags = r.flags + 1
                            if #r.flagged < FLAGGED_CAP then
                                r.flagged[#r.flagged + 1] = {
                                    t = math.Round(RealTime() - r.sampler.start, 3),
                                    ct = math.Round(CurTime(), 3),
                                    v = MCP.util.Serialize(res, { max_depth = 4, max_nodes = 40 }),
                                }
                            end
                        end
                    end
                    if r.hudFn then
                        local ok, txt = pcall(r.hudFn, r.sampler.state, ...)
                        if ok and txt ~= nil then r.readout = tostring(txt) end
                    elseif r.sampler.lastValue ~= nil then
                        r.readout = tostring(r.sampler.lastValue)
                    end
                end
                if reason then r.recEnd = reason end
                -- Never return a value from the hook: don't perturb movement hooks.
            end)
        end

        -- Phase machine: countdown -> recording -> review. Wall-clock timing on SysTime (CurTime
        -- misbehaves inside prediction); ct is captured at the window edges for cross-realm align.
        hook.Add("Think", r.thinkId, function()
            if r.phase == "countdown" then
                if SysTime() - r.armedAt >= r.countdown then
                    if r.sampler then
                        r.sampler:Reset()
                        r.sampler.state = {}
                        if r.initFn then pcall(r.initFn, r.sampler.state) end
                    end
                    r.flags = 0
                    r.flagged = {}
                    r.readout = nil
                    r.recEnd = nil
                    r.attempts = r.attempts + 1
                    r.recStartedAt = SysTime()
                    r.ctStart = math.Round(CurTime(), 3)
                    r.phase = "recording"
                end
            elseif r.phase == "recording" then
                if r.recEnd or (SysTime() - r.recStartedAt >= r.seconds) then
                    r.ctEnd = math.Round(CurTime(), 3)
                    r.phase = "review"
                    openReview(r)
                end
            end
        end)

        -- HUD: draws off the record's phase + timers. Nothing during arming/review (Derma owns
        -- those) or after finish.
        hook.Add("HUDPaint", r.hudId, function()
            local h, cx = ScrH(), ScrW() * 0.5
            if r.phase == "countdown" then
                local rem = math.ceil(r.countdown - (SysTime() - r.armedAt))
                draw.SimpleText(r.readyText or "GET READY", "mcp_rec_med", cx, h * 0.30, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                draw.SimpleText(math.max(rem, 0), "mcp_rec_huge", cx, h * 0.5, Color(255, 220, 0), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            elseif r.phase == "recording" then
                local rem = math.ceil(r.seconds - (SysTime() - r.recStartedAt))
                surface.SetDrawColor(190, 0, 0, 235)
                surface.DrawRect(cx - 175, h * 0.06, 350, 58)
                if r.sampler then
                    local n = #r.sampler.buffer
                    draw.SimpleText("\226\151\143 REC  " .. math.max(rem, 0) .. "s   [" .. n .. "]", "mcp_rec_med", cx, h * 0.06 + 29, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                    local y = h * 0.06 + 80
                    if r.flagFn then
                        local fc = r.flags > 0 and Color(255, 60, 60) or Color(0, 255, 120)
                        draw.SimpleText("flags: " .. r.flags, "mcp_rec_big", cx, y, fc, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                        y = y + 44
                    end
                    if r.readout then
                        draw.SimpleText(r.readout, "mcp_rec_med", cx, y, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                    end
                else
                    draw.SimpleText("\226\151\143 REC (server)  " .. math.max(rem, 0) .. "s", "mcp_rec_med", cx, h * 0.06 + 29, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                end
            end
        end)

        if confirm then
            r.phase = "arming"
            local body = (r.readyText and (r.readyText .. "\n\n") or "") ..
                countdown .. "s countdown, then records " .. seconds .. "s."
            r.query = Derma_Query(body, r.title or "MCP interactive recorder",
                "Start",  function() r.armedAt = SysTime() r.phase = "countdown" sendGo(r) end,
                "Cancel", function() cancelRecord(r) end)
        else
            r.armedAt = SysTime()
            r.phase = "countdown"
            sendGo(r)
        end

        local note = "Interactive recorder shown in-game. " ..
            (confirm and "The user clicks Start when ready, " or "Countdown starting now; ") ..
            "then a " .. countdown .. "s countdown runs and it records for " .. seconds ..
            "s while they perform the repro, then they click Done (accept) or Retry (re-attempt). " ..
            "Call debug_record_read with this handle to collect the series -- it blocks until Done."
        if linkId then
            note = note .. " LINKED: this fires the go-signal to the server recorder \"" .. linkId ..
                "\"; read the client side (this handle) FIRST, then debug_record_read on the SERVER realm by link_id, and align rows on `ct`."
        end

        return {
            ok = true,
            realm = MCP.util.RealmName(),
            handle = handle,
            link_id = linkId,
            mode = hasSample and (linkId and "shared" or "client-only") or "server-only",
            status = r.phase,
            seconds = seconds,
            countdown = countdown,
            note = note,
        }
    end,
})

-- Collect a finished record: build the response from the snapshot and drop the record.
local function collect(r)
    forget(r)
    local res = {
        ok = r.result.reason ~= "error",
        status = "ok",
        realm = MCP.util.RealmName(),
        handle = r.handle,
        link_id = r.linkId,
        hook = r.hookPoint,
    }
    for k, v in pairs(r.result) do res[k] = v end
    return res
end

MCP:AddFunction({
    id = "debug_record_read",
    description = "Collect the series from a debug_record_interactive recorder. Identify it by the `handle` it returned, or by the shared `link_id`. Blocks up to `wait` seconds for the user to click Done, then returns the recorded series in the same shape as debug_record (samples, each tagged with `ct`, plus aggregate/histogram when requested) with the interactive extras `flags`, `flagged` (per-flag context), `attempts`, and `ct_start`/`ct_end`. A UI-only (server-only) session returns `ui_only` with just the ct window. If the user is still setting up or recording when `wait` elapses, returns status \"pending\" with the current `phase` -- just call again (their timing is unbounded, and they may Retry as many times as they like before accepting). Returns status \"cancelled\" if they dismissed the popup. For a LINKED capture, read THIS (client) side first (it blocks until Done), then debug_record_read on the SERVER realm by the same link_id, and align rows on `ct`. Ungated: it only reads a buffer that debug_record_interactive (which is `unsafe`-gated) already captured.",
    timeout = READ_MAX_WAIT + 3,
    schema = {
        type = "object",
        properties = {
            handle = {
                type = "string",
                description = "The recorder handle returned by debug_record_interactive.",
            },
            link_id = {
                type = "string",
                description = "Alternatively, the shared link_id of a paired capture (resolves the same client-side recorder).",
            },
            wait = {
                type = "number",
                description = "Max seconds to block waiting for the user to click Done (default 45, max 55). 0 polls once and returns the current phase immediately.",
            },
        },
    },
    ---@param args table
    handler = function(args, ctx)
        args = args or {}
        local handle = (type(args.handle) == "string" and args.handle ~= "") and args.handle or nil
        local linkId = (type(args.link_id) == "string" and args.link_id ~= "") and args.link_id or nil
        local r = (handle and MCP._irec[handle]) or (linkId and MCP._irecByLink[linkId]) or nil
        if not r then
            return { ok = false, error = "unknown or expired recorder; pass the `handle` from debug_record_interactive or the shared `link_id`" }
        end

        local function terminalResponse()
            if r.phase == "finished" then return collect(r) end
            forget(r)
            return { ok = true, status = "cancelled", realm = MCP.util.RealmName(), handle = r.handle, link_id = r.linkId }
        end
        local function pendingResponse()
            return {
                ok = true,
                status = "pending",
                realm = MCP.util.RealmName(),
                handle = r.handle,
                link_id = r.linkId,
                phase = r.phase,
                attempts = r.attempts,
                sample_count = r.sampler and #r.sampler.buffer or 0,
                flags = r.flags or 0,
                note = "The user hasn't accepted a recording yet (phase: " .. r.phase .. "). Call debug_record_read again to keep waiting.",
            }
        end

        if r.phase == "finished" or r.phase == "cancelled" then return terminalResponse() end

        local wait = math.Clamp(tonumber(args.wait) or DEFAULT_READ_WAIT, 0, READ_MAX_WAIT)
        if wait <= 0 then return pendingResponse() end

        MCP:RunFor({
            seconds = wait,
            stop = function() return r.phase == "finished" or r.phase == "cancelled" end,
        }, function()
            if r.phase == "finished" or r.phase == "cancelled" then
                ctx.respond(terminalResponse())
            else
                ctx.respond(pendingResponse())
            end
        end)

        return ctx.deferred
    end,
})
