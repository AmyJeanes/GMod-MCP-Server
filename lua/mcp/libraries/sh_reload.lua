-- Hot reload: clears the registry and re-runs LoadFolder, then re-emits the manifest.
-- Bound to the `mcp_reload` console command. Server-issued reloads broadcast
-- a net message so clients reload too.

if SERVER then
    util.AddNetworkString("MCP_ClientReload")
end

function MCP:Reload()
    self._generation = (self._generation or 0) + 1
    self._functions = {}
    self._capabilities = {}

    self:LoadFolder("libraries/libraries")
    self:LoadFolder("libraries")
    self:LoadFolder("functions")

    -- Restart the bridge so any change to the polling mechanism takes effect.
    self:StopBridge()
    self:StartBridge()

    print("[MCP] Reloaded (" .. MCP.util.RealmName() .. "); manifest re-emitted, bridge restarted.")
end

if SERVER then
    concommand.Add("mcp_reload", function(ply)
        if IsValid(ply) and not ply:IsSuperAdmin() then
            ply:ChatPrint("[MCP] mcp_reload requires superadmin.")
            return
        end
        MCP:Reload()
        net.Start("MCP_ClientReload")
        net.Broadcast()
    end)
else
    net.Receive("MCP_ClientReload", function()
        MCP:Reload()
    end)
end
