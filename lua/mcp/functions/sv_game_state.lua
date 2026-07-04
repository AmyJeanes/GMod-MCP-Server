-- game_state: one read of server-wide state -- map, gamemode, host/dedicated, player slots
-- and a lean player roster -- plus a `tuning` block echoing the current values of game_set's
-- knobs, so the read/write pair shares one surface. Replaces the hand-rolled game.GetMap /
-- SinglePlayer / MaxPlayers / IsListenServerHost-loop / player.GetCount idioms the scan found
-- across every addon. Server realm (these are server-authoritative facts). The read-half
-- paired with game_set. Read-only/ungated.

MCP:AddFunction({
    id = "game_state",
    description = "Structured snapshot of server-wide game state in one read -- current map, gamemode, hostname, singleplayer/dedicated flags, max player slots, player/bot/human counts, a lean roster of every player (name/userid/entindex/is_bot/is_host/team -- drill into one with player_state or entity_state), a `tuning` block with the live values of game_set's knobs (gravity, timescale, phys_timescale, fakelag), and `cheats_enabled` (sv_cheats) -- which gates whether game_set's timescale/fakelag will take. `cheats_enabled` is read-only here AND everywhere on a running game: sv_cheats is blocklisted from every Lua/console path, so it can't be flipped mid-session via the bridge -- enable it either by typing `sv_cheats 1` in the in-game console, or by relaunching with host_launch `cheats=true` (the `+sv_cheats 1` command-line arg is honored at startup). The read-half paired with game_set (which writes the tuning knobs). Read-only.",
    schema = {
        type = "object",
        properties = {},
    },
    handler = function()
        local all = player.GetAll()
        local roster = {}
        for _, p in ipairs(all) do
            local id = MCP.player.Identity(p)
            id.team = p:Team()
            roster[#roster + 1] = id
        end

        local tuning = {}
        for name, def in pairs(MCP.game.KNOBS) do
            local cv = GetConVar(def.convar)
            if cv then tuning[name] = cv:GetFloat() end
        end

        local hostnameCv = GetConVar("hostname")
        local cheatsCv = GetConVar("sv_cheats")

        return {
            ok = true,
            realm = MCP.util.RealmName(),
            map = game.GetMap(),
            gamemode = engine.ActiveGamemode(),
            hostname = hostnameCv and hostnameCv:GetString() or nil,
            singleplayer = game.SinglePlayer(),
            dedicated = game.IsDedicated(),
            maxplayers = game.MaxPlayers(),
            cheats_enabled = cheatsCv and cheatsCv:GetBool() or false,
            player_count = #all,
            bot_count = #player.GetBots(),
            human_count = #player.GetHumans(),
            players = roster,
            tuning = tuning,
        }
    end,
})
