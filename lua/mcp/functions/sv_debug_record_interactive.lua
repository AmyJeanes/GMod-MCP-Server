-- debug_record_interactive (server realm): the paired SERVER half of the interactive recorder.
-- The client half (cl_debug_record_interactive) owns the UI + human timing; this half records the
-- server realm for the same window so a prediction bug that lives in the client/server DISAGREEMENT
-- can be captured. The two are correlated by a caller-generated `link_id` and aligned by `ct`
-- (CurTime, the shared tick clock) -- both samplers run with tag_curtime on.
--
-- Security: the sample CODE is armed here through the trusted MCP bridge (unsafe-gated), NEVER sent
-- from the client. The only thing that crosses realms is a non-code, host-gated "go at CurTime X"
-- signal (sh_irec_net.lua). This tool arms an idle recorder; when the client's Start fires the
-- go-signal, MCP.irec.ServerScheduleGo waits until CurTime hits X, records for `seconds`, and holds
-- the result for debug_record_read (server realm) to collect by `link_id`.

local MAX_SECONDS = 30        -- record-window cap (matches debug_record)
local DEFAULT_READ_WAIT = 45  -- debug_record_read default block, under the host's 60s ceiling
local READ_MAX_WAIT = 55
local RECORD_TTL = 300        -- reap a done/armed recorder left unread this long
local GO_WAIT_CAP = 20        -- give up waiting for CurTime to reach go_time after this (bogus/late go)

MCP.irec = MCP.irec or {}     -- also set in sh_irec_net.lua; guard so the headless generator is safe
MCP._irecSv = MCP._irecSv or {} -- link_id -> server recorder record

local function removeHooks(rec)
    hook.Remove(rec.hookPoint, rec.hookId)
    if rec.driveId then hook.Remove("Think", rec.driveId) end
end

-- Reap done/armed recorders left unread past their TTL, and drop any existing recorder for a link
-- that's being re-armed.
local function sweep(rearmLink)
    for link, rec in pairs(MCP._irecSv) do
        local stale = rec.doneAt and (RealTime() - rec.doneAt) > RECORD_TTL
        local orphan = not rec.doneAt and rec.armedAt and (RealTime() - rec.armedAt) > (RECORD_TTL + GO_WAIT_CAP)
        if link == rearmLink or stale or orphan then
            removeHooks(rec)
            MCP._irecSv[link] = nil
        end
    end
end

-- Drive one recording attempt for `rec`: wait until CurTime reaches go_time, record for `seconds`,
-- then snapshot the result. Called on every go-signal, so a client Retry (a fresh go) supersedes
-- the previous attempt -- the stale drive loop sees rec.driveId change and removes itself.
function MCP.irec.ServerScheduleGo(rec, goTime)
    rec.goTime = goTime
    rec.phase = "waiting"
    rec.recording = false
    rec.result = nil
    rec.waitStart = RealTime()

    MCP._irecSvSeq = (MCP._irecSvSeq or 0) + 1
    local driveId = "mcp_irec_sv_drive_" .. MCP._irecSvSeq
    if rec.driveId then hook.Remove("Think", rec.driveId) end
    rec.driveId = driveId

    local recStart
    hook.Add("Think", driveId, function()
        if rec.driveId ~= driveId then hook.Remove("Think", driveId) return end
        local ct = CurTime()
        if rec.phase == "waiting" then
            if ct >= rec.goTime then
                rec.sampler:Reset() -- start the clock at the recording boundary, not the arm
                rec.sampler.state = {}
                if rec.initFn then pcall(rec.initFn, rec.sampler.state) end
                rec.recording = true
                rec.phase = "recording"
                rec.ctStart = math.Round(ct, 3)
                recStart = RealTime()
            elseif RealTime() - rec.waitStart > GO_WAIT_CAP then
                rec.phase = "done" -- go_time never arrived (bogus/late); resolve empty
                rec.result = rec.sampler:Result()
                rec.result.note = "go_time was not reached within " .. GO_WAIT_CAP .. "s"
                rec.doneAt = RealTime()
                hook.Remove("Think", driveId)
            end
        elseif rec.phase == "recording" then
            if rec.sampler.doneReason or (RealTime() - recStart >= rec.seconds) then
                rec.recording = false
                rec.phase = "done"
                rec.ctEnd = math.Round(CurTime(), 3)
                rec.result = rec.sampler:Result()
                rec.result.ct_start = rec.ctStart
                rec.result.ct_end = rec.ctEnd
                rec.doneAt = RealTime()
                hook.Remove("Think", driveId)
            end
        end
    end)
end

MCP:AddFunction({
    id = "debug_record_interactive",
    requires = { "unsafe" },
    description = "Arm the paired SERVER-realm capture for an interactive recording -- the server half of debug_record_interactive_cl (which owns the on-screen UI and human timing). Records the SERVER realm for the same window so a bug that lives in the client/server DISAGREEMENT (e.g. a one-tick predicted-teleport divergence) can be captured, not just one side. Both halves are correlated by a `link_id` YOU generate (any unique string) and passed to both arms; each sample row is tagged with `ct` (CurTime, the shared tick clock), so you line the two series up on `ct`. This arms an IDLE recorder and returns immediately -- it starts recording when the client's Start button fires a non-code, host-gated \"go\" signal (the client sends the moment recording begins as a future CurTime; this side waits for it, then records for `seconds`). The sample CODE is armed here through the trusted bridge (this is why it's a real server tool and rides `unsafe`), never networked from the client. `hook` is the SERVER event to sample (Think, Tick, StartCommand, PhysicsCollide, EntityTakeDamage, or a custom shared hook like a portal's teleport hook that fires on both realms); `sample`/`stop`/`init`/`interval`/`stats`/`histogram`/`max_samples` behave exactly as in debug_record. `seconds` is the record window (max 30) and should match the client's. Collect with debug_record_read (server realm) by `link_id` -- read the CLIENT first (it blocks until the user clicks Done), THEN the server (whose last window is then the accepted attempt). For CLIENT-ONLY or SERVER-ONLY captures see debug_record_interactive_cl; a server-only capture still needs a client arm (with the same link_id and no `sample`) to give the human the Start button and fire the go-signal.",
    timeout = MAX_SECONDS + 3,
    schema = {
        type = "object",
        properties = {
            link_id = {
                type = "string",
                description = "A unique id YOU generate, shared with the paired debug_record_interactive_cl arm and used to read this side back. Any unique string.",
            },
            hook = {
                type = "string",
                description = "Server-realm hook event to sample (e.g. \"Think\", \"StartCommand\", or a custom shared hook that fires on both realms).",
            },
            sample = {
                type = "string",
                description = "Lua function body run each fire; receives the shared `state` table then the hook's arguments as `...`. `return` a value to record; return nothing to skip. Each row is auto-tagged with `ct` for cross-realm alignment.",
            },
            seconds = {
                type = "number",
                description = "Record window in seconds (max 30). Should match the client arm's `seconds`.",
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
                description = "Throttle: minimum seconds between samples. Default 0 (record every fire).",
            },
            stats = {
                type = "boolean",
                description = "When true, also return an `aggregate` block (numeric_count/min/max/sum/avg) over the numeric samples at full resolution.",
            },
            histogram = {
                type = "boolean",
                description = "When true, also return a `histogram` -- a distinct-value tally, for counting categorical outcomes (have `sample` return a short string key).",
            },
            max_samples = {
                type = "integer", minimum = 2, maximum = 500,
                description = "Max points in the returned series (default 100). More are recorded and evenly downsampled on return.",
            },
        },
        required = { "link_id", "hook", "sample", "seconds" },
    },
    ---@param args table
    handler = function(args, ctx)
        args = args or {}
        local linkId = args.link_id
        if type(linkId) ~= "string" or linkId == "" then
            return { ok = false, error = "`link_id` is required (a unique id shared with the client arm)" }
        end
        if type(args.hook) ~= "string" or args.hook == "" then
            return { ok = false, error = "`hook` must be a non-empty server hook event name (e.g. \"Think\", \"StartCommand\")" }
        end
        if type(args.sample) ~= "string" or args.sample == "" then
            return { ok = false, error = "`sample` must be a non-empty Lua snippet (use `return` to record a value; return nothing to skip a fire)" }
        end
        local seconds = tonumber(args.seconds)
        if not seconds then return { ok = false, error = "`seconds` is required (the record window)" } end
        seconds = math.Clamp(seconds, 0.05, MAX_SECONDS)

        local sampleFn, serr = MCP.sampler.Compile(args.sample, "mcp_irec_sv_sample")
        if not sampleFn then return { ok = false, error = "`sample` compile error: " .. serr } end

        ---@type table<string, function>
        local compiled = {}
        for _, spec in ipairs({
            { key = "stop", name = "mcp_irec_sv_stop" },
            { key = "init", name = "mcp_irec_sv_init" },
        }) do
            local src = args[spec.key]
            if src ~= nil then
                if type(src) ~= "string" then return { ok = false, error = "`" .. spec.key .. "` must be a Lua string" } end
                local fn, e = MCP.sampler.Compile(src, spec.name)
                if not fn then return { ok = false, error = "`" .. spec.key .. "` compile error: " .. e } end
                compiled[spec.key] = fn
            end
        end

        sweep(linkId) -- reap stale recorders + drop any prior arm for this link

        local sampler = MCP.sampler.New({
            sample = sampleFn,
            stop = compiled.stop,
            interval = args.interval,
            max_samples = args.max_samples,
            want_stats = args.stats,
            want_histogram = args.histogram,
            tag_curtime = true,
            decimate_on_full = true, -- time-bounded: keep the whole window, don't end early
        })

        MCP._irecSvSeq = (MCP._irecSvSeq or 0) + 1
        local rec = {
            linkId = linkId,
            sampler = sampler,
            initFn = compiled.init,
            seconds = seconds,
            hookPoint = args.hook,
            hookId = "mcp_irec_sv_s_" .. MCP._irecSvSeq,
            recording = false,
            phase = "armed",
            armedAt = RealTime(),
        }
        MCP._irecSv[linkId] = rec

        -- Sample hook: only active while the drive loop has flipped `recording` on.
        hook.Add(rec.hookPoint, rec.hookId, function(...)
            if not rec.recording then return end
            rec.sampler:Fire(...)
            -- Never return a value from the hook: don't perturb StartCommand/Move etc.
        end)

        return {
            ok = true,
            realm = MCP.util.RealmName(),
            link_id = linkId,
            status = "armed",
            seconds = seconds,
            note = "Server capture armed idle. Arm debug_record_interactive_cl with link_id \"" .. linkId ..
                "\" so the user gets the Start button; on Start it fires the go-signal and this side records for " ..
                seconds .. "s. Collect with debug_record_read (server realm) by link_id -- read the client first (blocks until Done), then this side.",
        }
    end,
})

-- Build the response from a done record's snapshot and clean it up.
local function collect(rec)
    removeHooks(rec)
    MCP._irecSv[rec.linkId] = nil
    local res = {
        ok = rec.result.reason ~= "error",
        status = "ok",
        realm = MCP.util.RealmName(),
        link_id = rec.linkId,
        hook = rec.hookPoint,
    }
    for k, v in pairs(rec.result) do res[k] = v end
    return res
end

MCP:AddFunction({
    id = "debug_record_read",
    description = "Collect the SERVER-realm series from a debug_record_interactive (server) recorder, by `link_id`. Blocks up to `wait` seconds until this side's recording window has completed, then returns the series in the same shape as debug_record (samples, each tagged with `ct`, plus aggregate/histogram when requested and `ct_start`/`ct_end`). READ THE CLIENT SIDE FIRST (debug_record_read on the client realm blocks until the user clicks Done); by the time it returns, this side's last window is the accepted attempt. If the user hasn't triggered a window yet (still on the popup/countdown) when `wait` elapses, returns status \"pending\" with the current phase so you can call again. Align the client and server series by matching rows on `ct` (the shared tick clock). Ungated: it only reads a buffer that debug_record_interactive (which is `unsafe`-gated) already captured.",
    timeout = READ_MAX_WAIT + 3,
    schema = {
        type = "object",
        properties = {
            link_id = {
                type = "string",
                description = "The link_id the paired arms share.",
            },
            wait = {
                type = "number",
                description = "Max seconds to block waiting for this side's window to complete (default 45, max 55). 0 polls once and returns the current phase immediately.",
            },
        },
        required = { "link_id" },
    },
    ---@param args table
    handler = function(args, ctx)
        args = args or {}
        local linkId = args.link_id
        if type(linkId) ~= "string" or linkId == "" then
            return { ok = false, error = "`link_id` is required (the id shared by the paired arms)" }
        end
        local rec = MCP._irecSv[linkId]
        if not rec then
            return { ok = false, error = "unknown or expired server recorder link: " .. linkId }
        end

        local function pendingResponse()
            return {
                ok = true,
                status = "pending",
                realm = MCP.util.RealmName(),
                link_id = linkId,
                phase = rec.phase,
                sample_count = rec.sampler and #rec.sampler.buffer or 0,
                note = "This side hasn't completed a window yet (phase: " .. rec.phase .. "). Read the client side first (it blocks until Done), then call again.",
            }
        end

        if rec.phase == "done" and rec.result then return collect(rec) end

        local wait = math.Clamp(tonumber(args.wait) or DEFAULT_READ_WAIT, 0, READ_MAX_WAIT)
        if wait <= 0 then return pendingResponse() end

        MCP:RunFor({
            seconds = wait,
            stop = function() return rec.phase == "done" and rec.result ~= nil end,
        }, function()
            if rec.phase == "done" and rec.result then
                ctx.respond(collect(rec))
            else
                ctx.respond(pendingResponse())
            end
        end)

        return ctx.deferred
    end,
})
