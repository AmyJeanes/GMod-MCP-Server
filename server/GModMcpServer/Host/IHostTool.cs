using System.Text.Json;
using ModelContextProtocol.Protocol;

namespace GModMcpServer.Host;

/// <summary>
/// A tool implemented by the .NET MCP server itself, not dispatched to GMod.
/// Used for things that exist outside the game process — launching it,
/// closing it, reporting its status.
/// </summary>
public interface IHostTool
{
    /// <summary>The MCP tool name (final, no `_sv` / `_cl` suffix added).</summary>
    string Name { get; }

    /// <summary>One-line description shown in the MCP tool list.</summary>
    string Description { get; }

    /// <summary>JSON schema for the tool's <c>arguments</c>.</summary>
    JsonElement InputSchema { get; }

    ValueTask<CallToolResult> InvokeAsync(
        IDictionary<string, JsonElement>? arguments,
        CancellationToken ct);
}
