-- player_set: set a player or bot's pose/movement state -- teleport, aim, movetype
-- (pin/noclip), control-lock, velocity -- then confirm it stuck. Every arg is optional
-- except the target; supply any subset of actions. The hard-set sibling of player_walk:
-- walk drives real movement; set hard-sets the pose. Both are bounded, so neither is
-- gated by `unsafe`.
--
-- Server-only on purpose. A teleport is a direct SetPos, and SetPos is authoritative
-- server-side for every player including the listen-server host -- so there's no faithful
-- client realm here (LocalPlayer():SetPos() only moves the predicted clientside position,
-- which the server reconciles away next frame). That's the opposite of player_walk, whose
-- client realm is the faithful path because the host's CUserCmd is the real command.
--
-- The pose can fail to stick for reasons SetPos can't see: carried velocity slides the
-- player off, gravity drops a mid-air placement to the floor, noclip drifts. So the handler
-- applies, then defers and waits (Think + RealTime, never timer.Simple) for the position to
-- settle, and reports requested vs final so the caller knows whether it landed where asked.
--
-- Two distinct "hold" mechanisms, verified live -- they are NOT the same:
--   pin (MOVETYPE_NONE)   -- suspends the player entirely: no gravity, no input. Hangs
--                            exactly where placed, even mid-air. The real "hold this pose".
--   lock_controls (Freeze)-- sets FL_FROZEN: disables the player's own input but leaves them
--                            physical, so a mid-air lock STILL FALLS to the floor. Freeze()
--                            does not counteract gravity.

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
    description = "Set a player or bot's pose and movement state, then wait for it to settle and confirm it stuck. The hard-set sibling of player_walk (which drives real movement). It's authoritative for any target including the listen/SP host. Every arg is optional except the target -- supply any subset of actions (at least one): teleport `pos` [x,y,z]; aim via `angles` [pitch,yaw,roll] or `look_at` [x,y,z] / `look_at_entity` (aim at a world point / entity centre from the destination eye); and the hold/move modifiers below. So e.g. `{host, lock_controls:false}` just unfreezes without moving them. Target exactly one of `host` (the listen/SP host player), `bot` (the sole bot), `name`, `userid`, or `entindex`. Modifiers (leave-as-is when omitted): `pin` (true = MOVETYPE_NONE: fully suspend the player in place, no gravity and no input, so it hangs exactly where placed even mid-air -- the way to hold an exact pose for a screenshot; false restores walking), `noclip` (true = MOVETYPE_NOCLIP fly, false = walk; mutually exclusive with `pin`), `lock_controls` (true = Player:Freeze/FL_FROZEN: disable the player's own input but leave it physical -- a grounded player stays put, a mid-air one STILL FALLS; false releases), `kill_velocity` (default true: zero carried momentum so it doesn't slide off). To hold a player off the ground use `pin`, NOT `lock_controls` (Freeze does not counteract gravity). A plain walking player teleported into the air falls to the floor -- the report shows where it actually came to rest (`settled`, `moved_after_place`, `in_solid`, `on_ground`, `pinned`, `controls_locked`).",
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
                description = "true -> Player:Freeze (FL_FROZEN): disable the player's OWN movement input but keep it physical -- gravity still applies, so a grounded player stays put while a mid-air one still falls (use `pin` for a mid-air hold). false -> unfreeze. Omit to leave the lock state unchanged. Independent of pin/noclip.",
            },
            kill_velocity = {
                type = "boolean",
                description = "Zero the player's velocity on placement so carried momentum/gravity doesn't slide them off the mark. Default true; set false to preserve momentum (e.g. to test sliding).",
            },
        },
    },
    handler = function(args, ctx)
        args = args or {}

        local list, terr = MCP.player.Resolve(args, { allow_all = false })
        if not list then return { ok = false, error = terr } end
        local ply = list[1] --[[@as Player]]
        if not ply:Alive() then return { ok = false, error = "target '" .. ply:Nick() .. "' is dead; placement needs a live player" } end
        if ply:InVehicle() then return { ok = false, error = "target '" .. ply:Nick() .. "' is in a vehicle; exit it first" } end

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

        -- lock_controls: FL_FROZEN input lock, independent of movetype.
        local lockControls
        if args.lock_controls ~= nil then lockControls = args.lock_controls == true end

        local killVel = args.kill_velocity ~= false

        if not (reqPos or viewBases > 0 or targetMoveType or lockControls ~= nil) then
            return { ok = false, error = "player_set needs an action: pos, a view (angles/look_at/look_at_entity), pin, noclip, or lock_controls" }
        end

        local startPos = ply:GetPos()
        local startAng = ply:EyeAngles()

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
        if lockControls ~= nil then ply:Freeze(lockControls) end

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
            ctx.respond(result)
        end)

        return ctx.deferred
    end,
})
