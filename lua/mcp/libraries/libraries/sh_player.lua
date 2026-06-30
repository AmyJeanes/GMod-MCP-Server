-- MCP.player: shared player-subject resolution for the player_* family. Resolves the
-- "which player" selector (host/bot/name/userid/entindex, plus `all`) in one place so
-- each tool stops re-hand-rolling the IsListenServerHost()/IsBot()/find-by-name loops
-- the scan flagged ~20x. Both realms -- every lookup it uses (player.GetAll/GetBots,
-- Player(uid), Entity, IsListenServerHost) is realm-agnostic.
--
-- The headless tool-list generator does not load this file (its framework list is fixed);
-- fine, because tools call MCP.player.* only inside handlers, never at file-load.

MCP.player = MCP.player or {}

local function findHost()
    for _, p in ipairs(player.GetAll()) do
        if p:IsListenServerHost() then return p end
    end
    return nil
end

-- Resolve the subject(s) from exactly one of host/bot/name/userid/entindex/all. Returns
-- (list, err): a single-element list for the singular selectors, the full player list for
-- `all`. With opts.default_host, no selector falls back to the host (the common "me" case
-- for a read tool) instead of erroring. err is set (list nil) on >1 selector or a miss.
function MCP.player.Resolve(args, opts)
    args = args or {}
    opts = opts or {}

    local sel = {}
    if args.host then sel[#sel + 1] = "host" end
    if args.bot then sel[#sel + 1] = "bot" end
    if args.name ~= nil then sel[#sel + 1] = "name" end
    if args.userid ~= nil then sel[#sel + 1] = "userid" end
    if args.entindex ~= nil then sel[#sel + 1] = "entindex" end
    if args.all then sel[#sel + 1] = "all" end

    if #sel > 1 then return nil, "specify exactly one subject, got: " .. table.concat(sel, ", ") end
    if #sel == 0 then
        if not opts.default_host then
            return nil, "specify exactly one subject: host, bot, name, userid, entindex, or all"
        end
        local h = findHost()
        if not h then return nil, "no listen-server host player found; specify bot/name/userid/entindex/all" end
        return { h }
    end

    if args.all then
        return player.GetAll()
    end

    if args.host then
        local h = findHost()
        if not h then return nil, "no listen-server host player found (a dedicated server has none -- target by name/userid)" end
        return { h }
    end

    if args.bot then
        local bots = player.GetBots()
        if #bots == 0 then return nil, "no bots on the server -- spawn one first" end
        if #bots > 1 then
            local names = {}
            for _, p in ipairs(bots) do names[#names + 1] = p:Nick() end
            return nil, "more than one bot; pick with name/userid: " .. table.concat(names, ", ")
        end
        return { bots[1] }
    end

    if args.name ~= nil then
        local want = tostring(args.name)
        for _, p in ipairs(player.GetAll()) do
            if p:Nick() == want then return { p } end
        end
        local lw = string.lower(want)
        local matches = {}
        for _, p in ipairs(player.GetAll()) do
            if string.find(string.lower(p:Nick()), lw, 1, true) then matches[#matches + 1] = p end
        end
        if #matches == 0 then return nil, "no player whose name matches '" .. want .. "'" end
        if #matches > 1 then
            local names = {}
            for _, p in ipairs(matches) do names[#names + 1] = p:Nick() end
            return nil, "'" .. want .. "' matches several players: " .. table.concat(names, ", ")
        end
        return { matches[1] }
    end

    if args.userid ~= nil then
        local uid = tonumber(args.userid)
        if not uid then return nil, "`userid` must be a number" end
        local p = Player(uid)
        if not IsValid(p) then return nil, "no player with userid " .. tostring(uid) end
        return { p }
    end

    local idx = tonumber(args.entindex)
    if not idx then return nil, "`entindex` must be a number" end
    local e = Entity(idx)
    if not IsValid(e) or not e:IsPlayer() then return nil, "entity " .. tostring(idx) .. " is not a valid player" end
    return { e }
end

-- Compact identity block echoed by every player_* tool so a caller can confirm the
-- subject and drill into entity_state via entindex.
function MCP.player.Identity(ply)
    return {
        name = ply:Nick(),
        userid = ply:UserID(),
        entindex = ply:EntIndex(),
        steamid = ply:SteamID(),
        is_bot = ply:IsBot(),
        is_host = ply:IsListenServerHost(),
    }
end
