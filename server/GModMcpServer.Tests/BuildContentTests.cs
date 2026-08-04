using System.Text.Json.Nodes;
using ModelContextProtocol.Protocol;

namespace GModMcpServer.Tests;

public class BuildContentTests
{
    // A media tool returns a `content` array -> BuildContent maps it to native blocks.
    // (Passive events no longer ride here: they're stripped upstream and re-emitted as the
    // unified `events` block by EmitUnifiedEvents.)
    [Test]
    public void BuildContent_ContentArray_ReturnsMediaBlocks()
    {
        var result = new JsonObject
        {
            ["ok"] = true,
            ["content"] = new JsonArray
            {
                new JsonObject { ["type"] = "image", ["data"] = "AAAA", ["mimeType"] = "image/jpeg" },
            },
        };

        var blocks = Program.BuildContent(result, result.ToJsonString(), "C:\\data");

        Assert.That(blocks.Any(b => b is ImageContentBlock), Is.True, "the image block is mapped");
    }

    // The common text-tool path: no `content` array => the whole result JSON is the block.
    [Test]
    public void BuildContent_NoContentArray_DumpsFallbackJson()
    {
        var result = new JsonObject { ["ok"] = true, ["result"] = "hi" };
        var fallback = result.ToJsonString();

        var blocks = Program.BuildContent(result, fallback, "C:\\data");

        Assert.That(blocks, Has.Count.EqualTo(1));
        Assert.That(blocks[0], Is.TypeOf<TextContentBlock>());
        Assert.That(((TextContentBlock)blocks[0]).Text, Is.EqualTo(fallback));
    }
}
