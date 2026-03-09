defmodule Hive.Connector.TemplatesTest do
  use ExUnit.Case, async: true

  alias Hive.Connector.Templates

  test "list returns templates from disk" do
    templates = Templates.list()
    assert length(templates) >= 3
    slugs = Enum.map(templates, & &1["slug"])
    assert "github" in slugs
    assert "linear" in slugs
    assert "google-drive" in slugs
  end

  test "get returns a specific template" do
    template = Templates.get("github")
    assert template["slug"] == "github"
    assert template["name"] == "GitHub"
    assert template["mcp"]["command"] == "npx"
  end

  test "get returns nil for unknown slug" do
    assert Templates.get("nonexistent") == nil
  end

  test "apply_config resolves placeholders" do
    template = Templates.get("github")
    result = Templates.apply_config(template, %{"github_token" => "ghp_test123"})
    assert result.mcp.env["GITHUB_PERSONAL_ACCESS_TOKEN"] == "ghp_test123"
    assert result.event.type == "webhook"
    assert result.event.topic == "github-events"
  end

  test "apply_config uses custom topic when provided" do
    template = Templates.get("github")
    result = Templates.apply_config(template, %{"github_token" => "t", "topic" => "my-gh"})
    assert result.event.topic == "my-gh"
  end
end
