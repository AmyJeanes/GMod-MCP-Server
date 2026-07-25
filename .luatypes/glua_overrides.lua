---@meta

-- Type annotations only - never executed. The declarations below define real
-- globals and library functions with empty bodies, so loading this file at
-- runtime would replace working functions with stubs rather than declare them.
-- It lives outside lua/ so the game cannot reach it; this is the backstop.
error("glua_overrides.lua contains type annotations only and must never be executed")

-- Local annotation overrides for gaps in the provisioned GLua annotations.

-- Engine entity classes we spawn by name; declared so ents.Create's classname
-- template resolves a real type instead of hinting about an auto-created one.
---@class prop_dynamic : Entity