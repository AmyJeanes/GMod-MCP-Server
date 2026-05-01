-- File-based IPC bridge: polls inbox for requests, dispatches, writes responses.
--
-- Polling runs unconditionally once the addon loads. The `mcp_enable` convar
-- gates *dispatch* (handled in sh_module.lua's MCP:Dispatch), not polling, so
-- MCP requests always get a fast structured response — including a friendly
-- "bridge disabled" message when the user hasn't consented yet.
--
-- Polling is driven by GM:Think on both realms (per-frame, throttled by RealTime).
-- Pause limitation: in singleplayer, engine pause-on-menu freezes ALL server-side
-- hooks, so the SERVER realm's bridge stops polling during pause. We auto-set
-- `sv_pause_sp 0` when `mcp_enable` becomes 1 to keep the server responsive
-- while menus are open, and warn if the user re-enables sv_pause_sp later.

MCP._hookName = "MCP_Bridge_" .. (SERVER and "Server" or "Client")
MCP._lastPoll = MCP._lastPoll or 0

local function inboxDir() return "mcp/" .. MCP.util.RealmName() .. "/in" end
local function outboxDir() return "mcp/" .. MCP.util.RealmName() .. "/out" end

local function writeResponse(reqId, response)
    if not MCP.util.IsSafeId(reqId) then return end
    file.Write(outboxDir() .. "/" .. reqId .. ".json",
        MCP.util.JsonEncode({ id = reqId, result = response }, false))
end

local function processOne(filename)
    local inboxPath = inboxDir() .. "/" .. filename
    local raw = file.Read(inboxPath, "DATA")
    file.Delete(inboxPath)

    if not raw or raw == "" then return end

    local req = MCP.util.JsonDecode(raw)
    if type(req) ~= "table" then return end
    if not MCP.util.IsSafeId(req.id) then return end
    if type(req.function_id) ~= "string" then
        writeResponse(req.id, { ok = false, error = "request missing function_id" })
        return
    end

    -- Bridge-internal health check. Bypasses MCP:Dispatch so it works even when
    -- mcp_enable is 0 — the host's status tool uses this to distinguish
    -- "running but not consented" from "running but unreachable".
    if req.function_id == "_ping" then
        writeResponse(req.id, {
            ok = true,
            enabled = GetConVar("mcp_enable"):GetBool(),
            realm = MCP.util.RealmName(),
        })
        return
    end

    local response = MCP:Dispatch(req.function_id, req.args, function(deferredResponse)
        writeResponse(req.id, deferredResponse)
    end)
    -- Sync handlers return the response directly; deferred handlers return nil
    -- and resolve later via the respondLater callback above.
    if response then
        writeResponse(req.id, response)
    end
end

local function pollTick()
    local now = RealTime()
    local interval = math.max(0.05, GetConVar("mcp_poll_interval"):GetFloat())
    if (now - MCP._lastPoll) < interval then return end
    MCP._lastPoll = now

    local files = file.Find(inboxDir() .. "/*.json", "DATA")
    if not files or #files == 0 then return end
    table.sort(files)

    for _, fname in ipairs(files) do
        local ok, err = pcall(processOne, fname)
        if not ok then
            ErrorNoHalt("[MCP] processOne failed for " .. fname .. ": " .. tostring(err) .. "\n")
        end
    end
end

-- Auto-disable engine menu-pause on the server side when the user has consented
-- to the bridge, so the server's Think hook keeps firing while a player has the
-- menu open. Without this, hitting Esc in singleplayer freezes the server bridge
-- until the player closes the menu.
local function applyPauseGuard()
    if not SERVER then return end
    if not GetConVar("mcp_enable"):GetBool() then return end
    local pauseSp = GetConVar("sv_pause_sp")
    if pauseSp and pauseSp:GetBool() then
        -- RunConsoleCommand rather than :SetBool because sv_pause_sp is an
        -- engine cvar (not Lua-created), and :SetBool refuses those.
        RunConsoleCommand("sv_pause_sp", "0")
        MsgN("[MCP] mcp_enable=1: set sv_pause_sp=0 so the server bridge stays responsive while menus are open.")
        MsgN("[MCP] (Set sv_pause_sp 1 to re-allow menu-pause; the server bridge will then freeze when the menu is open.)")
    end
end

function MCP:StartBridge()
    file.CreateDir("mcp")
    file.CreateDir("mcp/" .. MCP.util.RealmName())
    file.CreateDir(inboxDir())
    file.CreateDir(outboxDir())

    -- Clear leftovers from a previous session so timed-out requests don't ghost-fire.
    for _, dir in ipairs({ inboxDir(), outboxDir() }) do
        for _, fname in ipairs(file.Find(dir .. "/*.json", "DATA") or {}) do
            file.Delete(dir .. "/" .. fname)
        end
    end

    -- Cancel any debounced auto-write scheduled by AddFunction/AddCapability —
    -- we're about to do a fresh synchronous write below.
    if timer.Exists("MCP_ManifestWrite") then timer.Remove("MCP_ManifestWrite") end
    self:WriteManifest()

    hook.Add("Think", self._hookName, pollTick)
    applyPauseGuard()

    print("[MCP] Bridge polling started (" .. MCP.util.RealmName() .. ").")
end

function MCP:StopBridge()
    hook.Remove("Think", self._hookName)
    print("[MCP] Bridge polling stopped (" .. MCP.util.RealmName() .. ")")
end

if SERVER then
    cvars.AddChangeCallback("mcp_enable", function(_, _, new)
        if new == "1" then applyPauseGuard() end
    end, "MCP_PauseGuard")
end
