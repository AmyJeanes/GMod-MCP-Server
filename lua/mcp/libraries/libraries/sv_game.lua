-- MCP.game: the curated server-tuning knob table shared by game_state (reads them for its
-- `tuning` block) and game_set (writes them) -- one source of truth keeps the read/write pair
-- in sync. Each knob maps a friendly name to its convar and a clamp range. game_set stays
-- ungated precisely because this whitelist + clamping means it cannot do what the unsafe
-- general cvar_set can. `cheat` knobs are FCVAR_CHEAT: they need sv_cheats, and since game_set
-- never flips sv_cheats (that would be the escalation), they honestly report took=false when
-- it is off.
--
-- Server-only (both consumer tools are sv). The headless tool-list generator does not load
-- this file; fine -- both tools touch MCP.game only inside handlers, and game_set's knob
-- schema is an inline literal (no file-load reference).

MCP.game = MCP.game or {}

MCP.game.KNOBS = {
    gravity        = { convar = "sv_gravity",     min = 0,    max = 10000 },
    timescale      = { convar = "host_timescale", min = 0.01, max = 10,   cheat = true },
    phys_timescale = { convar = "phys_timescale", min = 0.01, max = 10 },
    fakelag        = { convar = "net_fakelag",    min = 0,    max = 1000, cheat = true },
}
