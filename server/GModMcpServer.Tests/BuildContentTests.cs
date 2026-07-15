using System.Text.Json.Nodes;
using ModelContextProtocol.Protocol;

namespace GModMcpServer.Tests;

public class BuildContentTests
{
    // A media tool returns a `content` array, so BuildContent takes the content
    // branch and never emits the whole-result JSON fallback. Passive events
    // (console output, Lua errors, background-job completions) ride on the same
    // response's `events` array; without re-surfacing them here they'd be dropped
    // on media-returning tools, and their per-session cursor has already advanced.
    [Test]
    public void BuildContent_ContentArray_SurfacesPassiveEvents()
    {
        var result = new JsonObject
        {
            ["ok"] = true,
            ["content"] = new JsonArray
            {
                new JsonObject { ["type"] = "image", ["data"] = "AAAA", ["mimeType"] = "image/jpeg" },
            },
            ["events"] = new JsonArray
            {
                new JsonObject
                {
                    ["seq"] = 4,
                    ["kind"] = "job",
                    ["job_id"] = "mcp_job_2",
                    ["text"] = "job mcp_job_2 (screenshot) finished ok: mcp/screenshots/x.jpg.",
                },
            },
        };

        var blocks = Program.BuildContent(result, result.ToJsonString(), "C:\\data");

        Assert.That(blocks.Any(b => b is ImageContentBlock), Is.True, "the image block should survive");
        var text = string.Join("\n", blocks.OfType<TextContentBlock>().Select(t => t.Text));
        Assert.That(text, Does.Contain("mcp_job_2"),
            "a passive job completion on a media-returning response must be surfaced, not dropped");
    }

    // The common text-tool path is unchanged: no `content` array => the whole
    // result JSON (which already carries `events`) is the single text block.
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
