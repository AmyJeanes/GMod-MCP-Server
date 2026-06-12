-- Passive capture: records Lua errors and console output (print/Msg/MsgN/MsgC)
-- that happen OUTSIDE a tool call — hooks firing, timers, autorefresh re-runs,
-- the async tail of a deferred handler, other addons — so the model can see
-- them. captureRun in sh_module.lua already covers output produced *during* a
-- handler; this fills the gap for everything else.
--
-- Events land in a bounded in-memory ring (per realm — server and client are
-- separate Lua states). They reach the model two ways, both over the existing
-- file bridge: attached to the next tool response (sh_filebridge.lua) and via
-- the console_read tool (sh_console_read.lua). No .NET side, no push.
--
-- Capture only runs while mcp_enable is 1; mcp_capture (0/1/2) is the scope knob.

local MAX_EVENTS = 200

MCP._events = MCP._events or {}        -- ring of { seq, time, kind, text }
MCP._eventSeq = MCP._eventSeq or 0     -- process-monotonic; survives mcp_reload

-- Append an event to the ring. Source gating (mcp_enable/level) is handled by
-- what's installed in ApplyCaptureState; this stays cheap and guards only
-- against the two ways it could double-count or recurse.
function MCP:RecordEvent(kind, text)
    -- Output produced synchronously inside a handler is already captured by
    -- captureRun and attached to that response; don't also log it here.
    if MCP._inDispatch then return end
    if MCP._recording then return end

    text = tostring(text)
    -- Skip the framework's own console lines (bridge logs, pause-guard, dispatch
    -- logger) so capture doesn't echo itself.
    if string.sub(text, 1, 5) == "[MCP]" then return end

    MCP._recording = true
    MCP._eventSeq = MCP._eventSeq + 1
    local events = MCP._events
    events[#events + 1] = {
        seq = MCP._eventSeq,
        time = RealTime(),
        kind = kind,
        text = text,
    }
    while #events > MAX_EVENTS do
        table.remove(events, 1)
    end
    MCP._recording = false
end

-- Returns events with seq > sinceSeq, the current max seq (to use as the next
-- cursor), and whether anything between the cursor and the oldest retained
-- event was evicted. A sinceSeq beyond the max (e.g. a stale cursor after a
-- GMod restart reset the counter) is treated as "from the start".
function MCP:DrainEventsSince(sinceSeq)
    if not isnumber(sinceSeq) then sinceSeq = 0 end
    local maxSeq = MCP._eventSeq or 0
    if sinceSeq > maxSeq then sinceSeq = 0 end

    local events = MCP._events
    local out = {}
    for _, e in ipairs(events) do
        if e.seq > sinceSeq then out[#out + 1] = e end
    end

    local oldest = events[1] and events[1].seq or (maxSeq + 1)
    local dropped = sinceSeq > 0 and (sinceSeq + 1) < oldest
    return out, maxSeq, dropped
end

-- Current high-water seq. Used to start a new session's attach cursor at "now"
-- so it doesn't replay the existing backlog (possibly another session's).
function MCP:CurrentEventSeq()
    return MCP._eventSeq or 0
end

-- Console detours are installed once and left in place (never restored): tearing
-- down a global detour would clobber any addon that wrapped us afterwards. They
-- self-gate on MCP._captureConsole, so when capture is off the cost is a single
-- branch. State they read (MCP._captureConsole/_inDispatch, MCP:RecordEvent) goes
-- through the MCP table so mcp_reload picks up fresh logic; the originals are
-- captured as upvalues (they never change, and the guard means this body runs
-- once even across reload, so the persisted closures keep these upvalues).
function MCP:InstallConsoleDetours()
    if MCP._detoursInstalled then return end
    MCP._detoursInstalled = true

    -- Saved engine originals — the detours call these so they don't recurse.
    ---@type table<string, function>
    local engine = { print = print, Msg = Msg, MsgN = MsgN, MsgC = MsgC }

    local function joined(sep, ...)
        local parts = { ... }
        for i, v in ipairs(parts) do parts[i] = tostring(v) end
        return table.concat(parts, sep)
    end

    function _G.print(...)
        if MCP._captureConsole and not MCP._inDispatch then
            MCP:RecordEvent("print", joined("\t", ...))
        end
        return engine.print(...)
    end
    function _G.Msg(...)
        if MCP._captureConsole and not MCP._inDispatch then
            MCP:RecordEvent("msg", joined("", ...))
        end
        return engine.Msg(...)
    end
    function _G.MsgN(...)
        if MCP._captureConsole and not MCP._inDispatch then
            MCP:RecordEvent("msg", joined("", ...))
        end
        return engine.MsgN(...)
    end
    function _G.MsgC(color, ...)
        if MCP._captureConsole and not MCP._inDispatch then
            MCP:RecordEvent("msg", joined("", ...))
        end
        return engine.MsgC(color, ...)
    end
end

-- Single source of truth for what's installed. Reconciles the OnLuaError hook
-- and console detours against (mcp_enable AND mcp_capture). Idempotent.
function MCP:ApplyCaptureState()
    local enableCv = GetConVar("mcp_enable")
    local captureCv = GetConVar("mcp_capture")
    local enabled = enableCv and enableCv:GetBool() or false
    local level = captureCv and captureCv:GetInt() or 0
    local active = enabled and level >= 1

    if active then
        hook.Add("OnLuaError", "MCP_PassiveCapture", function(err)
            MCP:RecordEvent("error", err)
        end)
    else
        hook.Remove("OnLuaError", "MCP_PassiveCapture")
    end

    MCP._captureConsole = active and level >= 2
    if MCP._captureConsole then
        MCP:InstallConsoleDetours()
    end
end

-- Re-apply only when mcp_enable/mcp_capture actually changed. Driven from the
-- bridge poll loop rather than a cvar change-callback: on the CLIENT these
-- convars are restored from config before Lua runs, so they aren't Lua-created
-- and `cvars.AddChangeCallback` never fires for them. Polling the value is
-- realm-agnostic and costs two convar reads per poll.
function MCP:ReconcileCapture()
    local en = GetConVar("mcp_enable")
    local cap = GetConVar("mcp_capture")
    local sig = (en and en:GetBool() and "1" or "0") .. ":" .. (cap and cap:GetInt() or 0)
    if sig ~= MCP._captureSig then
        MCP._captureSig = sig
        MCP:ApplyCaptureState()
    end
end
