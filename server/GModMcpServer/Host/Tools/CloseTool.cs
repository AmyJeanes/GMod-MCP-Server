using System.Text.Json;
using System.Text.Json.Nodes;
using ModelContextProtocol.Protocol;

namespace GModMcpServer.Host.Tools;

public sealed class CloseTool : IHostTool
{
    private readonly GameProcessManager _proc;

    public CloseTool(GameProcessManager proc) { _proc = proc; }

    public string Name => "host_close";

    public string Description =>
        "Close the running GMod process (located by name, regardless of who launched it). " +
        "Tries CloseMainWindow first with a graceful timeout, then kills the process tree " +
        "if it does not exit in time.";

    public JsonElement InputSchema { get; } = HostToolHelpers.ParseSchema("""
    {
      "type": "object",
      "properties": {
        "graceful_seconds": { "type": "number", "description": "Seconds to wait for clean shutdown before killing (default: 3)." }
      },
      "required": []
    }
    """);

    public ValueTask<CallToolResult> InvokeAsync(IDictionary<string, JsonElement>? args, CancellationToken ct)
    {
        var seconds = 3.0;
        if (args is not null && args.TryGetValue("graceful_seconds", out var v)
            && v.ValueKind == JsonValueKind.Number && v.TryGetDouble(out var s))
        {
            seconds = Math.Max(0, s);
        }

        if (!_proc.IsRunning)
        {
            var notRunning = new JsonObject { ["ok"] = true, ["closed"] = false, ["reason"] = "no gmod.exe process is currently running" };
            return ValueTask.FromResult(HostToolHelpers.Ok(notRunning.ToJsonString()));
        }

        var closed = _proc.Close(TimeSpan.FromSeconds(seconds));
        var result = new JsonObject { ["ok"] = closed, ["closed"] = closed };
        return ValueTask.FromResult(closed ? HostToolHelpers.Ok(result.ToJsonString()) : HostToolHelpers.Err(result.ToJsonString()));
    }
}
