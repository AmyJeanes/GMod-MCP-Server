-- cvar_state: structured snapshot of one ConVar -- current value (typed), default,
-- decoded FCVAR_* flags, help text and min/max bounds, in a single read. The read-half
-- of the cvar pair (cvar_set writes). Nil-safe: an unregistered name returns exists=false
-- rather than erroring (valid-as-data, like entity_state). Realm-aware: GetConVar reads
-- in this realm, so a replicated server convar is visible on the client but a client-only
-- convar isn't on the server. Ungated (structured read).

-- FCVAR_* flags decode via MCP.util.DecodeBits (shared with world_trace's CONTENTS_*).

MCP:AddFunction({
    id = "cvar_state",
    description = "Structured snapshot of one console variable -- its current value (as string/int/float/bool), default, decoded FCVAR_* flags, help text and min/max bounds, in a single read. The read-half of the cvar pair (cvar_set writes). Nil-safe: an unregistered name returns exists=false rather than erroring. Realm-aware -- GetConVar reads in this realm, so a replicated server convar's value is visible on the client but a client-only convar isn't on the server; query the realm you care about. Read-only. Runs in both realms.",
    schema = {
        type = "object",
        properties = {
            name = {
                type = "string",
                description = "ConVar name to inspect (e.g. \"sv_gravity\", \"mcp_enable\").",
            },
        },
        required = { "name" },
    },
    handler = function(args)
        args = args or {}
        local name = args.name
        if type(name) ~= "string" or name == "" then
            return { ok = false, error = "`name` must be a non-empty convar name" }
        end

        local cv = GetConVar(name)
        if not cv then
            return { ok = true, realm = MCP.util.RealmName(), name = name, exists = false }
        end

        local get = MCP.util.Getter(cv)
        local r = {
            ok = true,
            realm = MCP.util.RealmName(),
            name = name,
            exists = true,
            value = get("GetString"),
            int = get("GetInt"),
            float = get("GetFloat"),
            bool = get("GetBool"),
            default = get("GetDefault"),
            help = get("GetHelpText"),
        }

        local flags = get("GetFlags")
        if isnumber(flags) then
            r.flags_raw = flags
            r.flags = MCP.util.DecodeBits("FCVAR_", flags)
        end
        -- GetMin/GetMax return the bound or nil when unbounded; include only real numbers.
        local mn, mx = get("GetMin"), get("GetMax")
        if isnumber(mn) then r.min = mn end
        if isnumber(mx) then r.max = mx end

        return r
    end,
})
