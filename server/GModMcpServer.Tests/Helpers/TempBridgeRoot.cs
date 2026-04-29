namespace GModMcpServer.Tests.Helpers;

/// <summary>
/// Disposable temp directory laid out like <c>garrysmod/data/mcp/</c> so tests can
/// drive <see cref="GModMcpServer.Bridge.FileBridge"/> and
/// <see cref="GModMcpServer.Bridge.ManifestWatcher"/> without touching the real game.
/// </summary>
internal sealed class TempBridgeRoot : IDisposable
{
	public string McpRoot { get; }

	public TempBridgeRoot()
	{
		McpRoot = Path.Combine(Path.GetTempPath(), "gmod-mcp-tests-" + Guid.NewGuid().ToString("N"));
		Directory.CreateDirectory(McpRoot);
		Directory.CreateDirectory(Path.Combine(McpRoot, "server", "in"));
		Directory.CreateDirectory(Path.Combine(McpRoot, "server", "out"));
		Directory.CreateDirectory(Path.Combine(McpRoot, "client", "in"));
		Directory.CreateDirectory(Path.Combine(McpRoot, "client", "out"));
	}

	public string InDir(string realm) => Path.Combine(McpRoot, realm, "in");
	public string OutDir(string realm) => Path.Combine(McpRoot, realm, "out");
	public string ManifestPath(string realm) => Path.Combine(McpRoot, "manifest_" + realm + ".json");

	public void Dispose()
	{
		try { Directory.Delete(McpRoot, recursive: true); }
		catch { /* best effort */ }
	}
}
