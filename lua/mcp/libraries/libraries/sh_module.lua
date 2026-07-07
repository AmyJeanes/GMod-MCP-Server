-- Registry: AddCapability, AddFunction, dispatch, manifest emission.

---@class mcp_ctx
---@field deferred table sentinel: return this from a handler, then deliver the real response later via `respond`
---@field session string?
---@field respond fun(response: table)

---@class mcp_capability_def
---@field id string
---@field description string?
---@field default boolean?

---@class mcp_function_def
---@field id string
---@field description string?
---@field schema table
---@field requires string[]?
---@field arg_requires table<string, string[]>?
---@field timeout number?
---@field handler fun(args: table, ctx: mcp_ctx): table?

MCP._functions = MCP._functions or {}
MCP._capabilities = MCP._capabilities or {}

-- Sentinel returned by an async handler to tell the bridge "don't write a
-- response yet — I'll deliver one via ctx.respond". Exposed as `ctx.deferred`
-- so handler code never has to reach into MCP internals.
MCP._DEFERRED = MCP._DEFERRED or {}

-- Capabilities replicate server -> client so toggling on the server propagates to clients.
-- FCVAR_ARCHIVE so the user's capability grants persist across game restarts.
local CAP_FLAGS = { FCVAR_PROTECTED, FCVAR_DONTRECORD, FCVAR_REPLICATED, FCVAR_ARCHIVE }

---@param kind string
---@param id string
local function validateId(kind, id)
    if type(id) ~= "string" or id == "" then
        error(kind .. " id must be a non-empty string", 3)
    end
    if id ~= string.lower(id) then
        error(kind .. " id must be lowercase: " .. id, 3)
    end
    if id:find("[^a-z0-9_]") then
        error(kind .. " id may only contain a-z, 0-9, _: " .. id, 3)
    end
end

-- Debounced manifest write so a burst of registrations (bootstrap, MCP:Reload,
-- or GMod autorefresh re-running a file) produces one disk write at the end.
-- StartBridge writes synchronously and clears any pending timer; this only fires
-- when the registrations come from somewhere other than a full reload — e.g. a
-- single autorefreshed Lua file calling MCP:AddFunction again.
local function scheduleManifestWrite()
    timer.Create("MCP_ManifestWrite", 0.1, 1, function()
        if MCP and MCP.WriteManifest then
            MCP:WriteManifest()
        end
    end)
end

---@param id string
function MCP:CapabilityConVarName(id)
    return "mcp_allow_" .. id
end

---@param t mcp_capability_def
function MCP:AddCapability(t)
    if type(t) ~= "table" then error("MCP:AddCapability expects a table", 2) end
    validateId("capability", t.id)

    local default = t.default and true or false
    local convarName = self:CapabilityConVarName(t.id)

    if not ConVarExists(convarName) then
        CreateConVar(convarName,
            default and "1" or "0",
            CAP_FLAGS,
            t.description or ("Capability gate for " .. t.id))
    end

    self._capabilities[t.id] = {
        id = t.id,
        description = t.description or "",
        default = default,
        convar = convarName,
        _generation = self._generation,
    }

    scheduleManifestWrite()
end

-- Shallow-copies the user's schema and drops empty `properties`. util.TableToJSON
-- encodes empty Lua tables as JSON arrays (`[]`), but JSON Schema requires
-- `properties` to be an object — strict MCP clients reject `"properties": []`.
-- An absent `properties` key is equivalent to `{}` in JSON Schema, so dropping
-- it is the correct canonical form.
---@param s table
local function normalizeSchema(s)
    if type(s) ~= "table" then return { type = "object" } end
    local out = {}
    for k, v in pairs(s) do out[k] = v end
    if type(out.properties) == "table" and next(out.properties) == nil then
        out.properties = nil
    end
    return out
end

-- Human-readable note derived from a `requires` / `arg_requires` entry so the
-- capability requirement is advertised in the description automatically (the
-- structured fields aren't sent over the wire). Keeps the gate and its advertised
-- note from drifting -- tools never hand-write capability prose.
---@param caps string[]
---@param perArg boolean
local function capNote(caps, perArg)
    local parts = {}
    for _, c in ipairs(caps) do parts[#parts + 1] = "`" .. c .. "`" end
    local note = "Requires the " .. table.concat(parts, ", ") .. " " ..
        (#caps == 1 and "capability" or "capabilities")
    if perArg then
        return note .. "; omit this argument to use the rest of the tool without the grant."
    end
    return note .. "."
end

---@param desc string?
---@param note string
local function appendSentence(desc, note)
    desc = desc or ""
    if desc == "" then return note end
    return desc .. " " .. note
end

-- Returns `schema` with the auto cap-note appended to each gated arg's description.
-- Copies the touched tables so the caller's schema literal isn't mutated, so a
-- reload re-deriving from the raw description can't double-append.
---@param schema table
---@param argRequires table<string, string[]>?
local function annotateArgCaps(schema, argRequires)
    if not argRequires or type(schema) ~= "table" or type(schema.properties) ~= "table" then
        return schema
    end
    local props = {}
    for k, v in pairs(schema.properties) do props[k] = v end
    for argName, caps in pairs(argRequires) do
        local prop = props[argName]
        if type(prop) == "table" then
            local copy = {}
            for k, v in pairs(prop) do copy[k] = v end
            copy.description = appendSentence(copy.description, capNote(caps, true))
            props[argName] = copy
        end
    end
    local out = {}
    for k, v in pairs(schema) do out[k] = v end
    out.properties = props
    return out
end

---@param t mcp_function_def
function MCP:AddFunction(t)
    if type(t) ~= "table" then error("MCP:AddFunction expects a table", 2) end
    validateId("function", t.id)

    if type(t.handler) ~= "function" then
        error("MCP:AddFunction requires a handler function", 2)
    end

    local requires = t.requires or {}
    if type(requires) ~= "table" then
        error("MCP:AddFunction `requires` must be a list of capability ids", 2)
    end
    for _, capId in ipairs(requires) do
        if not self._capabilities[capId] then
            error("function `" .. t.id .. "` requires unknown capability `" .. capId .. "`", 2)
        end
    end

    -- Per-arg capability gates: { [argName] = { capId, ... } }. Lets an otherwise-
    -- ungated tool require a capability for a single powerful arg (e.g. a caller-Lua
    -- `until`); dispatch rejects that arg when ungranted, but the rest of the tool
    -- stays callable without the grant. Gated args must be declared schema
    -- properties, so a typo'd name fails loudly instead of silently never gating.
    local argRequires = t.arg_requires
    if argRequires ~= nil then
        if type(argRequires) ~= "table" then
            error("MCP:AddFunction `arg_requires` must be a map of arg name -> capability id list", 2)
        end
        local props = type(t.schema) == "table" and t.schema.properties or nil
        for argName, caps in pairs(argRequires) do
            if type(caps) ~= "table" then
                error("function `" .. t.id .. "` arg_requires['" .. tostring(argName) .. "'] must be a list of capability ids", 2)
            end
            for _, capId in ipairs(caps) do
                if not self._capabilities[capId] then
                    error("function `" .. t.id .. "` arg `" .. tostring(argName) .. "` requires unknown capability `" .. capId .. "`", 2)
                end
            end
            if type(props) ~= "table" or props[argName] == nil then
                error("function `" .. t.id .. "` arg_requires gates `" .. tostring(argName) .. "` which isn't a declared schema property", 2)
            end
        end
    end

    -- Optional per-tool request timeout (seconds): how long the .NET host waits for
    -- this tool's response before giving up. Long-running blocking handlers (e.g.
    -- player_walk) declare it so the host's default 10s doesn't cut them off; the
    -- host clamps it to its own sane maximum.
    local timeout = t.timeout
    if timeout ~= nil and (type(timeout) ~= "number" or timeout <= 0) then
        error("MCP:AddFunction `timeout` must be a positive number of seconds", 2)
    end

    local description = t.description or ""
    if #requires > 0 then
        description = appendSentence(description, capNote(requires, false))
    end

    self._functions[t.id] = {
        id = t.id,
        description = description,
        schema = annotateArgCaps(normalizeSchema(t.schema), argRequires),
        requires = requires,
        arg_requires = argRequires,
        handler = t.handler,
        realm = MCP.util.RealmName(),
        timeout = timeout,
        _generation = self._generation,
    }

    scheduleManifestWrite()
end

-- Resolve one capability id to its grant state: "ok", "missing" (not registered),
-- or "disabled" (registered but its convar is 0) + the convar name for the message.
---@param capId string
local function capGrant(self, capId)
    local cap = self._capabilities[capId]
    if not cap then return "missing" end
    if not GetConVar(cap.convar):GetBool() then return "disabled", cap.convar end
    return "ok"
end

-- Gate a call: the whole-tool `requires`, then any per-arg `arg_requires` whose arg
-- is actually present (an absent gated arg doesn't trip the gate, so the rest of an
-- otherwise-ungated tool stays usable without the grant). `args` may be nil.
---@param fn mcp_function_def
---@param args table?
function MCP:CheckCapabilities(fn, args)
    for _, capId in ipairs(fn.requires) do
        local state, convar = capGrant(self, capId)
        if state == "missing" then
            return false, "function references missing capability: " .. capId
        elseif state == "disabled" then
            return false, "capability disabled: " .. capId .. " (set " .. convar .. " 1 to enable)"
        end
    end

    if fn.arg_requires and type(args) == "table" then
        for argName, caps in pairs(fn.arg_requires) do
            if args[argName] ~= nil then
                for _, capId in ipairs(caps) do
                    local state, convar = capGrant(self, capId)
                    if state == "missing" then
                        return false, "`" .. argName .. "` references missing capability: " .. capId
                    elseif state == "disabled" then
                        return false, "`" .. argName .. "` requires the " .. capId ..
                            " capability (set " .. convar .. " 1 to enable); omit `" .. argName .. "` to use the rest of the tool"
                    end
                end
            end
        end
    end

    return true
end

-- Wraps a handler call so that anything written to the GMod console during
-- execution (print, Msg, MsgN, MsgC, ErrorNoHalt) and any non-fatal Lua errors
-- (caught via the OnLuaError hook — blocked-command warnings, ErrorNoHaltTrace
-- calls, etc.) are captured and surfaced back to the MCP caller. Without this,
-- engine-side warnings like "RunConsoleCommand: Command is blocked!" go to the
-- GMod console but never reach the MCP client.
---@param fn fun(args: table, ctx: mcp_ctx): table?
---@param args table
---@param ctx mcp_ctx
local function captureRun(fn, args, ctx)
    local output, warnings = {}, {}
    local origPrint, origMsg, origMsgN, origMsgC = print, Msg, MsgN, MsgC

    _G.print = function(...)
        local parts = {...}
        for i, v in ipairs(parts) do parts[i] = tostring(v) end
        output[#output + 1] = table.concat(parts, "\t") .. "\n"
        return origPrint(...)
    end
    _G.Msg = function(...)
        local parts = {...}
        for i, v in ipairs(parts) do parts[i] = tostring(v) end
        output[#output + 1] = table.concat(parts, "")
        return origMsg(...)
    end
    _G.MsgN = function(...)
        local parts = {...}
        for i, v in ipairs(parts) do parts[i] = tostring(v) end
        output[#output + 1] = table.concat(parts, "") .. "\n"
        return origMsgN(...)
    end
    ---@param color Color
    _G.MsgC = function(color, ...)
        local parts = {...}
        for i, v in ipairs(parts) do parts[i] = tostring(v) end
        output[#output + 1] = table.concat(parts, "")
        return origMsgC(color, ...)
    end

    local hookId = "MCP_ErrCapture"
    hook.Add("OnLuaError", hookId, function(errMsg)
        warnings[#warnings + 1] = tostring(errMsg)
    end)

    -- Tell the passive capture layer (sh_capture.lua) to stand down for the
    -- duration of the handler: its output is already captured above and goes
    -- into this response, so it must not also land in the passive ring.
    MCP._inDispatch = true
    local ok, ret = pcall(fn, args, ctx)
    MCP._inDispatch = false

    _G.print, _G.Msg, _G.MsgN, _G.MsgC = origPrint, origMsg, origMsgN, origMsgC
    hook.Remove("OnLuaError", hookId)

    return ok, ret, output, warnings
end

-- Format a Lua table for the level-2 debug log. Returns a compact JSON string,
-- or a placeholder if the encode fails (cyclic tables, userdata, etc.).
---@param t table?
local function safeEncode(t)
    if t == nil then return "nil" end
    local ok, enc = pcall(util.TableToJSON, MCP.util.Serialize(t), false)
    if ok and enc then return enc end
    return "<unencodable>"
end

---@param funcId string
---@param args table?
---@param response table
---@param elapsedMs number
local function logDispatch(funcId, args, response, elapsedMs)
    local level = GetConVar("mcp_debug"):GetInt()
    if level <= 0 then return end

    local realm = MCP.util.RealmName()
    local outcome = response.ok and "ok" or ("err: " .. tostring(response.error or "?"))
    MsgN(string.format("[MCP] %s.%s %s (%.1fms)", realm, funcId, outcome, elapsedMs))

    if level >= 2 then
        -- [MCP]-prefixed so passive capture (sh_capture.lua) filters these out.
        MsgN("[MCP]   args:   " .. safeEncode(args))
        MsgN("[MCP]   result: " .. safeEncode(response))
    end
end

-- The .NET host prefixes every request id with `<session>__` — one session GUID
-- per connected host. Exposed on ctx so tools can namespace per-caller state
-- (e.g. saved files) and concurrent hosts don't collide.
---@param reqId string
function MCP:SessionFromRequestId(reqId)
    local s = string.match(tostring(reqId), "^(.-)__")
    if not s or s == "" then s = tostring(reqId) end
    return s
end

-- Dispatch returns either a final response table (sync handler) or nil
-- (deferred). When nil, the handler is expected to call `ctx.respond(result)`
-- exactly once; the bridge passes a `respondLater` callback that writes that
-- response when it eventually arrives.
---@param funcId string
---@param args table?
---@param respondLater fun(response: table)?
---@param reqId string?
function MCP:Dispatch(funcId, args, respondLater, reqId)
    local startSec = SysTime()
    local response

    -- Master switch: bridge polling always runs, but tool execution requires
    -- explicit user consent via the mcp_enable convar.
    if not GetConVar("mcp_enable"):GetBool() then
        response = {
            ok = false,
            error = "MCP bridge is disabled. In the GMod console, run `mcp_enable 1` to allow tool dispatch.",
        }
    else
        local fn = self._functions[funcId]
        if not fn then
            response = { ok = false, error = "unknown function: " .. tostring(funcId) }
        else
            local capOk, capErr = self:CheckCapabilities(fn, args)
            if not capOk then
                response = { ok = false, error = capErr }
            else
                local resolved = false
                ---@type mcp_ctx
                local ctx = {
                    deferred = MCP._DEFERRED,
                    session = reqId and self:SessionFromRequestId(reqId) or nil,
                    respond = function(deferredResponse)
                        if resolved then return end
                        resolved = true
                        if type(deferredResponse) ~= "table" then
                            deferredResponse = {
                                ok = false,
                                error = "deferred handler must respond with a table; got " .. type(deferredResponse),
                            }
                        end
                        logDispatch(funcId, args, deferredResponse, (SysTime() - startSec) * 1000)
                        if respondLater then respondLater(deferredResponse) end
                    end,
                }

                local pcallOk, ret, output, warnings = captureRun(fn.handler, args or {}, ctx)

                if not pcallOk then
                    response = { ok = false, error = "handler error: " .. tostring(ret) }
                elseif ret == MCP._DEFERRED then
                    -- Async path: handler will call ctx.respond later. Console
                    -- output / warnings captured during the synchronous portion
                    -- are dropped because the response isn't ours to write.
                    return nil
                elseif type(ret) ~= "table" then
                    response = { ok = false, error = "handler must return a table; got " .. type(ret) }
                else
                    response = ret
                end

                if #output > 0 then
                    response.console = table.concat(output, "")
                end
                if #warnings > 0 then
                    response.warnings = warnings
                end
            end
        end
    end

    logDispatch(funcId, args, response, (SysTime() - startSec) * 1000)
    return response
end

function MCP:BuildManifest()
    local functions = {}
    for _, fn in pairs(self._functions) do
        functions[#functions + 1] = {
            id = fn.id,
            description = fn.description,
            schema = fn.schema,
            requires = fn.requires,
            realm = fn.realm,
            timeout = fn.timeout,
        }
    end

    local capabilities = {}
    for _, cap in pairs(self._capabilities) do
        capabilities[#capabilities + 1] = {
            id = cap.id,
            description = cap.description,
            default = cap.default,
            convar = cap.convar,
            current = GetConVar(cap.convar):GetBool(),
        }
    end

    return {
        realm = MCP.util.RealmName(),
        generation = self._generation,
        functions = functions,
        capabilities = capabilities,
    }
end

function MCP:WriteManifest()
    local path = "mcp/manifest_" .. MCP.util.RealmName() .. ".json"
    file.Write(path, MCP.util.JsonEncode(self:BuildManifest(), true))
end
