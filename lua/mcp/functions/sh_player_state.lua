-- player_state: structured snapshot of a player (or all players) -- the player-specific
-- companion to entity_state, which defers eye/aim/duck/anim/weapon here. One read replaces
-- the hand-rolled IsListenServerHost()/EyePos()/Crouching() dumps that recur across every
-- addon. The crouch-desync fields (ducking, crouching, view_offset, hull height,
-- sequence_name) are first-class. Subject is one of host/bot/name/userid/entindex or `all`;
-- no selector defaults to the host. Both realms (_sv server state, _cl client prediction --
-- they legitimately differ for the local player). Read-only/ungated.

-- MCP.util.Getter (pcall getter factory) and MCP.util.DecodeEnum (lazy enum decode) are the
-- shared read-tool primitives; both are define-only/lazy so registration stays generator-safe.

---@param ply Player
local function snapshot(ply)
    local get = MCP.util.Getter(ply)
    local eyeAng = ply:EyeAngles()
    local vel = ply:GetVelocity()

    local r = {
        -- identity
        name = ply:Nick(),
        userid = ply:UserID(),
        entindex = ply:EntIndex(),
        steamid = ply:SteamID(),
        is_bot = ply:IsBot(),
        is_host = ply:IsListenServerHost(),
        team = ply:Team(),
        alive = ply:Alive(),

        -- vitals
        health = get("Health"),
        max_health = get("GetMaxHealth"),
        armor = get("Armor"),

        -- transform / aim
        pos = ply:GetPos(),
        eye_pos = ply:EyePos(),
        eye_angles = eyeAng,
        aim = eyeAng:Forward(),
        velocity = vel,
        speed = vel:Length(),

        -- movement state
        movetype = MCP.util.DecodeEnum("MOVETYPE_", get("GetMoveType")),
        on_ground = get("OnGround"),
        crouching = get("Crouching"),
        ducking = ply:IsFlagSet(FL_DUCKING --[[@as FL]]),
        frozen = ply:IsFlagSet(FL_FROZEN --[[@as FL]]),
        godmode = ply:IsFlagSet(FL_GODMODE --[[@as FL]]),
        water_level = get("WaterLevel"),

        -- view / hull -- the crouch-desync surface
        view_offset = get("GetViewOffset"),
        hull = { mins = ply:OBBMins(), maxs = ply:OBBMaxs() },

        -- model / anim / appearance (colours are normalised 0-1 Vectors, mirroring player_set)
        model = get("GetModel"),
        model_scale = get("GetModelScale"),
        player_color = get("GetPlayerColor"),
        weapon_color = get("GetWeaponColor"),
    }

    local seq = get("GetSequence")
    if isnumber(seq) then
        r.sequence = seq
        local sn = get("GetSequenceName", seq)
        if sn then r.sequence_name = sn end
    end

    local wep = ply:GetActiveWeapon()
    if IsValid(wep) then
        local wget = MCP.util.Getter(wep)
        local aw = { class = wep:GetClass() }
        local c1, c2 = wget("Clip1"), wget("Clip2")
        if isnumber(c1) and c1 >= 0 then aw.clip1 = c1 end
        if isnumber(c2) and c2 >= 0 then aw.clip2 = c2 end
        local pat = wget("GetPrimaryAmmoType")
        if isnumber(pat) and pat >= 0 then
            local cnt = get("GetAmmoCount", pat)
            if isnumber(cnt) then aw.ammo1 = cnt end
        end
        r.active_weapon = aw
    end

    return r
end

MCP:AddFunction({
    id = "player_state",
    description = "Structured snapshot of a player (or all players) -- identity, vitals, eye position/aim, velocity, movement state (movetype, on_ground, crouching, ducking, frozen, godmode, water_level), view offset and collision hull, model/animation sequence, playermodel and weapon colours, and active weapon, in one read. The player-specific companion to entity_state (which defers eye/aim/duck/anim/weapon here); use entity_state via the returned entindex for the generic render/physics fields. Subject is exactly one of `host` (the listen/SP host), `bot` (the sole bot), `name`, `userid`, or `entindex` -- or `all` to snapshot every player (returns a `players` array). With no selector it defaults to the host. Runs in both realms: _sv reports authoritative server state, _cl reports the local client's prediction -- they can differ for the local player (e.g. mid-prediction). Read-only.",
    schema = {
        type = "object",
        properties = {
            host = {
                type = "boolean",
                description = "Target the listen/SP host player. Omit all selectors to default to the host.",
            },
            bot = {
                type = "boolean",
                description = "Target the only bot on the server (errors if there are zero or more than one).",
            },
            name = {
                type = "string",
                description = "Target the player whose name matches (exact first, else case-insensitive contains; ambiguous matches error).",
            },
            userid = {
                type = "integer",
                description = "Target the player with this UserID (Player:UserID()).",
            },
            entindex = {
                type = "integer",
                description = "Target the player at this entity index.",
            },
            all = {
                type = "boolean",
                description = "Snapshot every player instead of one; returns a `players` array. Mutually exclusive with the other selectors.",
            },
        },
    },
    handler = function(args)
        args = args or {}

        local list, err = MCP.player.Resolve(args, { default_host = true })
        if not list then return { ok = false, error = err } end

        if args.all then
            local out = {}
            for _, p in ipairs(list) do
                if IsValid(p) then out[#out + 1] = snapshot(p) end
            end
            return { ok = true, realm = MCP.util.RealmName(), count = #out, players = out }
        end

        local r = snapshot(list[1])
        r.ok = true
        r.realm = MCP.util.RealmName()
        return r
    end,
})
