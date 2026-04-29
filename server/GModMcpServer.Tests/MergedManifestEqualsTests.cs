using System.Text.Json.Nodes;
using GModMcpServer.Bridge;
using GModMcpServer.Models;

namespace GModMcpServer.Tests;

public class MergedManifestEqualsTests
{
	[Test]
	public void Equals_WhenIdentical_ReturnsTrue()
	{
		var a = BuildManifest();
		var b = BuildManifest();

		Assert.That(a.Equals(b), Is.True);
	}

	[Test]
	public void Equals_WhenDescriptionDiffers_ReturnsFalse()
	{
		var a = BuildManifest();
		var b = BuildManifest(toolDescription: "different description");

		Assert.That(a.Equals(b), Is.False);
	}

	[Test]
	public void Equals_WhenSchemaDiffers_ReturnsFalse()
	{
		var a = BuildManifest();
		var b = BuildManifest(schema: JsonNode.Parse("""{"type":"object","properties":{"extra":{"type":"string"}}}"""));

		Assert.That(a.Equals(b), Is.False);
	}

	[Test]
	public void Equals_WhenRequiresOrderDiffers_ReturnsFalse()
	{
		var a = BuildManifest(requires: new List<string> { "cap_a", "cap_b" });
		var b = BuildManifest(requires: new List<string> { "cap_b", "cap_a" });

		Assert.That(a.Equals(b), Is.False);
	}

	[Test]
	public void Equals_WhenCapabilityCurrentDiffers_ReturnsFalse()
	{
		var a = BuildManifest();
		var b = BuildManifest(capabilityCurrent: true);

		Assert.That(a.Equals(b), Is.False);
	}

	[Test]
	public void Equals_WhenToolCountDiffers_ReturnsFalse()
	{
		var a = BuildManifest();
		var b = BuildManifest();
		b.Tools["extra_tool_sv"] = MakeTool("extra_tool", "server");

		Assert.That(a.Equals(b), Is.False);
	}

	[Test]
	public void Equals_WhenCapabilityCountDiffers_ReturnsFalse()
	{
		var a = BuildManifest();
		var b = BuildManifest();
		b.Capabilities["extra_cap"] = new CapabilityEntry
		{
			Id = "extra_cap",
			Description = "another",
			Default = false,
			ConVar = "mcp_allow_extra_cap",
			Current = false,
		};

		Assert.That(a.Equals(b), Is.False);
	}

	[Test]
	public void Equals_WhenOtherIsNull_ReturnsFalse()
	{
		var a = BuildManifest();

		Assert.That(a.Equals(null), Is.False);
	}

	private static MergedManifest BuildManifest(
		string toolDescription = "Default description.",
		JsonNode? schema = null,
		List<string>? requires = null,
		bool capabilityCurrent = false)
	{
		var manifest = new MergedManifest();
		manifest.Tools["lua_run_sv"] = new ToolDescriptor(
			"lua_run_sv",
			"lua_run",
			"server",
			new FunctionEntry
			{
				Id = "lua_run",
				Description = toolDescription,
				Schema = schema ?? JsonNode.Parse("""{"type":"object","properties":{"code":{"type":"string"}},"required":["code"]}"""),
				Requires = requires ?? new List<string> { "lua_eval" },
				Realm = "server",
			});
		manifest.Capabilities["lua_eval"] = new CapabilityEntry
		{
			Id = "lua_eval",
			Description = "Allow Lua eval.",
			Default = false,
			ConVar = "mcp_allow_lua_eval",
			Current = capabilityCurrent,
		};
		return manifest;
	}

	private static ToolDescriptor MakeTool(string id, string realm) => new(
		id + (realm == "server" ? "_sv" : "_cl"),
		id,
		realm,
		new FunctionEntry
		{
			Id = id,
			Description = "x",
			Schema = JsonNode.Parse("""{"type":"object","properties":{},"required":[]}"""),
			Requires = new List<string>(),
			Realm = realm,
		});
}
