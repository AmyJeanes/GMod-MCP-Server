-- Registry: AddCapability, AddFunction, dispatch, manifest emission.

MCP._functions = MCP._functions or {}
MCP._capabilities = MCP._capabilities or {}

-- Sentinel returned by an async handler to tell the bridge "don't write a
-- response yet — I'll deliver one via ctx.respond". Exposed as `ctx.deferred`
-- so handler code never has to reach into MCP internals.
MCP._DEFERRED = MCP._DEFERRED or {}

-- Capabilities replicate server -> client so toggling on the server propagates to clients.
-- FCVAR_ARCHIVE so the user's capability grants persist across game restarts.
local CAP_FLAGS = { FCVAR_PROTECTED, FCVAR_DONTRECORD, FCVAR_REPLICATED, FCVAR_ARCHIVE }

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

function MCP:CapabilityConVarName(id)
    return "mcp_allow_" .. id
end

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
local function normalizeSchema(s)
    if type(s) ~= "table" then return { type = "object" } end
    local out = {}
    for k, v in pairs(s) do out[k] = v end
    if type(out.properties) == "table" and next(out.properties) == nil then
        out.properties = nil
    end
    return out
end

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

    self._functions[t.id] = {
        id = t.id,
        description = t.description or "",
        schema = normalizeSchema(t.schema),
        requires = requires,
        handler = t.handler,
        realm = MCP.util.RealmName(),
        _generation = self._generation,
    }

    scheduleManifestWrite()
end

function MCP:CheckCapabilities(fn)
    for _, capId in ipairs(fn.requires) do
        local cap = self._capabilities[capId]
        if not cap then
            return false, "function references missing capability: " .. capId
        end
        if not GetConVar(cap.convar):GetBool() then
            return false, "capability disabled: " .. capId .. " (set " .. cap.convar .. " 1 to enable)"
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

    local ok, ret = pcall(fn, args, ctx)

    _G.print, _G.Msg, _G.MsgN, _G.MsgC = origPrint, origMsg, origMsgN, origMsgC
    hook.Remove("OnLuaError", hookId)

    return ok, ret, output, warnings
end

-- Format a Lua table for the level-2 debug log. Returns a compact JSON string,
-- or a placeholder if the encode fails (cyclic tables, userdata, etc.).
local function safeEncode(t)
    if t == nil then return "nil" end
    local ok, enc = pcall(util.TableToJSON, t, false)
    if ok and enc then return enc end
    return "<unencodable>"
end

local function logDispatch(funcId, args, response, elapsedMs)
    local level = GetConVar("mcp_debug"):GetInt()
    if level <= 0 then return end

    local realm = MCP.util.RealmName()
    local outcome = response.ok and "ok" or ("err: " .. tostring(response.error or "?"))
    MsgN(string.format("[MCP] %s.%s %s (%.1fms)", realm, funcId, outcome, elapsedMs))

    if level >= 2 then
        MsgN("  args:   " .. safeEncode(args))
        MsgN("  result: " .. safeEncode(response))
    end
end

-- Dispatch returns either a final response table (sync handler) or nil
-- (deferred). When nil, the handler is expected to call `ctx.respond(result)`
-- exactly once; the bridge passes a `respondLater` callback that writes that
-- response when it eventually arrives.
function MCP:Dispatch(funcId, args, respondLater)
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
            local capOk, capErr = self:CheckCapabilities(fn)
            if not capOk then
                response = { ok = false, error = capErr }
            else
                local resolved = false
                local ctx = {
                    deferred = MCP._DEFERRED,
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
