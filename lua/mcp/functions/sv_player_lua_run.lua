-- player_lua_run: run caller Lua on a target player's CLIENT and return the result.
--
-- The client-realm counterpart to lua_run_cl -- but lua_run_cl only reaches the host's own client
-- (which shares the MCP bridge dir). A remote client shares no bridge, so the request enters the
-- server realm (hence _sv) and hops server->client over net. The code push and result return live
-- in libraries/sh_luarun_net.lua; this tool resolves the target, sends, and waits for the reply.
--
-- Same unsafe gate as lua_run: it runs arbitrary caller Lua. Doing so on another player's client is
-- standard server-operator power (ply:SendLua does the same); the host's `unsafe` grant is consent.

local TIMEOUT = 12 -- reply-wait cap; keep < the declared per-tool timeout below

MCP:AddFunction({
    id = "player_lua_run",
    timeout = TIMEOUT + 3,
    description = "Compile and execute Lua source on a target player's client realm and return the result. Select the target with exactly one of name/userid/entindex/steamid; bots have no client and are rejected. Use `return <expr>` to get a value back (structured, same as lua_run); any print/Msg output during the run comes back in `output`. This is the remote-client counterpart to lua_run_cl, which only reaches the host's own client: the server pushes the code to the target over the network and waits for the reply. Reports `reason` (\"result\" = client replied, \"timeout\" = no reply within the cap, \"gone\" = target disconnected).",
    schema = {
        type = "object",
        properties = {
            code = { type = "string", description = "Lua source to execute on the target client. Use `return <expr>` to capture a value." },
            name = { type = "string", description = "Target by player name (partial match allowed when unambiguous)." },
            userid = { type = "number", description = "Target by UserID()." },
            entindex = { type = "number", description = "Target by entity index." },
            steamid = { type = "string", description = "Target by SteamID (STEAM_0:1:23...) or SteamID64." },
        },
        required = { "code" },
    },
    requires = { "unsafe" },
    asyncable = true,
    handler = function(args, ctx)
        local code = args.code
        if type(code) ~= "string" or code == "" then
            return { ok = false, error = "missing or non-string `code` argument" }
        end

        -- Compile-check on the server so a syntax error fails fast, before we push anything.
        local chk = CompileString(code, "mcp_player_lua_run_check", false)
        if type(chk) == "string" then
            return { ok = false, error = "compile error: " .. chk }
        end

        local players, err = MCP.player.Resolve(args, { allow_all = false })
        if not players then return { ok = false, error = err } end
        local ply = players[1] --[[@as Player]]
        if not IsValid(ply) then return { ok = false, error = "target player is not valid" } end
        if ply:IsBot() then return { ok = false, error = "target is a bot; bots have no client Lua state" } end

        local identity = MCP.player.Identity(ply)

        local token = MCP.luarun.Send(ply, code, function(payload)
            payload.reason = "result"
            payload.target = identity
            ctx.respond(payload)
        end)

        -- Timeout / disconnect fallback: stop as soon as the reply clears the pending entry (the net
        -- handler responded) or the target goes invalid. ctx.respond is single-shot, so a reply that
        -- lands first wins and this is a no-op.
        local cancelWait = MCP:RunFor({
            seconds = TIMEOUT,
            stop = function()
                return not (MCP._luarunPending and MCP._luarunPending[token]) or not IsValid(ply)
            end,
        }, function()
            if not (MCP._luarunPending and MCP._luarunPending[token]) then return end
            MCP.luarun.Cancel(token)
            local gone = not IsValid(ply)
            ctx.respond({
                ok = false,
                reason = gone and "gone" or "timeout",
                error = gone and "target disconnected before replying"
                    or ("no reply from client within " .. TIMEOUT .. "s"),
                target = identity,
            })
        end)
        ctx.onCancel(function()
            cancelWait()
            MCP.luarun.Cancel(token)
        end)

        return ctx.deferred
    end,
})
