using System.Text;
using System.Text.Json.Nodes;
using GModMcpServer.Host;
using GModMcpServer.ToolList;

// Regenerates the auto-managed tool tables in README.md from two sources:
//   * .NET host tools   -> HostToolCatalog (reflection of the server's own tools)
//   * GMod bridge tools -> LuaToolDump    (the addon's registration code under MoonSharp)
// ONLY the tables are generated — all surrounding prose is normal README text.
// Neither source needs a running game. Usage:
//   dotnet run --project server/GModMcpServer.ToolList [repoRoot] [--check]
// --check exits non-zero if README.md is out of date (for CI/PRs) instead of writing.

var check = args.Contains("--check");
var rootArg = args.FirstOrDefault(a => !a.StartsWith("--", StringComparison.Ordinal));
var repoRoot = FindRepoRoot(rootArg);

var serverManifest = LuaToolDump.LoadRealm(repoRoot, "server");
var clientManifest = LuaToolDump.LoadRealm(repoRoot, "client");

var bridgeTools = ExtractBridgeTools(serverManifest).Concat(ExtractBridgeTools(clientManifest))
    .OrderBy(t => t.McpName, StringComparer.Ordinal)
    .ToList();
var capabilities = ExtractCapabilities(serverManifest).Concat(ExtractCapabilities(clientManifest))
    .GroupBy(c => c.Id).Select(g => g.First())
    .OrderBy(c => c.Id, StringComparer.Ordinal)
    .ToList();
var hostTools = HostToolCatalog.Describe();

var readmePath = Path.Combine(repoRoot, "README.md");
var readme = File.ReadAllText(readmePath);
var nl = readme.Contains("\r\n", StringComparison.Ordinal) ? "\r\n" : "\n";

var rebuilt = readme;
rebuilt = Splice(rebuilt, "TOOLS:HOST", RenderHostTable(hostTools, nl), nl);
rebuilt = Splice(rebuilt, "TOOLS:GAME", RenderGameTable(bridgeTools, nl), nl);
rebuilt = Splice(rebuilt, "TOOLS:CAPS", RenderCapsTable(capabilities, nl), nl);

if (check)
{
    if (rebuilt == readme)
    {
        Console.WriteLine("README tool tables are up to date.");
        return 0;
    }
    Console.Error.WriteLine(
        "README tool tables are OUT OF DATE. Run: dotnet run --project server/GModMcpServer.ToolList");
    return 1;
}

if (rebuilt == readme)
{
    Console.WriteLine("README tool tables already up to date — no change.");
    return 0;
}

File.WriteAllText(readmePath, rebuilt);
Console.WriteLine(
    $"Updated README tool tables: {hostTools.Count} host, {bridgeTools.Count} game, {capabilities.Count} capabilities.");
return 0;

// ---------------------------------------------------------------------------

static string FindRepoRoot(string? explicitArg)
{
    if (!string.IsNullOrEmpty(explicitArg)) return Path.GetFullPath(explicitArg);
    var dir = new DirectoryInfo(AppContext.BaseDirectory);
    while (dir != null)
    {
        if (Directory.Exists(Path.Combine(dir.FullName, "lua", "mcp", "functions"))
            && File.Exists(Path.Combine(dir.FullName, "README.md")))
        {
            return dir.FullName;
        }
        dir = dir.Parent;
    }
    throw new InvalidOperationException(
        "Could not locate the repo root (a folder with lua/mcp/functions and README.md). Pass it as an argument.");
}

static IEnumerable<BridgeTool> ExtractBridgeTools(JsonObject manifest)
{
    var realm = (string)manifest["realm"]!;
    var suffix = realm == "server" ? "_sv" : "_cl";
    foreach (var node in (JsonArray)manifest["functions"]!)
    {
        var fn = (JsonObject)node!;
        var id = (string)fn["id"]!;
        var requires = (fn["requires"] as JsonArray ?? new JsonArray())
            .Select(r => (string)r!).ToArray();
        yield return new BridgeTool(
            id + suffix, realm, requires, (string)fn["description"]!);
    }
}

static IEnumerable<CapabilityInfo> ExtractCapabilities(JsonObject manifest)
{
    foreach (var node in (JsonArray)manifest["capabilities"]!)
    {
        var cap = (JsonObject)node!;
        yield return new CapabilityInfo(
            (string)cap["id"]!,
            (string)cap["convar"]!,
            cap["default"]?.GetValue<bool>() ?? false,
            (string)cap["description"]!);
    }
}

static string RenderHostTable(IReadOnlyList<HostToolInfo> tools, string nl)
{
    var sb = new StringBuilder();
    sb.Append("| Tool | Description |").Append(nl);
    sb.Append("| --- | --- |");
    foreach (var t in tools)
        sb.Append(nl).Append($"| `{t.Name}` | {Cell(FirstSentence(t.Description))} |");
    return sb.ToString();
}

static string RenderGameTable(IReadOnlyList<BridgeTool> tools, string nl)
{
    var sb = new StringBuilder();
    sb.Append("| Tool | Realm | Requires | Description |").Append(nl);
    sb.Append("| --- | --- | --- | --- |");
    foreach (var t in tools)
    {
        var req = t.Requires.Count > 0
            ? string.Join(", ", t.Requires.Select(r => $"`{r}`"))
            : "—";
        sb.Append(nl).Append($"| `{t.McpName}` | {t.Realm} | {req} | {Cell(FirstSentence(t.Description))} |");
    }
    return sb.ToString();
}

static string RenderCapsTable(IReadOnlyList<CapabilityInfo> caps, string nl)
{
    var sb = new StringBuilder();
    sb.Append("| Capability | ConVar | Default | Description |").Append(nl);
    sb.Append("| --- | --- | --- | --- |");
    foreach (var c in caps)
        sb.Append(nl).Append($"| `{c.Id}` | `{c.ConVar}` | {(c.Default ? "on" : "off")} | {Cell(FirstSentence(c.Description))} |");
    return sb.ToString();
}

// Replace the content between <!-- name:START --> and <!-- name:END --> with body.
static string Splice(string readme, string name, string body, string nl)
{
    var start = $"<!-- {name}:START -->";
    var end = $"<!-- {name}:END -->";
    var s = readme.IndexOf(start, StringComparison.Ordinal);
    var e = readme.IndexOf(end, StringComparison.Ordinal);
    if (s < 0 || e < 0 || e < s)
    {
        throw new InvalidOperationException(
            $"README.md must contain the markers {start} and {end} (in that order).");
    }
    return readme[..(s + start.Length)] + nl + body + nl + readme[e..];
}

// Markdown table cell: collapse newlines and escape pipes.
static string Cell(string s) =>
    s.Replace("\r", " ").Replace("\n", " ").Replace("|", "\\|").Trim();

static string FirstSentence(string s)
{
    var i = s.IndexOf(". ", StringComparison.Ordinal);
    return i > 0 ? s[..(i + 1)] : s;
}

internal sealed record BridgeTool(string McpName, string Realm, IReadOnlyList<string> Requires, string Description);
internal sealed record CapabilityInfo(string Id, string ConVar, bool Default, string Description);
