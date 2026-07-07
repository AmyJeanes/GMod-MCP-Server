-- Cross-realm coordination for the interactive recorder's paired capture (debug_record_interactive
-- on both realms). The ONLY thing that ever crosses realms is a non-code "go at CurTime X" signal
-- plus the shared link id -- the sample CODE is armed separately on each realm through the trusted
-- MCP bridge (unsafe-gated per realm), so client-authored Lua is NEVER networked to the server
-- (that would be a client->server RCE, bypassing the capability gate entirely). Host-gated too: the
-- server honours the go-signal only from the listen-server host, so a remote player can't even
-- mistime a recording.
--
-- Lives in libraries/ (not functions/) so the headless README tool-list generator -- which only
-- loads functions/ + three framework files -- never runs util.AddNetworkString / net at load, the
-- same reason sh_reload.lua sits here.

MCP.irec = MCP.irec or {}

if SERVER then
    util.AddNetworkString("MCP_IRecGo")

    -- Client -> server: "recorder <link_id> begins at CurTime <go_time>". We look up the recorder
    -- the server tool armed for that link and hand off to its drive loop; an unknown link (or a
    -- non-host sender) is a silent no-op. Signal only -- no code is read off the wire.
    net.Receive("MCP_IRecGo", function(_, ply)
        if not (IsValid(ply) and ply:IsListenServerHost()) then return end
        local linkId = net.ReadString()
        local goTime = net.ReadDouble()
        local rec = MCP._irecSv and MCP._irecSv[linkId]
        if rec and MCP.irec.ServerScheduleGo then
            MCP.irec.ServerScheduleGo(rec, goTime)
        end
    end)
else
    -- Server-bound go-signal from the host client. goTime is a CurTime() a countdown into the
    -- future, so the server has the whole countdown to receive this and be ready to start on time.
    ---@param linkId string
    ---@param goTime number
    function MCP.irec.SendGo(linkId, goTime)
        net.Start("MCP_IRecGo")
        net.WriteString(linkId)
        net.WriteDouble(goTime)
        net.SendToServer()
    end
end
