using System.Text.Json;
using GModMcpServer.Models;
using Microsoft.Extensions.Logging;

namespace GModMcpServer.Bridge;

/// <summary>
/// Watches the per-realm manifest files written by GMod, merges them, and raises
/// an event when the merged tool set changes (used to emit
/// <c>notifications/tools/list_changed</c>).
/// </summary>
public sealed class ManifestWatcher : IDisposable
{
    private readonly string _mcpRoot;
    private readonly ILogger _log;
    private readonly FileSystemWatcher _watcher;
    private readonly object _gate = new();
    private MergedManifest _current = new();

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    public event EventHandler<MergedManifest>? Changed;

    public MergedManifest Current
    {
        get { lock (_gate) return _current; }
    }

    public ManifestWatcher(string mcpRoot, ILogger log)
    {
        _mcpRoot = mcpRoot;
        _log = log;
        Directory.CreateDirectory(_mcpRoot);

        _watcher = new FileSystemWatcher(_mcpRoot, "manifest_*.json")
        {
            NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size,
            EnableRaisingEvents = true,
        };
        _watcher.Created += (_, _) => Reload();
        _watcher.Changed += (_, _) => Reload();
        _watcher.Deleted += (_, _) => Reload();

        Reload();
    }

    private void Reload()
    {
        try
        {
            var merged = LoadAndMerge();
            bool changed;
            lock (_gate)
            {
                changed = !merged.Equals(_current);
                if (changed) _current = merged;
            }
            if (changed)
            {
                _log.LogInformation("Manifest changed: {ToolCount} tools, {CapabilityCount} capabilities",
                    merged.Tools.Count, merged.Capabilities.Count);
                Changed?.Invoke(this, merged);
            }
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "Failed to reload manifest");
        }
    }

    private MergedManifest LoadAndMerge()
    {
        var merged = new MergedManifest();
        foreach (var realm in new[] { "server", "client" })
        {
            var path = Path.Combine(_mcpRoot, $"manifest_{realm}.json");
            if (!File.Exists(path)) continue;

            try
            {
                var raw = File.ReadAllText(path);
                if (string.IsNullOrWhiteSpace(raw)) continue;

                var manifest = JsonSerializer.Deserialize<RealmManifest>(raw, JsonOpts);
                if (manifest == null) continue;

                foreach (var fn in manifest.Functions)
                {
                    var toolName = fn.Id + (realm == "server" ? "_sv" : "_cl");
                    merged.Tools[toolName] = new ToolDescriptor(toolName, fn.Id, realm, fn);
                }
                foreach (var cap in manifest.Capabilities)
                {
                    // Capabilities are realm-independent in concept; both realms may declare the same
                    // capability id. Last-write wins; current state from whichever realm wrote latest.
                    merged.Capabilities[cap.Id] = cap;
                }
            }
            catch (Exception ex)
            {
                _log.LogWarning(ex, "Failed to parse manifest for realm {Realm}", realm);
            }
        }
        return merged;
    }

    public void Dispose()
    {
        _watcher.EnableRaisingEvents = false;
        _watcher.Dispose();
    }
}

public sealed record ToolDescriptor(string McpName, string FunctionId, string Realm, FunctionEntry Entry);

public sealed class MergedManifest
{
    public Dictionary<string, ToolDescriptor> Tools { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, CapabilityEntry> Capabilities { get; } = new(StringComparer.Ordinal);

    public bool Equals(MergedManifest? other)
    {
        if (other is null) return false;
        if (Tools.Count != other.Tools.Count) return false;
        if (Capabilities.Count != other.Capabilities.Count) return false;

        foreach (var kv in Tools)
        {
            if (!other.Tools.TryGetValue(kv.Key, out var rhs)) return false;
            if (!ToolEquals(kv.Value, rhs)) return false;
        }
        foreach (var kv in Capabilities)
        {
            if (!other.Capabilities.TryGetValue(kv.Key, out var rhs)) return false;
            if (!CapabilityEquals(kv.Value, rhs)) return false;
        }
        return true;
    }

    private static bool ToolEquals(ToolDescriptor a, ToolDescriptor b)
    {
        if (a.Realm != b.Realm) return false;
        if (a.FunctionId != b.FunctionId) return false;
        if (a.Entry.Description != b.Entry.Description) return false;
        if (!StringListEquals(a.Entry.Requires, b.Entry.Requires)) return false;
        return SchemaEquals(a.Entry.Schema, b.Entry.Schema);
    }

    private static bool CapabilityEquals(CapabilityEntry a, CapabilityEntry b)
    {
        return a.Id == b.Id
            && a.Description == b.Description
            && a.Default == b.Default
            && a.ConVar == b.ConVar
            && a.Current == b.Current;
    }

    private static bool StringListEquals(List<string> a, List<string> b)
    {
        if (a.Count != b.Count) return false;
        for (var i = 0; i < a.Count; i++)
        {
            if (!string.Equals(a[i], b[i], StringComparison.Ordinal)) return false;
        }
        return true;
    }

    private static bool SchemaEquals(System.Text.Json.Nodes.JsonNode? a, System.Text.Json.Nodes.JsonNode? b)
    {
        if (a is null && b is null) return true;
        if (a is null || b is null) return false;
        return string.Equals(a.ToJsonString(), b.ToJsonString(), StringComparison.Ordinal);
    }
}
