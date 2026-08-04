using GModMcpServer.Host;

namespace GModMcpServer.Tests;

public class CondebugDetectionTests
{
    [TestCase("gmod.exe -steam -game garrysmod -condebug +map x", true)]
    [TestCase("gmod.exe -condebug", true)]                       // trailing token
    [TestCase("-condebug -game garrysmod", true)]                // leading token
    [TestCase("gmod.exe -steam -game garrysmod", false)]
    [TestCase("gmod.exe -condebugfoo", false)]                   // not a bare token
    [TestCase("gmod.exe --condebug", false)]                     // double-dash isn't the flag
    [TestCase(null, false)]
    [TestCase("", false)]
    public void HasCondebug(string? cmdline, bool expected) =>
        Assert.That(GameProcessManager.HasCondebug(cmdline), Is.EqualTo(expected));
}
