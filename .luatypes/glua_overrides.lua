---@meta

-- Type annotations only - never executed. The declarations below define real
-- globals and library functions with empty bodies, so loading this file at
-- runtime would replace working functions with stubs rather than declare them.
-- It lives outside lua/ so the game cannot reach it; this is the backstop.
error("glua_overrides.lua contains type annotations only and must never be executed")

-- Local annotation overrides for gaps in the provisioned GLua annotations.

-- The annotations model stock Lua's 3-arg debug.getinfo(thread, f, what) as the base
-- signature and GMod's (funcOrStackLevel, fields) as overloads. Overloads only resolve
-- at a direct call, so passing it to pcall falls back to the base and lands the function
-- in the thread slot. Declare GMod's form as the base instead.
---@param funcOrStackLevel function|integer
---@param fields? string
---@return debuglib.DebugInfo
function debug.getinfo(funcOrStackLevel, fields) end

-- Engine entity classes we spawn by name; declared so ents.Create's classname
-- template resolves a real type instead of hinting about an auto-created one.
---@class prop_dynamic : Entity