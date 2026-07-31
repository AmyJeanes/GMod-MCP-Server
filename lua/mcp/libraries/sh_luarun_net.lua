-- Cross-realm code push for player_lua_run (functions/sv_player_lua_run.lua): the SERVER pushes
-- caller Lua to a target CLIENT over net, the client runs it and nets the serialized result back.
-- Only server->client ever carries code -- equivalent to the engine's own ply:SendLua, a power the
-- server already holds -- and the return path carries only serialized result DATA, never code. This
-- does NOT breach the client->server no-code rule (see sh_irec_net.lua): that forbids the opposite,
-- dangerous direction (untrusted client -> authoritative server = RCE). The unsafe gate lives on the
-- server tool -- the host's consent to wield server-operator power over a client.
--
-- In libraries/ (not functions/) so the headless README tool-list generator never runs
-- util.AddNetworkString / net at load -- same reason as sh_irec_net.lua and sh_reload.lua.

MCP.luarun = MCP.luarun or {}

local MSG_RUN = "MCP_PlayerLuaRun"          -- server -> client: {token, code}
local MSG_RESULT = "MCP_PlayerLuaRunResult" -- client -> server: {token, compressed json payload}

if SERVER then
    util.AddNetworkString(MSG_RUN)
    util.AddNetworkString(MSG_RESULT)

    -- Calls awaiting a client reply: token -> { ply, onResult }. The token binds a reply to the
    -- exact target, so no other client can resolve someone else's call with a spoofed result.
    MCP._luarunPending = MCP._luarunPending or {}
    MCP._luarunSeq = MCP._luarunSeq or 0 -- monotonic token source; persists across mcp_reload

    ---@param ply Player
    ---@param code string
    ---@param onResult fun(payload: table)
    ---@return string token
    function MCP.luarun.Send(ply, code, onResult)
        MCP._luarunSeq = MCP._luarunSeq + 1
        local token = "plr_" .. MCP._luarunSeq
        MCP._luarunPending[token] = { ply = ply, onResult = onResult }

        net.Start(MSG_RUN)
        net.WriteString(token)
        net.WriteString(code)
        net.Send(ply)
        return token
    end

    ---@param token string
    function MCP.luarun.Cancel(token)
        MCP._luarunPending[token] = nil
    end

    net.Receive(MSG_RESULT, function(_, ply)
        local token = net.ReadString()
        local pending = MCP._luarunPending[token]
        -- Unknown token or a reply from anyone but the addressed client: ignore. The payload is
        -- data we hand back verbatim, never executed, but bind to the target anyway.
        if not pending or pending.ply ~= ply then return end
        MCP._luarunPending[token] = nil

        local len = net.ReadUInt(32)
        local compressed = len > 0 and net.ReadData(len) or ""
        local payload = MCP.util.JsonDecode(util.Decompress(compressed) or "")
        if type(payload) ~= "table" then
            payload = { ok = false, error = "malformed result payload from client" }
        end
        pending.onResult(payload)
    end)
else
    -- select-based capture keeps trailing nils correct (GMod is Lua 5.1, no table.pack).
    ---@param ok boolean
    local function packResults(ok, ...)
        return ok, select("#", ...), { ... }
    end

    -- Run server-pushed Lua in this client's realm, capturing return values and console output.
    -- The result mirrors lua_run's shape; `output` ships print/Msg back because the remote client's
    -- own passive event ring never reaches the host's bridge.
    ---@param code string
    ---@return table
    function MCP.luarun.RunLocal(code)
        local fn = CompileString(code, "mcp_player_lua_run", false)
        if type(fn) == "string" then
            return { ok = false, error = "compile error: " .. fn }
        end

        local output = {}
        local origPrint, origMsg, origMsgN, origMsgC = print, Msg, MsgN, MsgC
        _G.print = function(...)
            local parts = { ... }
            for i, v in ipairs(parts) do parts[i] = tostring(v) end
            output[#output + 1] = table.concat(parts, "\t") .. "\n"
            return origPrint(...)
        end
        _G.Msg = function(...)
            local parts = { ... }
            for i, v in ipairs(parts) do parts[i] = tostring(v) end
            output[#output + 1] = table.concat(parts, "")
            return origMsg(...)
        end
        _G.MsgN = function(...)
            local parts = { ... }
            for i, v in ipairs(parts) do parts[i] = tostring(v) end
            output[#output + 1] = table.concat(parts, "") .. "\n"
            return origMsgN(...)
        end
        ---@param color Color
        _G.MsgC = function(color, ...)
            local parts = { ... }
            for i, v in ipairs(parts) do parts[i] = tostring(v) end
            output[#output + 1] = table.concat(parts, "")
            return origMsgC(color, ...)
        end

        local ok, count, rets = packResults(pcall(fn))

        _G.print, _G.Msg, _G.MsgN, _G.MsgC = origPrint, origMsg, origMsgN, origMsgC
        local captured = #output > 0 and table.concat(output) or nil

        if not ok then
            return { ok = false, error = "runtime error: " .. tostring(rets[1]), output = captured }
        end

        local result
        if count == 1 then
            result = rets[1]
        elseif count > 1 then
            result = {}
            for i = 1, count do result[i] = rets[i] end
        end

        return {
            ok = true,
            returns = count,
            result = MCP.util.Serialize(result),
            output = captured,
        }
    end

    -- net messages only ever come from the server, so there's no sender to authenticate here.
    net.Receive(MSG_RUN, function()
        local token = net.ReadString()
        local code = net.ReadString()
        local payload = MCP.luarun.RunLocal(code)

        local compressed = util.Compress(MCP.util.JsonEncode(payload, false)) or ""
        net.Start(MSG_RESULT)
        net.WriteString(token)
        net.WriteUInt(#compressed, 32)
        net.WriteData(compressed, #compressed)
        net.SendToServer()
    end)
end
