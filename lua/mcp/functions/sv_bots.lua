-- spawn_bot / remove_bot: manage test bots on a listen server. Bots are the only way to
-- exercise multiplayer behaviour on a listen/SP host; drive them with player_walk_sv.
-- Server-only (bots exist server-side). Ungated -- both are bounded actions, not the
-- arbitrary-code power that `unsafe` gates.

-- Resolve a single target player from name/userid/entindex, and require it to be a bot
-- (remove_bot must never kick a human or the host).
local function resolveBot(args)
    local p
    if args.name ~= nil then
        local want = tostring(args.name)
        for _, q in ipairs(player.GetAll()) do
            if q:Nick() == want then p = q break end
        end
        if not p then
            local lw = string.lower(want)
            local matches = {}
            for _, q in ipairs(player.GetAll()) do
                if string.find(string.lower(q:Nick()), lw, 1, true) then matches[#matches + 1] = q end
            end
            if #matches == 0 then return nil, "no player whose name matches '" .. want .. "'" end
            if #matches > 1 then return nil, "'" .. want .. "' matches several players; be more specific" end
            p = matches[1]
        end
    elseif args.userid ~= nil then
        local uid = tonumber(args.userid)
        if not uid then return nil, "`userid` must be a number" end
        p = Player(uid)
        if not IsValid(p) then return nil, "no player with userid " .. tostring(uid) end
    elseif args.entindex ~= nil then
        local idx = tonumber(args.entindex)
        if not idx then return nil, "`entindex` must be a number" end
        local e = Entity(idx)
        if not IsValid(e) or not e:IsPlayer() then return nil, "entity " .. tostring(idx) .. " is not a valid player" end
        p = e
    end
    if not IsValid(p) then return nil, "could not resolve a target player" end
    if not p:IsBot() then return nil, "target '" .. p:Nick() .. "' is not a bot -- remove_bot only kicks bots" end
    return p
end

MCP:AddFunction({
    id = "spawn_bot",
    description = "Spawn one or more bots on the server (needs a listen server -- maxplayers>1). Each bot is created with player.CreateNextBot and respawned once to clear the first-spawn clientside crouch desync, so it stands correctly. Bots are the only way to test multiplayer behaviour on a listen/SP host; drive them with player_walk_sv. Returns the spawned bots' identities. Server realm.",
    schema = {
        type = "object",
        properties = {
            name = {
                type = "string",
                description = "Base name for the bot(s). Default 'MCPBot'. With count>1, an index is appended (MCPBot1, MCPBot2, ...).",
            },
            count = {
                type = "integer", minimum = 1, maximum = 32,
                description = "How many bots to spawn (default 1). Capped by free player slots (maxplayers - current players).",
            },
        },
    },
    handler = function(args, ctx)
        args = args or {}
        local count = math.floor(tonumber(args.count) or 1)
        if count < 1 then count = 1 end

        local maxp = game.MaxPlayers()
        local cur = #player.GetAll()
        local free = maxp - cur
        if free <= 0 then
            return { ok = false, error = "no free player slots (maxplayers " .. maxp .. ", " .. cur .. " players); bots need a listen server -- relaunch with maxplayers>1" }
        end
        if count > free then
            return { ok = false, error = "can only spawn " .. free .. " more bot(s) (maxplayers " .. maxp .. ", " .. cur .. " players); requested " .. count }
        end

        local base = tostring(args.name or "MCPBot")
        local bots = {}
        for i = 1, count do
            local nm = count > 1 and (base .. i) or base
            local b = player.CreateNextBot(nm)
            if not IsValid(b) then
                return { ok = false, error = "player.CreateNextBot failed after " .. #bots .. " of " .. count .. " (engine/slot limit?)" }
            end
            bots[#bots + 1] = b
        end

        -- A first-spawn player.CreateNextBot bot renders crouched (clientside FL_DUCKING
        -- desync). Respawning it on a LATER tick -- once the initial spawn has settled and the
        -- duck has set in -- clears it on both realms; a same-frame Spawn does not. So wait for
        -- that duck signal, then respawn (event-driven, not a fixed delay -- see timing rules).
        local hookId = "MCP_SpawnBot_" .. tostring(SysTime()) .. "_" .. tostring(math.random(1, 1e9))
        local n, respawned, respawnFrame = 0, false, 0
        hook.Add("Think", hookId, function()
            n = n + 1
            if not respawned then
                local ducked = true
                for _, b in ipairs(bots) do
                    if IsValid(b) and not b:IsFlagSet(FL_DUCKING) then ducked = false break end
                end
                if ducked or n >= 33 then            -- duck has set in (or ~0.5s backstop)
                    for _, b in ipairs(bots) do if IsValid(b) then b:Spawn() end end
                    respawned, respawnFrame = true, n
                end
            elseif n >= respawnFrame + 2 then          -- let the respawn settle, then report
                hook.Remove("Think", hookId)
                local spawned = {}
                for _, b in ipairs(bots) do
                    if IsValid(b) then
                        spawned[#spawned + 1] = { name = b:Nick(), userid = b:UserID(), entindex = b:EntIndex() }
                    end
                end
                ctx.respond({ ok = true, spawned = spawned, count = #spawned, total_bots = #player.GetBots() })
            end
        end)
        return ctx.deferred
    end,
})

MCP:AddFunction({
    id = "remove_bot",
    description = "Remove (kick) bots from the server. Set `all` to remove every bot, or target exactly one with `name`/`userid`/`entindex`. Only ever kicks bots -- a selector resolving to a human or the host is refused. Waits for the disconnect to settle, then returns the bots removed and the remaining bot count. Server realm.",
    schema = {
        type = "object",
        properties = {
            all = { type = "boolean", description = "Remove every bot on the server. Mutually exclusive with name/userid/entindex." },
            name = { type = "string", description = "Remove the bot whose name matches (exact, else case-insensitive contains; must resolve to exactly one bot)." },
            userid = { type = "integer", description = "Remove the bot with this UserID." },
            entindex = { type = "integer", description = "Remove the bot at this entity index." },
        },
    },
    handler = function(args, ctx)
        args = args or {}

        local sel = {}
        if args.all then sel[#sel + 1] = "all" end
        if args.name ~= nil then sel[#sel + 1] = "name" end
        if args.userid ~= nil then sel[#sel + 1] = "userid" end
        if args.entindex ~= nil then sel[#sel + 1] = "entindex" end
        if #sel == 0 then return { ok = false, error = "specify `all` or one of name/userid/entindex" } end
        if #sel > 1 then return { ok = false, error = "specify exactly one of all/name/userid/entindex, got: " .. table.concat(sel, ", ") } end

        local targets = {}
        if args.all then
            for _, b in ipairs(player.GetBots()) do targets[#targets + 1] = b end
            if #targets == 0 then return { ok = false, error = "no bots to remove" } end
        else
            local b, err = resolveBot(args)
            if not b then return { ok = false, error = err } end
            targets[1] = b
        end

        local removed = {}
        local removedEnts = {}
        for _, b in ipairs(targets) do
            removed[#removed + 1] = { name = b:Nick(), userid = b:UserID(), entindex = b:EntIndex() }
            removedEnts[#removedEnts + 1] = b
            b:Kick("MCP remove_bot")
        end

        -- Kick is deferred (the player leaves over the next tick or two), so wait until the
        -- kicked entities are invalid before reporting the settled bot count.
        local hookId = "MCP_RemoveBot_" .. tostring(SysTime()) .. "_" .. tostring(math.random(1, 1e9))
        local deadline = RealTime() + 1
        local fired = false
        local function finish()
            if fired then return end
            fired = true
            hook.Remove("Think", hookId)
            ctx.respond({ ok = true, removed = removed, remaining_bots = #player.GetBots() })
        end
        hook.Add("Think", hookId, function()
            local allGone = true
            for _, e in ipairs(removedEnts) do
                if IsValid(e) then allGone = false break end
            end
            if allGone or RealTime() >= deadline then finish() end
        end)

        return ctx.deferred
    end,
})
