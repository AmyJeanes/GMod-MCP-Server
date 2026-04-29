using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace GModMcpServer.Models;

/// <summary>
/// One-realm manifest emitted by GMod into <c>garrysmod/data/mcp/manifest_&lt;realm&gt;.json</c>.
/// The .NET host merges the two realms into a unified tool list.
/// </summary>
public sealed class RealmManifest
{
    [JsonPropertyName("realm")]
    public string Realm { get; init; } = "";

    [JsonPropertyName("generation")]
    public long Generation { get; init; }

    [JsonPropertyName("functions")]
    public List<FunctionEntry> Functions { get; init; } = new();

    [JsonPropertyName("capabilities")]
    public List<CapabilityEntry> Capabilities { get; init; } = new();
}

public sealed class FunctionEntry
{
    [JsonPropertyName("id")]
    public string Id { get; init; } = "";

    [JsonPropertyName("description")]
    public string Description { get; init; } = "";

    [JsonPropertyName("schema")]
    public JsonNode? Schema { get; init; }

    [JsonPropertyName("requires")]
    public List<string> Requires { get; init; } = new();

    [JsonPropertyName("realm")]
    public string Realm { get; init; } = "";
}

public sealed class CapabilityEntry
{
    [JsonPropertyName("id")]
    public string Id { get; init; } = "";

    [JsonPropertyName("description")]
    public string Description { get; init; } = "";

    [JsonPropertyName("default")]
    public bool Default { get; init; }

    [JsonPropertyName("convar")]
    public string ConVar { get; init; } = "";

    [JsonPropertyName("current")]
    public bool Current { get; init; }
}
