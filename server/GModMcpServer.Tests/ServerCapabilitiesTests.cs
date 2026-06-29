using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;
using ModelContextProtocol.Server;

namespace GModMcpServer.Tests;

public class ServerCapabilitiesTests
{
    // Guards the regression where the server emitted notifications/tools/list_changed
    // without advertising the capability, so spec-compliant clients ignored it.
    [Test]
    public void Server_AdvertisesToolsListChanged()
    {
        var services = new ServiceCollection();
        services.AddLogging();
        Program.AddGModMcpServer(services);

        using var provider = services.BuildServiceProvider();
        var options = provider.GetRequiredService<IOptions<McpServerOptions>>().Value;

        Assert.That(options.Capabilities?.Tools?.ListChanged, Is.True,
            "Server must advertise tools.listChanged so clients honour the " +
            "notifications/tools/list_changed emitted on manifest changes.");
    }
}
