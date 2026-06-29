-- player_walk: walk a player naturally by driving the real movement code -- mutating
-- the CUserCmd each command the way the engine does for held keys -- so grounded-
-- locomotion bugs (stairs, slopes, triggers, friction) reproduce. Teleport can't (the
-- stair-step artifact only fires under real movement); console_cmd +forward can't either
-- (the engine clears the key state on focus loss, so it doesn't hold unfocused).
--
-- One shared definition, two realms (the framework registers player_walk_cl and _sv):
--   CLIENT drives LocalPlayer via GM:CreateMove -- the host's own crafted command is
--     authoritative on a listen server, so there is no rubber-band.
--   SERVER drives a resolved target (bot/name/userid/entindex) via GM:StartCommand --
--     the canonical bot driver. Driving the listen-server host works but warns: the cl
--     tool is the faithful path for the host (no prediction round-trip).
--
-- Input is forced in the driver hook (forward/side analog with optional sine oscillation,
-- sprint/duck buttons, single hop or continuous bhop, and a view base of held angles /
-- look-at tracking / continuous turn rate); a Think loop samples the trajectory and ends
-- the run on duration / distance / stuck / teleport / near / a Lua condition. The handler
-- spans many frames, so it defers via ctx.respond -- and times with RealTime, never
-- timer.Simple.

-- The handler blocks until the walk ends, so the .NET host must wait at least this long:
-- player_walk declares a per-tool request timeout of MAX_SECONDS + 3 in its registration
-- (the host clamps it to its own max), instead of the host's 10s default. Keep this <=
-- the host's clamp.
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

local function parseVec3(t)
    if type(t) ~= "table" then return nil end
    local x, y, z = tonumber(t[1]), tonumber(t[2]), tonumber(t[3])
    if not (x and y and z) then return nil end
    return Vector(x, y, z)
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

-- Server-only: resolve the target player from exactly one of bot/name/userid/entindex.
local function resolveTarget(args)
    local sel = {}
    if args.bot then sel[#sel + 1] = "bot" end
    if args.name ~= nil then sel[#sel + 1] = "name" end
    if args.userid ~= nil then sel[#sel + 1] = "userid" end
    if args.entindex ~= nil then sel[#sel + 1] = "entindex" end
    if #sel == 0 then return nil, "specify exactly one target: bot, name, userid, or entindex" end
    if #sel > 1 then return nil, "specify exactly one target, got: " .. table.concat(sel, ", ") end

    if args.bot then
        local bots = player.GetBots()
        if #bots == 0 then return nil, "no bots on the server -- spawn one first" end
        if #bots > 1 then
            local names = {}
            for _, p in ipairs(bots) do names[#names + 1] = p:Nick() end
            return nil, "more than one bot; pick with name/userid: " .. table.concat(names, ", ")
        end
        return bots[1]
    end

    if args.name ~= nil then
        local want = tostring(args.name)
        for _, p in ipairs(player.GetAll()) do
            if p:Nick() == want then return p end
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
        return matches[1]
    end

    if args.userid ~= nil then
        local uid = tonumber(args.userid)
        if not uid then return nil, "`userid` must be a number" end
        local p = Player(uid)
        if not IsValid(p) then return nil, "no player with userid " .. tostring(uid) end
        return p
    end

    local idx = tonumber(args.entindex)
    if not idx then return nil, "`entindex` must be a number" end
    local e = Entity(idx)
    if not IsValid(e) or not e:IsPlayer() then return nil, "entity " .. tostring(idx) .. " is not a valid player" end
    return e
end

local clientDesc = "Walk the local (host) player naturally by driving the real movement code (CUserCmd each tick) via CreateMove, so grounded-locomotion bugs reproduce -- unlike teleport or `+forward`. Walks correctly through world-portals/TARDIS/safe-space transitions (real movement triggers their teleport). Set analog forward/side (-1..1, relative to view yaw), sprint/crouch, a single `jump` or continuous `bhop`, and a view: a held `angles`, `look_at`/`look_at_entity` tracking, or a continuous `yaw_rate`/`pitch_rate` spin. `oscillate` adds a sine weave to forward or side (slalom/patrol). Runs for `seconds` (required) or until the first of `distance`, `stop_on_teleport`, `stop_near`, `until`, or stuck. Returns the downsampled trajectory, start/end pose, displacement, max speed, airborne/movetype/frozen, and `teleported`/`view_hold_released`. Drives the listen/SP host's own player."

local serverDesc = "Walk a target player or bot naturally by driving its CUserCmd each tick via StartCommand -- the canonical way to control bots. Target exactly one of `bot` (the sole bot), `name`, `userid`, or `entindex`. Best for bots (no client, so no prediction conflict); driving a remote human rubber-bands them on their machine, and driving the listen-server host works but returns a `warning` -- player_walk_cl is the faithful path for the host (no prediction round-trip). Set analog forward/side (-1..1, relative to view yaw), sprint/crouch, a single `jump` or continuous `bhop`, and a view: a held `angles`, `look_at`/`look_at_entity` tracking, or a continuous `yaw_rate`/`pitch_rate` spin. `oscillate` adds a sine weave to forward or side (slalom/patrol). Runs for `seconds` (required) or until the first of `distance`, `stop_on_teleport`, `stop_near`, `until`, or stuck. Returns the downsampled trajectory, start/end pose, displacement, max speed, airborne/movetype/frozen, `teleported`/`view_hold_released`, and a `target` identity block. (Target a clean bot: the `bot` command, or a respawned player.CreateNextBot -- a first-spawn player.CreateNextBot has a clientside crouch desync unrelated to this tool.)"

local untilExample = CLIENT and "LocalPlayer():WaterLevel() >= 2" or "player.GetBots()[1]:WaterLevel() >= 2"

local schema = {
    type = "object",
    properties = {
        forward = {
            type = "number", minimum = -1, maximum = 1,
            description = "Analog forward move, -1..1 (1 = full ahead, -1 = backpedal, 0.5 = half-speed). Relative to view yaw.",
        },
        side = {
            type = "number", minimum = -1, maximum = 1,
            description = "Analog strafe, -1..1 (+ = right). Relative to view yaw.",
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
            description = "Perform a single jump (one hop) at the start. Default false. Mutually exclusive with `bhop`.",
        },
        bhop = {
            type = "boolean",
            description = "Bunny-hop: keep jumping, re-tapping on each landing, for the whole walk. Mutually exclusive with `jump`.",
        },
        angles = {
            type = "array", items = { type = "number" }, minItems = 3, maxItems = 3,
            description = "Static [pitch, yaw, roll] facing, held for the duration; steers camera and forward direction. Auto-released on a teleport so the portal/TARDIS view-rotation carries through. Mutually exclusive with look_at/look_at_entity.",
        },
        look_at = {
            type = "array", items = { type = "number" }, minItems = 3, maxItems = 3,
            description = "Aim the view at this [x,y,z] world point, recomputed every frame (movement curves around it). Mutually exclusive with angles/look_at_entity.",
        },
        look_at_entity = {
            type = "integer",
            description = "Aim the view at this entity's center every frame (tracks a moving target). Mutually exclusive with angles/look_at.",
        },
        yaw_rate = {
            type = "number",
            description = "Continuous view yaw rotation in deg/sec (e.g. 90 = a full spin every 4s) -- camera spin/pan. Layers on `angles` or the start view. Not combinable with look_at.",
        },
        pitch_rate = {
            type = "number",
            description = "Continuous view pitch rotation in deg/sec (clamped to +/-89). Layers on `angles` or the start view. Not combinable with look_at.",
        },
        oscillate = {
            type = "object",
            description = "Add a sine weave to a movement channel: slalom = oscillate `side`; patrol/back-and-forth = oscillate `forward` (with forward 0).",
            properties = {
                channel = { type = "string", enum = { "forward", "side" }, description = "Which movement channel to oscillate." },
                amplitude = { type = "number", minimum = 0, maximum = 1, description = "Peak analog offset 0..1 added to the channel's constant value." },
                period_seconds = { type = "number", minimum = 0.05, description = "Seconds per full oscillation cycle." },
            },
            required = { "channel", "amplitude", "period_seconds" },
        },
        seconds = {
            type = "number", minimum = 0.05, maximum = MAX_SECONDS,
            description = "REQUIRED. How long to walk, in seconds. Also the safety cap, so the run can never hang.",
        },
        distance = {
            type = "number", minimum = 0,
            description = "Early-stop: end once horizontal displacement from the start reaches this many units.",
        },
        stop_when_stuck = {
            type = "boolean",
            description = "End early if movement is commanded but the player stops making progress (e.g. walked into a wall). Default true. Ignored when no movement is commanded (e.g. a stationary spin).",
        },
        stop_on_teleport = {
            type = "boolean",
            description = "End the instant a teleport is detected (a one-frame position jump > 150u). Clean way to walk into a portal/TARDIS/safe-space and stop on the other side.",
        },
        stop_near = {
            type = "object",
            description = "End when the player gets within `distance` units of a point or an entity.",
            properties = {
                point = { type = "array", items = { type = "number" }, minItems = 3, maxItems = 3, description = "Target [x,y,z] world point." },
                entity = { type = "integer", description = "Target entity index (uses its center)." },
                distance = { type = "number", minimum = 0, description = "Stop within this many units of the target." },
            },
            required = { "distance" },
        },
        ["until"] = {
            type = "string",
            description = "A Lua expression evaluated " .. (CLIENT and "client" or "server") .. "-side every frame; the walk ends when it returns truthy (ended_reason `until`). E.g. \"" .. untilExample .. "\".",
        },
    },
    required = { "seconds" },
}

if SERVER then
    schema.properties.bot = {
        type = "boolean",
        description = "Target the only bot on the server. Errors if there are zero or more than one bot. Exactly one of bot/name/userid/entindex is required.",
    }
    schema.properties.name = {
        type = "string",
        description = "Target the player whose name matches this (exact first, else case-insensitive contains; ambiguous matches error). Exactly one target selector is required.",
    }
    schema.properties.userid = {
        type = "integer",
        description = "Target the player with this UserID (Player:UserID()). Exactly one target selector is required.",
    }
    schema.properties.entindex = {
        type = "integer",
        description = "Target the player at this entity index. Exactly one target selector is required.",
    }
end

MCP:AddFunction({
    id = "player_walk",
    -- Blocking handler: tell the host to wait up to the full walk (hardDeadline =
    -- seconds + 1) plus bridge/poll slack, instead of its default 10s per call.
    timeout = MAX_SECONDS + 3,
    -- Only `until` runs caller-supplied Lua, so gate just that arg on `unsafe` --
    -- the rest of player_walk stays ungated. Dispatch rejects `until` when ungranted
    -- before the handler runs.
    arg_requires = { ["until"] = { "unsafe" } },
    description = CLIENT and clientDesc or serverDesc,
    schema = schema,
    handler = function(args, ctx)
        args = args or {}

        local whoLabel = CLIENT and "local player" or "target player"

        local ply
        local hostWarning
        if CLIENT then
            ply = LocalPlayer()
            if not IsValid(ply) then return { ok = false, error = "no valid LocalPlayer to walk" } end
        else
            local resolved, terr = resolveTarget(args)
            if not resolved then return { ok = false, error = terr } end
            ply = resolved
            -- Driving the host server-side works (prediction reconciles cleanly for steady
            -- motion) but isn't the faithful path, so warn rather than refuse.
            if ply:IsListenServerHost() then
                hostWarning = "driving the listen-server host via StartCommand; player_walk_cl is the faithful path for the host (drives LocalPlayer directly via CreateMove -- no prediction round-trip, and it doesn't take over your mouse-look)"
            end
        end
        if not ply:Alive() then return { ok = false, error = whoLabel .. " is dead" } end
        if ply:InVehicle() then return { ok = false, error = whoLabel .. " is in a vehicle; exit it first" } end

        local forward = math.Clamp(tonumber(args.forward) or 0, -1, 1)
        local side = math.Clamp(tonumber(args.side) or 0, -1, 1)

        local seconds = tonumber(args.seconds)
        if not seconds then
            return { ok = false, error = "`seconds` is required (the walk's time budget and safety cap)" }
        end
        seconds = math.Clamp(seconds, 0.05, MAX_SECONDS)

        local distance = tonumber(args.distance)
        if distance and distance <= 0 then distance = nil end

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

        local yawRate = tonumber(args.yaw_rate) or 0
        local pitchRate = tonumber(args.pitch_rate) or 0
        local hasRates = yawRate ~= 0 or pitchRate ~= 0
        if hasRates and (lookAtPoint or lookAtEnt) then
            return { ok = false, error = "`yaw_rate`/`pitch_rate` can't combine with `look_at`/`look_at_entity` (tracking owns the view)" }
        end

        -- Movement oscillation (one channel).
        local osc
        if args.oscillate ~= nil then
            local o = args.oscillate
            if type(o) ~= "table" then return { ok = false, error = "`oscillate` must be an object {channel, amplitude, period_seconds}" } end
            local ch = tostring(o.channel or "")
            if ch ~= "forward" and ch ~= "side" then return { ok = false, error = "`oscillate.channel` must be 'forward' or 'side'" } end
            local period = tonumber(o.period_seconds)
            if not period or period <= 0 then return { ok = false, error = "`oscillate.period_seconds` must be > 0" } end
            osc = { channel = ch, amplitude = math.Clamp(tonumber(o.amplitude) or 0, 0, 1), period = period }
        end

        local run = args.run == true
        local crouch = args.crouch == true
        local singleJump = args.jump == true
        local bhop = args.bhop == true
        if singleJump and bhop then
            return { ok = false, error = "set only one of `jump` (single hop) or `bhop` (continuous)" }
        end

        local stopWhenStuck = args.stop_when_stuck ~= false
        local stopOnTeleport = args.stop_on_teleport == true

        -- stop_near: exactly one of point / entity, plus a distance.
        local nearPoint, nearEnt, nearDist
        if args.stop_near ~= nil then
            local sn = args.stop_near
            if type(sn) ~= "table" then return { ok = false, error = "`stop_near` must be an object {point|entity, distance}" } end
            nearDist = tonumber(sn.distance)
            if not nearDist or nearDist <= 0 then return { ok = false, error = "`stop_near.distance` must be > 0" } end
            local haveP, haveE = sn.point ~= nil, sn.entity ~= nil
            if haveP == haveE then return { ok = false, error = "`stop_near` needs exactly one of `point` or `entity`" } end
            if haveP then
                nearPoint = parseVec3(sn.point)
                if not nearPoint then return { ok = false, error = "`stop_near.point` must be a 3-number array [x, y, z]" } end
            else
                nearEnt = Entity(tonumber(sn.entity) or 0)
                if not IsValid(nearEnt) then return { ok = false, error = "`stop_near.entity` must be a valid entity index" } end
            end
        end

        -- `until`: arbitrary Lua, declared in arg_requires as needing `unsafe`. The
        -- dispatch gate already rejected it if ungranted, so here we only compile.
        local untilFn
        if args["until"] ~= nil then
            local compiled = CompileString("return (" .. tostring(args["until"]) .. ")", "player_walk_until", false)
            if type(compiled) == "string" then return { ok = false, error = "`until` compile error: " .. compiled } end
            untilFn = compiled
        end

        local hasMovement = forward ~= 0 or side ~= 0 or osc ~= nil
        local hasView = angles ~= nil or lookAtPoint ~= nil or lookAtEnt ~= nil or hasRates
        local hasJump = singleJump or bhop
        if not (hasMovement or hasView or hasJump) then
            return { ok = false, error = "player_walk needs some action: forward/side, oscillate, a view (angles/look_at/yaw_rate), or jump/bhop" }
        end

        -- Scale the commanded move to the player's gait so the analog is roughly
        -- linear: at run, 1 -> sprint speed; otherwise 1 -> walk speed.
        local base = run and ply:GetRunSpeed() or ply:GetWalkSpeed()
        if not base or base <= 0 then base = 10000 end

        local startPos = ply:GetPos()
        local startAng = ply:EyeAngles()
        local startTime = RealTime()
        local hardDeadline = startTime + seconds + 1
        local lastProgress = startTime
        local lastSample = 0
        local lastViewTime = startTime
        local maxSpeed = 0
        local everAirborne = false
        local lastCMPos = nil
        local teleported = false
        local viewReleased = false
        local samples = {}
        -- Single hop held until airborne (then released in Think): a one-frame edge is
        -- unreliably seen, but engine anti-bhop means holding still yields one hop.
        local jumping = singleJump
        -- Evolving angle for the continuous-spin mode (base = angles or the start view).
        local spinAng = hasRates and (angles or Angle(startAng.p, startAng.y, startAng.r)) or nil

        local hookId = uniqueId()
        local driverHook = CLIENT and "CreateMove" or "StartCommand"
        local fired = false

        local function cleanup()
            hook.Remove(driverHook, hookId)
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
            if not IsValid(ply) then
                ctx.respond({ ok = false, error = whoLabel .. " became invalid during the walk" })
                return
            end

            local now = RealTime()
            local endPos = ply:GetPos()
            local endVel = ply:GetVelocity()
            samples[#samples + 1] = {
                t = math.Round(now - startTime, 2),
                pos = vec3(endPos),
                speed = math.Round(Vector(endVel.x, endVel.y, 0):Length(), 1),
                onground = ply:OnGround(),
            }

            local result = {
                ok = true,
                ended_reason = reason,
                duration = math.Round(now - startTime, 2),
                sample_count = #samples,
                start = { pos = vec3(startPos), ang = ang3(startAng) },
                ["end"] = { pos = vec3(endPos), ang = ang3(ply:EyeAngles()), vel = vec3(endVel) },
                displacement = math.Round(horizLen(endPos, startPos), 1),
                max_speed = math.Round(maxSpeed, 1),
                ever_airborne = everAirborne,
                movetype = MOVETYPE_NAMES[ply:GetMoveType()] or tostring(ply:GetMoveType()),
                frozen = ply:IsFlagSet(FL_FROZEN --[[@as FL]]),
                teleported = teleported,
                view_hold_released = viewReleased,
                trajectory = downsample(samples, MAX_TRAJECTORY),
            }
            if SERVER then
                result.target = {
                    name = ply:Nick(),
                    userid = ply:UserID(),
                    entindex = ply:EntIndex(),
                    is_bot = ply:IsBot(),
                }
            end
            if hostWarning then result.warning = hostWarning end
            ctx.respond(result)
        end

        -- The per-frame view angle: dynamic look-at, evolving spin, or a static hold.
        local function viewAngleFor(dt)
            if lookAtPoint then
                return (lookAtPoint - ply:EyePos()):Angle()
            elseif lookAtEnt then
                if IsValid(lookAtEnt) then return (lookAtEnt:WorldSpaceCenter() - ply:EyePos()):Angle() end
                return nil
            elseif spinAng then
                spinAng.y = spinAng.y + yawRate * dt
                spinAng.p = math.Clamp(spinAng.p + pitchRate * dt, -89, 89)
                return Angle(spinAng.p, spinAng.y, spinAng.r)
            elseif angles then
                return angles
            end
            return nil
        end

        -- Force the input for one command. Shared by both realms; the only difference is
        -- which hook calls it (CreateMove drives LocalPlayer; StartCommand drives the
        -- target after the realm hook has filtered to it).
        local function drive(cmd)
            local now = RealTime()
            local dt = now - lastViewTime
            lastViewTime = now

            -- A teleport changes the frame of reference: rebase a spin onto the new view
            -- (so it keeps spinning correctly) and release a static hold (so the portal's
            -- view-rotation carries through instead of being stomped). look_at is
            -- position-relative and self-corrects, so it needs no handling.
            local pos = ply:GetPos()
            if lastCMPos and pos:DistToSqr(lastCMPos) > TELEPORT_JUMP * TELEPORT_JUMP then
                teleported = true
                if spinAng then
                    local e = ply:EyeAngles()
                    spinAng = Angle(e.p, e.y, e.r)
                    viewReleased = true
                elseif angles then
                    angles = nil
                    viewReleased = true
                end
            end
            lastCMPos = pos

            local elapsed = now - startTime
            local effF, effS = forward, side
            if osc then
                local s = osc.amplitude * math.sin(2 * math.pi * elapsed / osc.period)
                if osc.channel == "forward" then
                    effF = math.Clamp(forward + s, -1, 1)
                else
                    effS = math.Clamp(side + s, -1, 1)
                end
            end
            cmd:SetForwardMove(effF * base)
            cmd:SetSideMove(effS * base)

            local buttons = 0
            if run then buttons = bit.bor(buttons, IN_SPEED) end
            if crouch then buttons = bit.bor(buttons, IN_DUCK) end

            if jumping then buttons = bit.bor(buttons, IN_JUMP) end
            -- bhop: press while grounded, release while airborne -> one hop per landing.
            if bhop and ply:OnGround() then buttons = bit.bor(buttons, IN_JUMP) end
            cmd:SetButtons(buttons)

            local va = viewAngleFor(dt)
            if va then
                cmd:SetViewAngles(va)
                -- A bot has no client to apply the cmd view (it only steers movement), so
                -- set the eye angle too -- then the bot actually turns and EyeAngles()
                -- reads true. The client's prediction already applies it, so it's
                -- server-only (doing it on LocalPlayer would fight prediction).
                if SERVER then ply:SetEyeAngles(va) end
            end
        end

        if CLIENT then
            hook.Add("CreateMove", hookId, function(cmd)
                if fired or not IsValid(ply) then return end
                drive(cmd)
            end)
        else
            hook.Add("StartCommand", hookId, function(p, cmd)
                if fired or not IsValid(ply) then return end
                if p ~= ply then return end
                drive(cmd)
            end)
        end

        hook.Add("Think", hookId, function()
            if fired then return end
            if not IsValid(ply) then return abort(whoLabel .. " became invalid during the walk") end

            local now = RealTime()
            local pos = ply:GetPos()
            local vel = ply:GetVelocity()
            local hspeed = Vector(vel.x, vel.y, 0):Length()
            local onground = ply:OnGround()
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

            -- Terminations, first to fire wins.
            if stopOnTeleport and teleported then return finish("teleport") end
            if nearDist then
                local target = nearPoint or (IsValid(nearEnt) and nearEnt:WorldSpaceCenter()) or nil
                if target and pos:Distance(target) <= nearDist then return finish("near") end
            end
            if untilFn then
                local okU, res = pcall(untilFn)
                if not okU then return abort("`until` condition errored: " .. tostring(res)) end
                if res then return finish("until") end
            end
            if now - startTime >= seconds then return finish("duration") end
            if distance and horizLen(pos, startPos) >= distance then return finish("distance") end
            if stopWhenStuck and hasMovement and (now - lastProgress) >= STUCK_GRACE then return finish("stuck") end
            if now >= hardDeadline then return finish("duration") end
        end)

        return ctx.deferred
    end,
})
