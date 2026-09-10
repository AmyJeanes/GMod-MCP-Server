using GModMcpServer.Host.Tools;

namespace GModMcpServer.Tests;

/// <summary>
/// The on-disk map check that decides whether host_launch bootstraps. On-disk maps
/// (base game / loose addons / download) boot directly; a map found nowhere on disk
/// is assumed to be a workshop map and triggers the two-stage bootstrap.
/// </summary>
public sealed class LaunchToolMapResolveTests
{
    private string _root = "";
    private string Mod => Path.Combine(_root, "garrysmod");

    [SetUp]
    public void SetUp()
    {
        _root = Path.Combine(Path.GetTempPath(), "gmod-mcp-maps-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path.Combine(Mod, "maps"));
        Directory.CreateDirectory(Path.Combine(Mod, "download", "maps"));
        Directory.CreateDirectory(Path.Combine(Mod, "addons", "someaddon", "maps"));
    }

    [TearDown]
    public void TearDown()
    {
        try { Directory.Delete(_root, recursive: true); }
        catch { /* best effort temp cleanup */ }
    }

    private void WriteMap(string dir, string name)
        => File.WriteAllText(Path.Combine(Mod, Path.Combine(dir.Split('/')), name + ".bsp"), "");

    [Test]
    public void BaseGameMap_IsOnDisk()
    {
        WriteMap("maps", "gm_construct");
        Assert.That(LaunchTool.MapExistsOnDisk(_root, "gm_construct"), Is.True);
    }

    [Test]
    public void LooseAddonMap_IsOnDisk()
    {
        WriteMap("addons/someaddon/maps", "rp_foo");
        Assert.That(LaunchTool.MapExistsOnDisk(_root, "rp_foo"), Is.True);
    }

    [Test]
    public void DownloadedMap_IsOnDisk()
    {
        WriteMap("download/maps", "gm_dl");
        Assert.That(LaunchTool.MapExistsOnDisk(_root, "gm_dl"), Is.True);
    }

    [Test]
    public void WorkshopOnlyMap_IsNotOnDisk()
    {
        // Nothing on disk — simulates a map that only exists inside a workshop .gma,
        // which Steam mounts asynchronously. This is the signal to bootstrap.
        Assert.That(LaunchTool.MapExistsOnDisk(_root, "gm_frozen_lake"), Is.False);
    }

    [Test]
    public void BspSuffix_Accepted()
    {
        WriteMap("maps", "gm_construct");
        Assert.That(LaunchTool.MapExistsOnDisk(_root, "gm_construct.bsp"), Is.True);
    }

    [TestCase("")]
    [TestCase("../secret")]
    [TestCase("foo/bar")]
    [TestCase("foo\\bar")]
    public void PathEscapesRejected(string map)
    {
        // A real map name is a single path segment; anything else can't be a map.
        Assert.That(LaunchTool.MapExistsOnDisk(_root, map), Is.False);
    }
}
