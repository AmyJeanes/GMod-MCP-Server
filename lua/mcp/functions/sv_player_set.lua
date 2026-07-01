-- player_set: set a player or bot's pose/movement state -- teleport, aim, movetype
-- (pin/noclip), control-lock, velocity, health, loadout, colour -- then confirm it stuck.
-- Every arg is optional except the target; supply any subset of actions. The hard-set
-- sibling of player_walk: walk drives real movement; set hard-sets the pose. Both are
-- bounded, so neither is gated by `unsafe`.
--
-- Server-only on purpose. A teleport is a direct SetPos, and SetPos is authoritative
-- server-side for every player including the listen-server host -- so there's no faithful
-- client realm here (LocalPlayer():SetPos() only moves the predicted clientside position,
-- which the server reconciles away next frame). That's the opposite of player_walk, whose
-- client realm is the faithful path because the host's CUserCmd is the real command.
-- Caveat for the listen/SP host: SetEyeAngles is overwritten by the host's own CreateMove
-- the next tick (its live mouse input wins), so an `angles`/`look_at` on the host holds only
-- until the player next moves the mouse -- fine for a screenshot, not a durable re-aim.
--
-- The pose can fail to stick for reasons SetPos can't see: carried velocity slides the
-- player off, gravity drops a mid-air placement to the floor, noclip drifts. So the handler
-- applies, then defers and waits (Think + RealTime, never timer.Simple) for the position to
-- settle, and reports requested vs final so the caller knows whether it landed where asked.
--
-- Three distinct "hold" mechanisms, verified live -- they are NOT the same:
--   pin (MOVETYPE_NONE)   -- suspends the player entirely: no gravity, no input. Hangs
--                            exactly where placed, even mid-air. The real "hold this pose".
--   lock_controls (Freeze)-- sets FL_FROZEN: disables the player's own input but leaves them
--                            physical, so a mid-air lock STILL FALLS. Freeze does not fight gravity.
--   lock (Lock/UnLock)    -- FL_FROZEN *plus* FL_GODMODE *plus* MOVETYPE_NONE (verified live --
--                            Lock is a stronger hold than the wiki's flags-only description).
--                            Freeze(false) clears only the frozen flag, leaving godmode and the
--                            suspended movetype -- so the report surfaces `godmode` and `pinned`
--                            alongside `controls_locked`; otherwise a lock_controls:false on a
--                            previously-Locked player looks released while still invincible+pinned.
--                            UnLock clears all three and restores walking.

local SETTLE_CAP = 1.0     -- give up waiting for stillness after this long; report as-is. Generous
                           -- so a normal placement plus a modest fall settles inside it (fall time
                           -- + dwell); a longer fall honestly reports settled=false, still moving.
local STILL_DWELL = 0.1    -- velocity must stay at-rest (the dwell) this long to count as settled.
                           -- Also keeps a fall from false-settling: a from-rest drop accelerates
                           -- past STILL_SPEED within a frame or two, breaking the dwell.
-- Gate stillness on velocity, NOT per-frame position delta: a just-placed pose starts at ~0
-- speed, so a position gate false-settles the first frames of a fall before it accelerates
-- (observed live -- a mid-air drop wrongly reported settled). A real fall reads >this at once.
local STILL_SPEED = 5      -- velocity (u/s) below which the pose counts as at rest

local MOVETYPE_NAMES = {
    [MOVETYPE_NONE] = "none",
    [MOVETYPE_WALK] = "walk",
    [MOVETYPE_FLY] = "fly",
    [MOVETYPE_FLYGRAVITY] = "flygravity",
    [MOVETYPE_NOCLIP] = "noclip",
    [MOVETYPE_LADDER] = "ladder",
    [MOVETYPE_OBSERVER] = "observer",
}

local function vec3(v) return { math.Round(v.x, 1), math.Round(v.y, 1), math.Round(v.z, 1) } end
local function ang3(a) return { math.Round(a.p, 1), math.Round(a.y, 1), math.Round(a.r, 1) } end
-- Player/weapon colours are normalised 0-1 Vectors, not 0-255.
local function col3(v) return { math.Round(v.x, 3), math.Round(v.y, 3), math.Round(v.z, 3) } end

local function parseAngles(t)
    if type(t) ~= "table" then return nil end
    local p, y, r = tonumber(t[1]), tonumber(t[2]), tonumber(t[3])
    if not (p and y and r) then return nil end
    return Angle(p, y, r)
end

local function parseVec3(t)
    if type(t) ~= "table" then return nil end
    local x, y, z = tonumber(t[1]), tonumber(t[2]), tonumber(t[3])
    if not (x and y and z) then return nil end
    return Vector(x, y, z)
end

-- Parse a normalised colour Vector, clamping each channel to 0-1.
local function parseColor01(t)
    local v = parseVec3(t)
    if not v then return nil end
    return Vector(math.Clamp(v.x, 0, 1), math.Clamp(v.y, 0, 1), math.Clamp(v.z, 0, 1))
end

-- A zero-extent hull trace at the rest position: is the player embedded in world/solid?
local function inSolid(ply, pos)
    local tr = util.TraceHull({
        start = pos,
        endpos = pos,
        mins = ply:OBBMins(),
        maxs = ply:OBBMaxs(),
        filter = ply,
        mask = MASK_PLAYERSOLID --[[@as MASK]],
    })
    return tr.StartSolid == true or tr.AllSolid == true
end

-- Target resolution (exactly one of host/bot/name/userid/entindex) is shared with the rest
-- of the player_* family via MCP.player.Resolve; allow_all=false since player_set acts on
-- one player.

MCP:AddFunction({
    id = "player_set",
    requires = { "player_control" },
    description = "Set a player or bot's pose and state, then wait for it to settle and confirm it stuck. The hard-set sibling of player_walk (which drives real movement). It's authoritative for any target including the listen/SP host. Every arg is optional except the target -- supply any subset of actions (at least one): teleport `pos` [x,y,z]; aim via `angles` [pitch,yaw,roll] or `look_at` [x,y,z] / `look_at_entity` (aim from the destination eye); movement holds; health/loadout; and colours. So e.g. `{host, lock_controls:false}` just unfreezes without moving them. Target exactly one of `host` (the listen/SP host player), `bot` (the sole bot), `name`, `userid`, or `entindex`. Modifiers (leave-as-is when omitted): `pin` (true = MOVETYPE_NONE: fully suspend in place, no gravity and no input, hangs even mid-air -- the way to hold an exact pose; false restores walking), `noclip` (true = MOVETYPE_NOCLIP fly, false = walk; mutually exclusive with `pin`), `lock_controls` (true = Player:Freeze/FL_FROZEN: disable the player's own input but leave it physical -- a grounded player stays put, a mid-air one STILL FALLS; false releases), `lock` (true = Player:Lock: FL_FROZEN plus FL_GODMODE/invincible; false = Player:UnLock, clears both -- note lock_controls:false only clears the freeze, leaving godmode, so the report shows `godmode` separately), `kill_velocity` (default true: zero carried momentum). Other actions: `respawn` (Player:Spawn -- revives a dead target and resets loadout/position, applied before the pose so a `pos` still lands), `health`/`armor`, `give_weapon` (weapon class to Give), `select_weapon` (weapon class to switch to), `player_color`/`weapon_color` ([r,g,b] each 0-1). To hold a player off the ground use `pin`, NOT `lock_controls`. The report shows where it came to rest (`settled`, `moved_after_place`, `in_solid`, `on_ground`, `pinned`, `controls_locked`, `godmode`) plus any requested health/weapon/colour state. On the listen/SP host an `angles`/`look_at` holds only until the host next moves the mouse (its CreateMove overrides the view next tick).",
    schema = {
        type = "object",
        properties = {
            host = {
                type = "boolean",
                description = "Target the listen/SP host player. Exactly one of host/bot/name/userid/entindex is required.",
            },
            bot = {
                type = "boolean",
                description = "Target the only bot on the server. Errors if there are zero or more than one bot.",
            },
            name = {
                type = "string",
                description = "Target the player whose name matches this (exact first, else case-insensitive contains; ambiguous matches error).",
            },
            userid = {
                type = "integer",
                description = "Target the player with this UserID (Player:UserID()).",
            },
            entindex = {
                type = "integer",
                description = "Target the player at this entity index.",
            },
            pos = {
                type = "array", items = { type = "number" }, minItems = 3, maxItems = 3,
                description = "Destination [x, y, z] world position. Omit to leave the position and only re-aim/pin/noclip/lock in place.",
            },
            angles = {
                type = "array", items = { type = "number" }, minItems = 3, maxItems = 3,
                description = "Static [pitch, yaw, roll] facing to snap the view to. Mutually exclusive with look_at/look_at_entity.",
            },
            look_at = {
                type = "array", items = { type = "number" }, minItems = 3, maxItems = 3,
                description = "Aim the view at this [x, y, z] world point, computed from the post-teleport eye. Mutually exclusive with angles/look_at_entity.",
            },
            look_at_entity = {
                type = "integer",
                description = "Aim the view at this entity's centre. Mutually exclusive with angles/look_at.",
            },
            pin = {
                type = "boolean",
                description = "true -> MOVETYPE_NONE: fully suspend the player in place (no gravity, no input) so it hangs exactly where placed, even mid-air -- use this to hold an exact pose. false -> MOVETYPE_WALK. Omit to leave the movetype unchanged. Mutually exclusive with noclip.",
            },
            noclip = {
                type = "boolean",
                description = "true -> MOVETYPE_NOCLIP (float, fly on input), false -> MOVETYPE_WALK. Omit to leave the movetype unchanged. Mutually exclusive with pin.",
            },
            lock_controls = {
                type = "boolean",
                description = "true -> Player:Freeze (FL_FROZEN): disable the player's OWN movement input but keep it physical -- gravity still applies, so a grounded player stays put while a mid-air one still falls (use `pin` for a mid-air hold). false -> unfreeze. Omit to leave unchanged. Independent of pin/noclip. NOTE: false only clears FL_FROZEN; a player previously put under `lock` keeps FL_GODMODE (see `lock`).",
            },
            lock = {
                type = "boolean",
                description = "true -> Player:Lock (FL_FROZEN + FL_GODMODE + MOVETYPE_NONE: frozen, invincible AND movement-suspended -- a stronger hold than lock_controls). false -> Player:UnLock (clears all three and restores walking -- the way to fully release a locked player). Distinct from lock_controls, which only toggles the freeze; lock_controls:false on a locked player leaves godmode and the movetype set (shown as `godmode`/`pinned` in the report). Omit to leave unchanged.",
            },
            kill_velocity = {
                type = "boolean",
                description = "Zero the player's velocity on placement so carried momentum/gravity doesn't slide them off the mark. Default true; set false to preserve momentum (e.g. to test sliding).",
            },
            respawn = {
                type = "boolean",
                description = "Player:Spawn the target first -- revives a dead player and resets loadout/health/position per the gamemode. Applied before pos/aim/loadout so those still take effect on the fresh spawn.",
            },
            health = {
                type = "integer", minimum = 1,
                description = "Set the player's health (Player:SetHealth). May exceed max health (overheal).",
            },
            armor = {
                type = "integer", minimum = 0,
                description = "Set the player's armor (Player:SetArmor).",
            },
            give_weapon = {
                type = "string",
                description = "Weapon class to give the player (Player:Give), e.g. \"weapon_pistol\". Reports whether it was granted.",
            },
            select_weapon = {
                type = "string",
                description = "Weapon class to switch the player to (Player:SelectWeapon). The player must already hold it (pair with give_weapon to grant then select).",
            },
            player_color = {
                type = "array", items = { type = "number" }, minItems = 3, maxItems = 3,
                description = "Playermodel colour as [r, g, b], each 0-1 (normalised, NOT 0-255). Player:SetPlayerColor.",
            },
            weapon_color = {
                type = "array", items = { type = "number" }, minItems = 3, maxItems = 3,
                description = "Weapon/physgun colour as [r, g, b], each 0-1 (normalised, NOT 0-255). Player:SetWeaponColor.",
            },
        },
    },
    handler = function(args, ctx)
        args = args or {}

        local list, terr = MCP.player.Resolve(args, { allow_all = false })
        if not list then return { ok = false, error = terr } end
        local ply = list[1] --[[@as Player]]

        local reqPos
        if args.pos ~= nil then
            reqPos = parseVec3(args.pos)
            if not reqPos then return { ok = false, error = "`pos` must be a 3-number array [x, y, z]" } end
        end

        -- View base: at most one of angles / look_at / look_at_entity.
        local angles, lookAtPoint, lookAtEnt
        local viewBases = 0
        if args.angles ~= nil then
            angles = parseAngles(args.angles)
            if not angles then return { ok = false, error = "`angles` must be a 3-number array [pitch, yaw, roll]" } end
            viewBases = viewBases + 1
        end
        if args.look_at ~= nil then
            lookAtPoint = parseVec3(args.look_at)
            if not lookAtPoint then return { ok = false, error = "`look_at` must be a 3-number array [x, y, z]" } end
            viewBases = viewBases + 1
        end
        if args.look_at_entity ~= nil then
            lookAtEnt = Entity(tonumber(args.look_at_entity) or 0)
            if not IsValid(lookAtEnt) then return { ok = false, error = "`look_at_entity` must be a valid entity index" } end
            viewBases = viewBases + 1
        end
        if viewBases > 1 then
            return { ok = false, error = "set at most one of `angles`, `look_at`, `look_at_entity`" }
        end

        -- Movetype: pin (MOVETYPE_NONE) and noclip both write it, so allow only one.
        local pin, noclip
        if args.pin ~= nil then pin = args.pin == true end
        if args.noclip ~= nil then noclip = args.noclip == true end
        if pin ~= nil and noclip ~= nil then
            return { ok = false, error = "set at most one of `pin` or `noclip` (both set the movetype)" }
        end
        local targetMoveType
        if pin == true then
            targetMoveType = MOVETYPE_NONE
        elseif noclip == true then
            targetMoveType = MOVETYPE_NOCLIP
        elseif pin == false or noclip == false then
            targetMoveType = MOVETYPE_WALK
        end

        -- lock_controls (Freeze/FL_FROZEN) and lock (Lock/UnLock = FL_FROZEN+FL_GODMODE) are
        -- independent input locks; lock is applied first, lock_controls second so an explicit
        -- lock_controls wins the frozen bit.
        local lockControls, lockFull
        if args.lock_controls ~= nil then lockControls = args.lock_controls == true end
        if args.lock ~= nil then lockFull = args.lock == true end

        local killVel = args.kill_velocity ~= false
        local respawn = args.respawn == true

        local health, armor
        if args.health ~= nil then health = math.max(1, math.floor(tonumber(args.health) or 0)) end
        if args.armor ~= nil then armor = math.max(0, math.floor(tonumber(args.armor) or 0)) end

        local giveWeapon = isstring(args.give_weapon) and args.give_weapon ~= "" and args.give_weapon or nil
        local selectWeapon = isstring(args.select_weapon) and args.select_weapon ~= "" and args.select_weapon or nil

        local playerColor, weaponColor
        if args.player_color ~= nil then
            playerColor = parseColor01(args.player_color)
            if not playerColor then return { ok = false, error = "`player_color` must be [r, g, b] numbers 0-1" } end
        end
        if args.weapon_color ~= nil then
            weaponColor = parseColor01(args.weapon_color)
            if not weaponColor then return { ok = false, error = "`weapon_color` must be [r, g, b] numbers 0-1" } end
        end

        local hasAction = reqPos or viewBases > 0 or targetMoveType or lockControls ~= nil
            or lockFull ~= nil or respawn or health or armor or giveWeapon or selectWeapon
            or playerColor or weaponColor
        if not hasAction then
            return { ok = false, error = "player_set needs an action: pos, a view, pin/noclip, lock/lock_controls, respawn, health/armor, give_weapon/select_weapon, or a colour" }
        end

        -- respawn first (revives + resets), so the dead/vehicle guards and the rest apply to
        -- the fresh spawn. Without respawn a dead or in-vehicle target can't be posed.
        if respawn then ply:Spawn() end
        if not ply:Alive() then return { ok = false, error = "target '" .. ply:Nick() .. "' is dead; pass respawn:true to revive it first" } end
        if ply:InVehicle() then return { ok = false, error = "target '" .. ply:Nick() .. "' is in a vehicle; exit it first" } end

        local startPos = ply:GetPos()
        local startAng = ply:EyeAngles()

        if health then ply:SetHealth(health) end
        if armor then ply:SetArmor(armor) end

        local gaveWeapon
        if giveWeapon then
            local w = ply:Give(giveWeapon)
            gaveWeapon = IsValid(w) and w:GetClass() or false
        end

        -- Position first, so look_at is computed from the destination eye.
        if reqPos then ply:SetPos(reqPos) end

        local appliedAng
        if angles then
            appliedAng = angles
        elseif lookAtPoint then
            appliedAng = (lookAtPoint - ply:EyePos()):Angle()
        elseif lookAtEnt then
            appliedAng = (lookAtEnt:WorldSpaceCenter() - ply:EyePos()):Angle()
        end
        -- look_at's (target-eye):Angle() can return pitch as e.g. 333.3 (= -26.7);
        -- normalize to [-180,180] so requested_ang matches the convention EyeAngles reads back.
        if appliedAng then
            appliedAng:Normalize()
            ply:SetEyeAngles(appliedAng)
        end

        if targetMoveType then ply:SetMoveType(targetMoveType) end
        -- SetVelocity adds an impulse, so negating the current velocity nets it to ~zero.
        if killVel then ply:SetVelocity(-ply:GetVelocity()) end
        if lockFull ~= nil then
            if lockFull then ply:Lock() else ply:UnLock() end
        end
        if lockControls ~= nil then ply:Freeze(lockControls) end

        if selectWeapon then ply:SelectWeapon(selectWeapon) end
        if playerColor then ply:SetPlayerColor(playerColor) end
        if weaponColor then ply:SetWeaponColor(weaponColor) end

        -- Settle on VELOCITY (not position): a just-placed pose starts at ~0 speed, so a
        -- position gate false-settles the first frames of a fall before it accelerates. The
        -- dwell handles the fall too -- a falling player can't stay under STILL_SPEED for a
        -- continuous STILL_DWELL, so it never settles mid-fall.
        MCP:Settle({
            seconds = SETTLE_CAP,
            stable_for = STILL_DWELL,
            check = function() return IsValid(ply) and ply:GetVelocity():Length() < STILL_SPEED end,
        }, function(s)
            if not IsValid(ply) then
                ctx.respond({ ok = false, error = "target became invalid during placement settle" })
                return
            end

            local endPos = ply:GetPos()
            local result = {
                ok = true,
                settled = s.settled,
                settle_time = math.Round(s.elapsed, 2),
                start = { pos = vec3(startPos), ang = ang3(startAng) },
                final = {
                    pos = vec3(endPos),
                    ang = ang3(ply:EyeAngles()),
                    vel = vec3(ply:GetVelocity()),
                },
                on_ground = ply:OnGround(),
                in_solid = inSolid(ply, endPos),
                movetype = MOVETYPE_NAMES[ply:GetMoveType()] or tostring(ply:GetMoveType()),
                pinned = ply:GetMoveType() == MOVETYPE_NONE,
                controls_locked = ply:IsFlagSet(FL_FROZEN --[[@as FL]]),
                godmode = ply:IsFlagSet(FL_GODMODE --[[@as FL]]),
                target = {
                    name = ply:Nick(),
                    userid = ply:UserID(),
                    entindex = ply:EntIndex(),
                    is_bot = ply:IsBot(),
                },
            }
            if reqPos then
                result.requested_pos = vec3(reqPos)
                result.moved_after_place = math.Round(endPos:Distance(reqPos), 1)
            end
            if appliedAng then result.requested_ang = ang3(appliedAng) end
            if respawn then result.respawned = true end
            if health or armor or respawn then
                result.health = ply:Health()
                result.armor = ply:Armor()
            end
            if giveWeapon or selectWeapon or respawn then
                local w = ply:GetActiveWeapon()
                result.active_weapon = IsValid(w) and w:GetClass() or false
            end
            if giveWeapon then result.gave_weapon = gaveWeapon end
            if playerColor then result.player_color = col3(ply:GetPlayerColor()) end
            if weaponColor then result.weapon_color = col3(ply:GetWeaponColor()) end
            ctx.respond(result)
        end)

        return ctx.deferred
    end,
})
