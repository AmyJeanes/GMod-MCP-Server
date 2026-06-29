using System.Text.Json;
using GModMcpServer.Host.Tools;

namespace GModMcpServer.Host;

/// <summary>Static metadata for a host tool — name, description, argument schema — independent of a live host.</summary>
public sealed record HostToolInfo(string Name, string Description, JsonElement InputSchema);

/// <summary>
/// The single registry of host-tool types. Program.cs registers these for DI;
/// the tool-list generator reflects their metadata via <see cref="Describe"/>.
/// Adding a host tool means adding it here once — both paths pick it up.
/// </summary>
public static class HostToolCatalog
{
    public static readonly IReadOnlyList<Type> ToolTypes = new[]
    {
        typeof(LaunchTool),
        typeof(CloseTool),
        typeof(StatusTool),
        typeof(ChangeLevelTool),
    };

    /// <summary>
    /// Build each tool with throwaway constructor dependencies and read its
    /// metadata. Safe because a host tool's Name/Description/InputSchema never
    /// read their injected services — only <c>BridgePaths.McpRoot</c> is touched
    /// in a constructor, so that one dependency is supplied. If a future tool
    /// reads a service to compute its schema this throws (caught in CI), the cue
    /// to hand it a real dependency here.
    /// </summary>
    public static IReadOnlyList<HostToolInfo> Describe()
    {
        var infos = new List<HostToolInfo>();
        foreach (var type in ToolTypes)
        {
            var tool = Construct(type);
            infos.Add(new HostToolInfo(tool.Name, tool.Description, tool.InputSchema));
        }
        return infos;
    }

    private static IHostTool Construct(Type type)
    {
        var ctor = type.GetConstructors().Single();
        var args = ctor.GetParameters()
            .Select(p => p.ParameterType == typeof(BridgePaths)
                ? (object?)new BridgePaths("", "", "")
                : null)
            .ToArray();
        return (IHostTool)ctor.Invoke(args);
    }
}
