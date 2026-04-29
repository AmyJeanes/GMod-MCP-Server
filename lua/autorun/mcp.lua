-- GMod MCP Server bootstrap
-- https://github.com/AmyJeanes/GMod-MCP-Server

MCP = MCP or {}

function MCP:LoadFolder(folder, addonly, noprefix)
    local base
    if folder then
        base = "mcp/" .. folder .. "/"
    else
        base = "mcp/"
    end

    local files = file.Find(base .. "*.lua", "LUA")
    for _, plugin in ipairs(files) do
        if noprefix then
            if SERVER then
                AddCSLuaFile(base .. plugin)
            end
            if not addonly then
                include(base .. plugin)
            end
        else
            local prefix = string.Left(plugin, string.find(plugin, "_") - 1)
            if (CLIENT and (prefix == "sh" or prefix == "cl")) then
                if not addonly then
                    include(base .. plugin)
                end
            elseif (SERVER) then
                if (prefix == "sv" or prefix == "sh") and (not addonly) then
                    include(base .. plugin)
                end
                if (prefix == "sh" or prefix == "cl") then
                    AddCSLuaFile(base .. plugin)
                end
            end
        end
    end
end

file.CreateDir("mcp")

MCP._generation = MCP._generation or 0

MCP:LoadFolder("libraries/libraries")
MCP:LoadFolder("libraries")
MCP:LoadFolder("functions")

-- Bridge polling starts unconditionally so MCP requests always get a fast,
-- structured response — even when `mcp_enable` is 0 (user hasn't consented yet).
-- Tool dispatch itself is gated inside MCP:Dispatch.
timer.Simple(0, function()
    if MCP and MCP.StartBridge then
        MCP:StartBridge()
    end
end)
