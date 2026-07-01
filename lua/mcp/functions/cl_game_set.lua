-- game_set_cl: curated client-only game knobs -- the client counterpart of game_set_sv
-- (same id "game_set", realm-disjoint files, so the framework registers game_set_sv and
-- game_set_cl separately). game_set_sv drives the shared server convar knobs; the client
-- has its own client-only levers that don't fit a convar.
--
-- Ungated for the same reason as game_set_sv: each knob is a curated, bounded lever (here,
-- one specific function replacement), not arbitrary code -- so it can't escalate like the
-- unsafe cvar_set/lua_run.
--
-- background_render: many addons stop rendering while the window is unfocused by gating
-- their render hooks on system.HasFocus() (world-portals and vrmod both do -- the scan found
-- ~26 hand-rolled `system.HasFocus = function() return true end` patches). This overrides
-- system.HasFocus to always report focused so that clientside rendering keeps running while
-- the game is backgrounded (e.g. so a screenshot of a portal surface stays live). It does NOT
-- raise the backgrounded frame rate (that's fps_max_nofocus, which is Lua-unsettable) -- it
-- only unblocks Lua that gates on HasFocus. The genuine window focus is still reported
-- separately via the saved original, so the override is never mistaken for real focus.

MCP:AddFunction({
    id = "game_set",
    description = "Set curated client-only game knobs, then confirm. The client counterpart of game_set_sv (which sets the shared server convar knobs like gravity/timescale). Supply at least one knob. `background_render`: override system.HasFocus() so clientside rendering that is gated on window focus keeps running while the game is backgrounded -- many addons (world-portals, vrmod) stop rendering when unfocused, and this unblocks them (e.g. to keep a portal surface or VR view live for a backgrounded screenshot). true installs the override (system.HasFocus always reports focused); false restores the original. It does NOT raise the backgrounded frame rate (that is fps_max_nofocus, which no Lua path can set) -- it only unblocks focus-gated Lua. The report distinguishes what HasFocus now reports (has_focus_reported) from the real window focus (real_has_focus, read through the saved original), so the override is never mistaken for genuine focus. Ungated (a bounded, specific lever, not arbitrary code).",
    schema = {
        type = "object",
        properties = {
            background_render = {
                type = "boolean",
                description = "true = override system.HasFocus() to always report focused, so focus-gated clientside rendering keeps running while backgrounded; false = restore the original system.HasFocus. Does not change the frame rate, only unblocks Lua that checks HasFocus.",
            },
        },
    },
    handler = function(args)
        args = args or {}

        if args.background_render == nil then
            return { ok = false, error = "game_set_cl needs a knob: background_render" }
        end

        local applied = {}
        if args.background_render ~= nil then
            local enable = args.background_render == true
            if enable then
                -- Save the genuine system.HasFocus once, then override. MCP._origHasFocus
                -- persists across mcp_reload (in-memory), so re-enabling is idempotent and
                -- we never lose the real function under a double-patch.
                if not MCP._origHasFocus then MCP._origHasFocus = system.HasFocus end
                system.HasFocus = function() return true end
            elseif MCP._origHasFocus then
                system.HasFocus = MCP._origHasFocus
                MCP._origHasFocus = nil
            end
            applied[#applied + 1] = "background_render"
        end

        local patched = MCP._origHasFocus ~= nil
        -- Read the true window focus through the saved original when patched, so the report
        -- tells real focus apart from the override.
        local realFocus = patched and MCP._origHasFocus() or system.HasFocus()

        return {
            ok = true,
            realm = MCP.util.RealmName(),
            applied = applied,
            background_render = patched,
            has_focus_reported = system.HasFocus() == true,
            real_has_focus = realFocus == true,
        }
    end,
})
