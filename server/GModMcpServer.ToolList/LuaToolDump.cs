using System.Text.Json.Nodes;
using MoonSharp.Interpreter;

namespace GModMcpServer.ToolList;

/// <summary>
/// Recovers each realm's tool manifest by running the addon's real
/// tool-registration code headlessly under MoonSharp — no GMod, no game state.
///
/// Tool registration is pure data: <c>MCP:AddFunction</c> only stores the table
/// (the handler is never called), so a minimal stub environment plus the real
/// framework + tool files is enough to reproduce exactly what GMod writes to
/// <c>manifest_&lt;realm&gt;.json</c>. We load each tool file with the same realm
/// dispatch GMod uses (sh_ in both realms, sv_ server-only, cl_ client-only) so
/// realm-conditional descriptions and schemas resolve correctly, then call the
/// framework's own <c>MCP:BuildManifest()</c>.
/// </summary>
internal static class LuaToolDump
{
    /// <summary>Run registration for one realm and return its BuildManifest() output.</summary>
    public static JsonObject LoadRealm(string repoRoot, string realm)
    {
        var script = new Script(CoreModules.Preset_SoftSandbox);
        script.DoString(Prelude(realm), null, "prelude");

        foreach (var f in FrameworkFiles(repoRoot))
            script.DoString(File.ReadAllText(f), null, Path.GetFileName(f));
        foreach (var f in FunctionFiles(repoRoot, realm))
            script.DoString(File.ReadAllText(f), null, Path.GetFileName(f));

        var res = script.DoString("return MCP:BuildManifest()");
        return (JsonObject)Convert(res)!;
    }

    private static IEnumerable<string> FrameworkFiles(string repoRoot)
    {
        var lib = Path.Combine(repoRoot, "lua", "mcp", "libraries");
        yield return Path.Combine(lib, "libraries", "sh_util.lua");
        yield return Path.Combine(lib, "libraries", "sh_module.lua");
        yield return Path.Combine(lib, "sh_capabilities.lua");
    }

    private static IEnumerable<string> FunctionFiles(string repoRoot, string realm)
    {
        var dir = Path.Combine(repoRoot, "lua", "mcp", "functions");
        var allowed = realm == "server"
            ? new[] { "sh", "sv" }
            : new[] { "sh", "cl" };
        return Directory.GetFiles(dir, "*.lua")
            .Where(f =>
            {
                var name = Path.GetFileName(f);
                var us = name.IndexOf('_');
                return us > 0 && allowed.Contains(name[..us]);
            })
            .OrderBy(f => f, StringComparer.Ordinal);
    }

    // Stub environment: only what the tool files touch at file-load (registration)
    // time. Everything else lives inside handlers, which never run here.
    private static string Prelude(string realm) => $$"""
        SERVER = {{(realm == "server" ? "true" : "false")}}
        CLIENT = {{(realm == "client" ? "true" : "false")}}

        -- GMod constants referenced at registration time.
        MOVETYPE_NONE=0 MOVETYPE_ISOMETRIC=1 MOVETYPE_WALK=2 MOVETYPE_STEP=3
        MOVETYPE_FLY=4 MOVETYPE_FLYGRAVITY=5 MOVETYPE_VPHYSICS=6 MOVETYPE_PUSH=7
        MOVETYPE_NOCLIP=8 MOVETYPE_LADDER=9 MOVETYPE_OBSERVER=10 MOVETYPE_CUSTOM=11
        FCVAR_PROTECTED=32 FCVAR_DONTRECORD=131072 FCVAR_REPLICATED=8192 FCVAR_ARCHIVE=128

        -- No-op subsystems touched during registration.
        hook = { Add = function() end, Remove = function() end }
        timer = { Create = function() end, Simple = function() end, Remove = function() end }

        -- ConVar shim backing capability gates.
        local __convars = {}
        function ConVarExists(n) return __convars[n] ~= nil end
        function CreateConVar(n, default, flags, help)
            local cv = { _v = default }
            function cv:GetBool() return self._v == "1" or self._v == true end
            function cv:GetInt() return tonumber(self._v) or 0 end
            function cv:GetFloat() return tonumber(self._v) or 0 end
            function cv:GetString() return tostring(self._v) end
            __convars[n] = cv
            return cv
        end
        function GetConVar(n) return __convars[n] end

        -- GMod math extensions (cheap insurance; not used at load today).
        function math.Clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi else return v end end
        function math.Round(v, d) d = d or 0 local m = 10 ^ d return math.floor(v * m + 0.5) / m end

        MCP = {}
        """;

    // MoonSharp value -> System.Text.Json. Empty Lua tables become JSON arrays,
    // matching GMod's util.TableToJSON (e.g. an empty `requires`).
    private static JsonNode? Convert(DynValue v)
    {
        switch (v.Type)
        {
            case DataType.Nil:
            case DataType.Void:
                return null;
            case DataType.Boolean:
                return JsonValue.Create(v.Boolean);
            case DataType.Number:
                var d = v.Number;
                if (!double.IsInfinity(d) && d == Math.Floor(d) && Math.Abs(d) < 9.2e18)
                    return JsonValue.Create((long)d);
                return JsonValue.Create(d);
            case DataType.String:
                return JsonValue.Create(v.String);
            case DataType.Table:
                var t = v.Table;
                var len = t.Length;
                var total = t.Pairs.Count();
                if (total == len) // pure sequence (incl. empty) -> array
                {
                    var arr = new JsonArray();
                    for (var i = 1; i <= len; i++)
                        arr.Add(Convert(t.Get(i)));
                    return arr;
                }
                var obj = new JsonObject();
                foreach (var pair in t.Pairs)
                {
                    if (pair.Key.Type != DataType.String) continue;
                    var cv = Convert(pair.Value);
                    if (cv != null) obj[pair.Key.String] = cv;
                }
                return obj;
            default:
                return JsonValue.Create(v.ToPrintString());
        }
    }
}
