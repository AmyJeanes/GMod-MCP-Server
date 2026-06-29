-- player_walk_cl: walk the local (listen/SP host) player naturally by driving the
-- real movement code -- mutating the CUserCmd each command the way the engine does
-- for held keys -- so grounded-locomotion bugs (stairs, slopes, triggers, friction)
-- reproduce. Teleport can't: the stair-step artifact only fires under real movement.
-- console_cmd +forward can't either: it sets a key state the engine clears on focus
-- loss, so it doesn't hold on the listen host / when unfocused.
--
-- Input is forced in CreateMove (forward/side analog, sprint/duck buttons, a one-shot
-- jump edge, optional held view angles); a Think loop samples the trajectory and ends
-- the run on duration / distance / stuck. The handler spans many frames, so it defers
-- via ctx.respond rather than returning inline -- and times with RealTime, never
-- timer.Simple.

local MAX_SECONDS = 30
local STUCK_SPEED = 5     -- u/s horizontal: below this we count as "not moving"
local STUCK_GRACE = 0.4   -- sustained no-progress time that ends a stuck run
local SAMPLE_INTERVAL = 0.05
local MAX_TRAJECTORY = 20
local TELEPORT_JUMP = 150 -- one-frame position jump above this = a teleport (portal/TARDIS)

local MOVETYPE_NAMES = {
    [MOVETYPE_NONE] = "none",
    [MOVETYPE_WALK] = "walk",
    [MOVETYPE_FLY] = "fly",
    [MOVETYPE_FLYGRAVITY] = "flygravity",
    [MOVETYPE_NOCLIP] = "noclip",
    [MOVETYPE_LADDER] = "ladder",
    [MOVETYPE_OBSERVER] = "observer",
}

local function uniqueId()
    return "MCP_PlayerWalk_" .. tostring(SysTime()) .. "_" .. tostring(math.random(1, 1e9))
end

local function vec3(v) return { math.Round(v.x, 1), math.Round(v.y, 1), math.Round(v.z, 1) } end
local function ang3(a) return { math.Round(a.p, 1), math.Round(a.y, 1), math.Round(a.r, 1) } end

local function horizLen(a, b)
    return Vector(a.x - b.x, a.y - b.y, 0):Length()
end

local function parseAngles(t)
    if type(t) ~= "table" then return nil end
    local p, y, r = tonumber(t[1]), tonumber(t[2]), tonumber(t[3])
    if not (p and y and r) then return nil end
    return Angle(p, y, r)
end

-- Evenly pick up to `n` samples from `list`, always keeping the first and last.
local function downsample(list, n)
    local total = #list
    if total <= n then return list end
    local out = {}
    for i = 1, n do
        out[i] = list[math.Round(1 + (i - 1) * (total - 1) / (n - 1))]
    end
    return out
end

MCP:AddFunction({
    id = "player_walk",
    description = "Walk the local (host) player naturally by driving the real movement code (CUserCmd each tick), so grounded-locomotion bugs reproduce -- unlike teleport or `+forward`. Walks correctly through world-portals/TARDIS/safe-space transitions (real movement triggers their teleport). Set analog forward/side (-1..1, relative to view yaw), optional sprint/crouch/single-jump and a held facing; runs for `seconds` (required) or until `distance`/stuck, whichever is first. Returns the trajectory (downsampled), start/end pose, displacement, max speed, airborne/movetype/frozen flags, and `teleported` / `view_hold_released` (set when a portal/TARDIS teleport is detected mid-walk and any held `angles` is auto-released so the portal's view-rotation carries through). Client/host only.",
    schema = {
        type = "object",
        properties = {
            forward = {
                type = "number", minimum = -1, maximum = 1,
                description = "Analog forward move, -1..1 (1 = full ahead, -1 = backpedal, 0.5 = half-speed). Relative to view yaw. Either `forward` or `side` must be nonzero.",
            },
            side = {
                type = "number", minimum = -1, maximum = 1,
                description = "Analog strafe, -1..1 (+ = right). Either `forward` or `side` must be nonzero.",
            },
            run = {
                type = "boolean",
                description = "Hold sprint (IN_SPEED) for the whole walk -> higher top speed. Default false.",
            },
            crouch = {
                type = "boolean",
                description = "Hold crouch (IN_DUCK) for the whole walk -> crouch-walk. Default false.",
            },
            jump = {
                type = "boolean",
                description = "Perform a single jump (one hop) at the start. Default false. NB: holding jump does not bunny-hop (engine anti-bhop) -- continuous hopping is a future mode.",
            },
            angles = {
                type = "array", items = { type = "number" }, minItems = 3, maxItems = 3,
                description = "Optional [pitch, yaw, roll] facing, held for the duration; steers the camera and sets the forward direction. Omitted = keep the player's current view (camera stays free). Auto-released on a teleport (portal/TARDIS) so the portal's view-rotation carries through instead of being pinned to the old world angle.",
            },
            seconds = {
                type = "number", minimum = 0.05, maximum = MAX_SECONDS,
                description = "REQUIRED. How long to walk, in seconds. Also the safety cap, so the run can never hang.",
            },
            distance = {
                type = "number", minimum = 0,
                description = "Optional early-stop: end once horizontal displacement from the start reaches this many units. `seconds` still bounds the call, so this only ever shortens a walk.",
            },
            stop_when_stuck = {
                type = "boolean",
                description = "End early if movement is commanded but the player stops making progress (e.g. walked into a wall). Default true.",
            },
        },
        required = { "seconds" },
    },
    handler = function(args, ctx)
        args = args or {}

        local lp = LocalPlayer()
        if not IsValid(lp) then return { ok = false, error = "no valid LocalPlayer to walk" } end
        if not lp:Alive() then return { ok = false, error = "local player is dead" } end
        if lp:InVehicle() then return { ok = false, error = "local player is in a vehicle; exit it first" } end

        local forward = math.Clamp(tonumber(args.forward) or 0, -1, 1)
        local side = math.Clamp(tonumber(args.side) or 0, -1, 1)
        if forward == 0 and side == 0 then
            return { ok = false, error = "player_walk needs a nonzero `forward` or `side` (it is a movement tool)" }
        end

        local seconds = tonumber(args.seconds)
        if not seconds then
            return { ok = false, error = "`seconds` is required (the walk's time budget and safety cap)" }
        end
        seconds = math.Clamp(seconds, 0.05, MAX_SECONDS)

        local distance = tonumber(args.distance)
        if distance and distance <= 0 then distance = nil end

        local angles
        if args.angles ~= nil then
            angles = parseAngles(args.angles)
            if not angles then
                return { ok = false, error = "`angles` must be a 3-number array [pitch, yaw, roll]" }
            end
        end

        local run = args.run == true
        local crouch = args.crouch == true
        local stopWhenStuck = args.stop_when_stuck ~= false

        -- Scale the commanded move to the player's gait so the analog is roughly
        -- linear: at run, 1 -> sprint speed; otherwise 1 -> walk speed.
        local base = run and lp:GetRunSpeed() or lp:GetWalkSpeed()
        if not base or base <= 0 then base = 10000 end

        local startPos = lp:GetPos()
        local startAng = lp:EyeAngles()
        local startTime = RealTime()
        local hardDeadline = startTime + seconds + 1
        local lastProgress = startTime
        local lastSample = 0
        local maxSpeed = 0
        local everAirborne = false
        local lastCMPos = nil
        local teleported = false
        local viewReleased = false
        local samples = {}
        -- Held until the player actually leaves the ground (then released in Think),
        -- not pulsed for one command: a single-frame edge is unreliably seen, but
        -- engine anti-bhop means holding still yields exactly one hop.
        local jumping = args.jump == true

        local hookId = uniqueId()
        local fired = false

        local function cleanup()
            hook.Remove("CreateMove", hookId)
            hook.Remove("Think", hookId)
        end

        local function abort(msg)
            if fired then return end
            fired = true
            cleanup()
            ctx.respond({ ok = false, error = msg })
        end

        local function finish(reason)
            if fired then return end
            fired = true
            cleanup()
            if not IsValid(lp) then
                ctx.respond({ ok = false, error = "local player became invalid during the walk" })
                return
            end

            local now = RealTime()
            local endPos = lp:GetPos()
            local endVel = lp:GetVelocity()
            samples[#samples + 1] = {
                t = math.Round(now - startTime, 2),
                pos = vec3(endPos),
                speed = math.Round(Vector(endVel.x, endVel.y, 0):Length(), 1),
                onground = lp:OnGround(),
            }

            ctx.respond({
                ok = true,
                ended_reason = reason,
                duration = math.Round(now - startTime, 2),
                sample_count = #samples,
                start = { pos = vec3(startPos), ang = ang3(startAng) },
                ["end"] = { pos = vec3(endPos), ang = ang3(lp:EyeAngles()), vel = vec3(endVel) },
                displacement = math.Round(horizLen(endPos, startPos), 1),
                max_speed = math.Round(maxSpeed, 1),
                ever_airborne = everAirborne,
                movetype = MOVETYPE_NAMES[lp:GetMoveType()] or tostring(lp:GetMoveType()),
                frozen = lp:IsFlagSet(FL_FROZEN --[[@as FL]]),
                teleported = teleported,
                view_hold_released = viewReleased,
                trajectory = downsample(samples, MAX_TRAJECTORY),
            })
        end

        hook.Add("CreateMove", hookId, function(cmd)
            if fired or not IsValid(lp) then return end

            -- A portal/TARDIS teleport rotates the player's view through the portal
            -- transform. Once the player jumps a large distance in one frame, stop
            -- pinning `angles` so that rotation carries through instead of being
            -- stomped back to the pre-teleport world angle every frame.
            local pos = lp:GetPos()
            if lastCMPos and pos:DistToSqr(lastCMPos) > TELEPORT_JUMP * TELEPORT_JUMP then
                teleported = true
                if angles then
                    angles = nil
                    viewReleased = true
                end
            end
            lastCMPos = pos

            cmd:SetForwardMove(forward * base)
            cmd:SetSideMove(side * base)

            local buttons = 0
            if run then buttons = bit.bor(buttons, IN_SPEED) end
            if crouch then buttons = bit.bor(buttons, IN_DUCK) end
            if jumping then buttons = bit.bor(buttons, IN_JUMP) end
            cmd:SetButtons(buttons)

            if angles then cmd:SetViewAngles(angles) end
        end)

        hook.Add("Think", hookId, function()
            if fired then return end
            if not IsValid(lp) then return abort("local player became invalid during the walk") end

            local now = RealTime()
            local pos = lp:GetPos()
            local vel = lp:GetVelocity()
            local hspeed = Vector(vel.x, vel.y, 0):Length()
            local onground = lp:OnGround()
            if hspeed > maxSpeed then maxSpeed = hspeed end
            if not onground then
                everAirborne = true
                jumping = false  -- left the ground: the single hop fired, stop holding jump
            end
            if hspeed >= STUCK_SPEED then lastProgress = now end

            if now - lastSample >= SAMPLE_INTERVAL then
                lastSample = now
                samples[#samples + 1] = {
                    t = math.Round(now - startTime, 2),
                    pos = vec3(pos),
                    speed = math.Round(hspeed, 1),
                    onground = onground,
                }
            end

            if now - startTime >= seconds then return finish("duration") end
            if distance and horizLen(pos, startPos) >= distance then return finish("distance") end
            if stopWhenStuck and (now - lastProgress) >= STUCK_GRACE then return finish("stuck") end
            if now >= hardDeadline then return finish("duration") end
        end)

        return ctx.deferred
    end,
})
