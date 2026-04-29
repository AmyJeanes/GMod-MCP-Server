using System.Text.Json;
using System.Text.Json.Nodes;
using ModelContextProtocol.Protocol;

namespace GModMcpServer.Host.Tools;

public sealed class LaunchTool : IHostTool
{
    private readonly GameProcessManager _proc;

    public LaunchTool(GameProcessManager proc) { _proc = proc; }

    public string Name => "host_launch";

    public string Description =>
        "Launch Garry's Mod. Defaults: gm_construct map, sandbox, windowed 1280x720, console open. " +
        "The MCP bridge does NOT auto-enable; once GMod is running, the user must opt in via " +
        "`mcp_enable 1` in the developer console (and any required capability convars).";

    public JsonElement InputSchema { get; } = HostToolHelpers.ParseSchema("""
    {
      "type": "object",
      "properties": {
        "map":         { "type": "string",  "description": "Map to load on boot (default: gm_construct). NOTE: Workshop maps cannot be loaded via +map — they don't mount in time. Use a map under garrysmod/maps/ (or in the engine's built-ins), or pass an empty string to boot to the main menu." },
        "gamemode":    { "type": "string",  "description": "Gamemode (default: sandbox)." },
        "console":     { "type": "boolean", "description": "Open the developer console window (default: true)." },
        "windowed":    { "type": "boolean", "description": "Run windowed instead of fullscreen (default: true)." },
        "width":       { "type": "integer", "description": "Window width (default: 1280)." },
        "height":      { "type": "integer", "description": "Window height (default: 720)." },
        "extra_args":  { "type": "array",   "items": { "type": "string" }, "description": "Extra arguments appended verbatim to the gmod.exe command line." }
      },
      "required": []
    }
    """);

    public ValueTask<CallToolResult> InvokeAsync(IDictionary<string, JsonElement>? args, CancellationToken ct)
    {
        var map = HostToolHelpers.GetString(args, "map", "gm_construct");
        var gamemode = HostToolHelpers.GetString(args, "gamemode", "sandbox");
        var console = HostToolHelpers.GetBool(args, "console", true);
        var windowed = HostToolHelpers.GetBool(args, "windowed", true);
        var width = HostToolHelpers.GetInt(args, "width", 1280);
        var height = HostToolHelpers.GetInt(args, "height", 720);
        var extra = HostToolHelpers.GetStringArray(args, "extra_args");

        var argList = new List<string>
        {
            "-game", "garrysmod",
            "-novid",
            "+sv_lan", "1",
        };

        if (console) argList.Add("-console");
        if (windowed)
        {
            argList.Add("-windowed");
            argList.Add("-w"); argList.Add(width.ToString());
            argList.Add("-h"); argList.Add(height.ToString());
        }
        if (!string.IsNullOrEmpty(gamemode))
        {
            argList.Add("+gamemode"); argList.Add(gamemode);
        }
        argList.AddRange(extra);
        if (!string.IsNullOrEmpty(map))
        {
            argList.Add("+map"); argList.Add(map);
        }

        try
        {
            var p = _proc.Launch(argList);
            var result = new JsonObject
            {
                ["ok"] = true,
                ["pid"] = p.Id,
                ["args"] = string.Join(" ", argList),
                ["note"] = "GMod is launching. Once loaded, run `mcp_enable 1` (and any required capability convars, e.g. `mcp_allow_lua_eval 1`) in the developer console to enable tool dispatch.",
            };
            return ValueTask.FromResult(HostToolHelpers.Ok(result.ToJsonString()));
        }
        catch (Exception ex)
        {
            var result = new JsonObject { ["ok"] = false, ["error"] = ex.Message };
            return ValueTask.FromResult(HostToolHelpers.Err(result.ToJsonString()));
        }
    }
}
