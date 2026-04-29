using ModelContextProtocol.Server;

namespace GModMcpServer.Bridge;

/// <summary>
/// Singleton holder that captures the live <see cref="McpServer"/> reference once
/// the SDK starts handling requests. The SDK doesn't expose its server instance via
/// DI directly, but every <see cref="RequestContext{T}"/> carries a Server property —
/// so the tool handlers in <c>Program.cs</c> populate this accessor on first call.
/// Used by <c>BridgeHostedService</c> to push <c>notifications/tools/list_changed</c>
/// to the connected client when the GMod manifest changes.
/// </summary>
public sealed class McpServerAccessor
{
    private McpServer? _server;

    public McpServer? Server => _server;

    public void TrySet(McpServer? server)
    {
        if (server is null) return;
        Interlocked.CompareExchange(ref _server, server, null);
    }
}
