using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace GModMcpServer.Models;

/// <summary>
/// Request payload written into <c>garrysmod/data/mcp/&lt;realm&gt;/in/&lt;id&gt;.json</c>.
/// </summary>
public sealed class BridgeRequest
{
    [JsonPropertyName("id")]
    public string Id { get; init; } = "";

    [JsonPropertyName("function_id")]
    public string FunctionId { get; init; } = "";

    [JsonPropertyName("args")]
    public JsonNode? Args { get; init; }
}

/// <summary>
/// Response payload read from <c>garrysmod/data/mcp/&lt;realm&gt;/out/&lt;id&gt;.json</c>.
/// </summary>
public sealed class BridgeResponse
{
    [JsonPropertyName("id")]
    public string Id { get; init; } = "";

    [JsonPropertyName("result")]
    public JsonNode? Result { get; init; }
}
