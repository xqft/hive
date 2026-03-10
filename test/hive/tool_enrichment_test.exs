defmodule Hive.ToolEnrichmentTest do
  use ExUnit.Case, async: true

  alias Hive.ToolEnrichment

  describe "enrich/2 — hive messaging tools" do
    test "send_message" do
      r = ToolEnrichment.enrich("mcp__hive__send_message", %{"topic" => "general", "text" => "hello world"})
      assert r.icon == :chat_bubble_left
      assert r.summary == "Sent message to <strong>#general</strong>"
      assert r.detail == "hello world"
      assert r.body == {:content, "hello world"}
      assert r.link == {:navigate, "/?topic=general"}
    end

    test "send_message truncates detail to 3 lines" do
      text = "line 1\nline 2\nline 3\nline 4\nline 5"
      r = ToolEnrichment.enrich("mcp__hive__send_message", %{"topic" => "dev", "text" => text})
      assert r.detail == "line 1\nline 2\nline 3"
      assert r.body == {:content, text}
    end

    test "send_dm" do
      r = ToolEnrichment.enrich("mcp__hive__send_dm", %{"to" => "bob", "from" => "alice", "text" => "hi"})
      assert r.icon == :chat_bubble_left_right
      assert r.summary == "Sent DM to <strong>@bob</strong>"
      assert r.body == {:content, "hi"}
      assert r.link == {:navigate, "/?topic=dm:alice:bob"}
    end

    test "send_dm sorts names alphabetically" do
      r = ToolEnrichment.enrich("mcp__hive__send_dm", %{"to" => "alice", "from" => "zara", "text" => "hi"})
      assert r.link == {:navigate, "/?topic=dm:alice:zara"}
    end

    test "send_dm with missing from" do
      r = ToolEnrichment.enrich("mcp__hive__send_dm", %{"to" => "bob", "text" => "hi"})
      assert r.summary == "Sent DM to <strong>@bob</strong>"
      # Should still produce a link with fallback
      assert r.link == {:navigate, "/?topic=dm:bob:unknown"}
    end
  end

  describe "enrich/2 — agent management" do
    test "create_agent" do
      r = ToolEnrichment.enrich("mcp__hive__create_agent", %{"name" => "worker1", "description" => "A worker"})
      assert r.icon == :user_plus
      assert r.summary == "Created agent <strong>worker1</strong>"
      assert r.detail == "A worker"
      assert r.body == nil
      assert r.link == {:navigate, "/agent/worker1"}
    end

    test "create_agent without description" do
      r = ToolEnrichment.enrich("mcp__hive__create_agent", %{"name" => "worker1"})
      assert r.detail == nil
    end

    test "delete_agent" do
      r = ToolEnrichment.enrich("mcp__hive__delete_agent", %{"name" => "worker1"})
      assert r.icon == :user_minus
      assert r.summary == "Deleted agent <strong>worker1</strong>"
      assert r.link == nil
    end
  end

  describe "enrich/2 — topic management" do
    test "create_topic with invites" do
      r = ToolEnrichment.enrich("mcp__hive__create_topic", %{"name" => "dev", "invite" => ["a", "b"]})
      assert r.icon == :hashtag
      assert r.summary == "Created topic <strong>#dev</strong>"
      assert r.detail == "a, b"
      assert r.link == {:navigate, "/?topic=dev"}
    end

    test "create_topic without invites" do
      r = ToolEnrichment.enrich("mcp__hive__create_topic", %{"name" => "dev"})
      assert r.detail == nil
    end

    test "create_topic with empty invite list" do
      r = ToolEnrichment.enrich("mcp__hive__create_topic", %{"name" => "dev", "invite" => []})
      assert r.detail == nil
    end

    test "join_topic" do
      r = ToolEnrichment.enrich("mcp__hive__join_topic", %{"topic" => "dev"})
      assert r.icon == :arrow_right_on_rectangle
      assert r.summary == "Joined <strong>#dev</strong>"
      assert r.link == {:navigate, "/?topic=dev"}
    end

    test "leave_topic" do
      r = ToolEnrichment.enrich("mcp__hive__leave_topic", %{"topic" => "dev"})
      assert r.icon == :arrow_left_on_rectangle
      assert r.summary == "Left <strong>#dev</strong>"
      assert r.link == nil
    end

    test "get_topic_history" do
      r = ToolEnrichment.enrich("mcp__hive__get_topic_history", %{"topic" => "general"})
      assert r.icon == :clock
      assert r.summary == "Read history of <strong>#general</strong>"
      assert r.link == {:navigate, "/?topic=general"}
    end

    test "list_agents" do
      r = ToolEnrichment.enrich("mcp__hive__list_agents", %{})
      assert r.icon == :user_group
      assert r.summary == "Listed agents"
      assert r.link == {:navigate, "/dashboard"}
    end

    test "list_topics" do
      r = ToolEnrichment.enrich("mcp__hive__list_topics", %{})
      assert r.icon == :rectangle_stack
      assert r.summary == "Listed topics"
      assert r.link == {:navigate, "/dashboard"}
    end
  end

  describe "enrich/2 — skills and CLAUDE.md" do
    test "write_skill with content preview" do
      content = Enum.map_join(1..10, "\n", &"line #{&1}")
      r = ToolEnrichment.enrich("mcp__hive__write_skill", %{"name" => "deploy", "content" => content})
      assert r.icon == :academic_cap
      assert r.summary == "Wrote skill <strong>deploy</strong>"
      assert r.detail == "line 1\nline 2\nline 3\nline 4\nline 5"
      assert r.body == {:content, content}
    end

    test "read_skill" do
      r = ToolEnrichment.enrich("mcp__hive__read_skill", %{"name" => "deploy"})
      assert r.icon == :academic_cap
      assert r.summary == "Read skill <strong>deploy</strong>"
      assert r.detail == nil
      assert r.body == nil
    end

    test "delete_skill" do
      r = ToolEnrichment.enrich("mcp__hive__delete_skill", %{"name" => "deploy"})
      assert r.icon == :trash
      assert r.summary == "Deleted skill <strong>deploy</strong>"
    end

    test "write_claude_md" do
      r = ToolEnrichment.enrich("mcp__hive__write_claude_md", %{"content" => "# Agent\nRules here"})
      assert r.icon == :document_text
      assert r.summary == "Updated CLAUDE.md"
      assert r.detail == "# Agent\nRules here"
      assert r.body == {:content, "# Agent\nRules here"}
    end

    test "write_claude_md truncates detail to 5 lines" do
      content = Enum.map_join(1..20, "\n", &"line #{&1}")
      r = ToolEnrichment.enrich("mcp__hive__write_claude_md", %{"content" => content})
      assert length(String.split(r.detail, "\n")) == 5
    end
  end

  describe "enrich/2 — terminal tools" do
    test "tmux_send with text and Enter" do
      r = ToolEnrichment.enrich("mcp__hive__tmux_send", %{"text" => "npm test", "keys" => "Enter"})
      assert r.icon == :command_line
      assert r.summary == "Terminal: <code>npm test</code> ↵"
      assert r.link == {:tab, :terminal}
    end

    test "tmux_send with just Ctrl+C" do
      r = ToolEnrichment.enrich("mcp__hive__tmux_send", %{"keys" => "C-c"})
      assert r.summary == "Terminal: Ctrl+C"
    end

    test "tmux_send with just Ctrl+D" do
      r = ToolEnrichment.enrich("mcp__hive__tmux_send", %{"keys" => "C-d"})
      assert r.summary == "Terminal: Ctrl+D"
    end

    test "tmux_send with Tab key" do
      r = ToolEnrichment.enrich("mcp__hive__tmux_send", %{"keys" => "Tab"})
      assert r.summary == "Terminal: Tab"
    end

    test "tmux_send with arrow keys" do
      assert ToolEnrichment.enrich("mcp__hive__tmux_send", %{"keys" => "Up"}).summary ==
               "Terminal: ↑"

      assert ToolEnrichment.enrich("mcp__hive__tmux_send", %{"keys" => "Down"}).summary ==
               "Terminal: ↓"
    end

    test "tmux_send with unknown key passes through" do
      r = ToolEnrichment.enrich("mcp__hive__tmux_send", %{"keys" => "Space"})
      assert r.summary == "Terminal: Space"
    end

    test "tmux_send with wait_ms" do
      r =
        ToolEnrichment.enrich("mcp__hive__tmux_send", %{
          "text" => "y",
          "keys" => "Enter",
          "wait_ms" => 1000
        })

      assert r.summary == "Terminal: <code>y</code> ↵ (read)"
    end

    test "tmux_send with wait_ms of 0 does not append (read)" do
      r =
        ToolEnrichment.enrich("mcp__hive__tmux_send", %{
          "text" => "y",
          "keys" => "Enter",
          "wait_ms" => 0
        })

      assert r.summary == "Terminal: <code>y</code> ↵"
    end

    test "tmux_send with only text, no keys" do
      r = ToolEnrichment.enrich("mcp__hive__tmux_send", %{"text" => "hello"})
      assert r.summary == "Terminal: <code>hello</code>"
    end

    test "tmux_read" do
      r = ToolEnrichment.enrich("mcp__hive__tmux_read", %{})
      assert r.icon == :command_line
      assert r.summary == "Terminal: read screen"
      assert r.link == {:tab, :terminal}
    end
  end

  describe "enrich/2 — Claude Code built-in tools" do
    test "Read tool strips /workspace/ prefix" do
      r = ToolEnrichment.enrich("Read", %{"file_path" => "/workspace/lib/app.ex"})
      assert r.icon == :document
      assert r.summary == "Read <strong>lib/app.ex</strong>"
      assert r.body == nil
    end

    test "Read tool strips /home/ to ~/" do
      r = ToolEnrichment.enrich("Read", %{"file_path" => "/home/user/project/file.ex"})
      assert r.summary == "Read <strong>~/user/project/file.ex</strong>"
    end

    test "Read tool with missing file_path" do
      r = ToolEnrichment.enrich("Read", %{})
      assert r.summary == "Read <strong>unknown</strong>"
    end

    test "Write tool" do
      r = ToolEnrichment.enrich("Write", %{"file_path" => "/workspace/lib/app.ex", "content" => "defmodule App do\nend"})
      assert r.icon == :document_plus
      assert r.summary == "Wrote <strong>lib/app.ex</strong>"
      assert r.body == {:content, "defmodule App do\nend"}
    end

    test "Write tool truncates detail to 8 lines" do
      content = Enum.map_join(1..20, "\n", &"line #{&1}")
      r = ToolEnrichment.enrich("Write", %{"file_path" => "/workspace/app.ex", "content" => content})
      assert length(String.split(r.detail, "\n")) == 8
    end

    test "Edit tool" do
      r =
        ToolEnrichment.enrich("Edit", %{
          "file_path" => "/workspace/lib/app.ex",
          "old_string" => "foo",
          "new_string" => "bar"
        })

      assert r.icon == :pencil_square
      assert r.summary == "Edited <strong>lib/app.ex</strong>"
      assert r.body == {:diff, "foo", "bar"}
      assert r.detail =~ "- foo"
      assert r.detail =~ "+ bar"
    end

    test "Edit tool with multiline diff" do
      old = "line1\nline2\nline3"
      new = "new1\nnew2\nnew3"

      r =
        ToolEnrichment.enrich("Edit", %{
          "file_path" => "/workspace/app.ex",
          "old_string" => old,
          "new_string" => new
        })

      lines = String.split(r.detail, "\n")
      assert Enum.count(lines, &String.starts_with?(&1, "- ")) == 3
      assert Enum.count(lines, &String.starts_with?(&1, "+ ")) == 3
    end

    test "Edit tool truncates diff detail to 8 lines" do
      old = Enum.map_join(1..10, "\n", &"old #{&1}")
      new = Enum.map_join(1..10, "\n", &"new #{&1}")

      r =
        ToolEnrichment.enrich("Edit", %{
          "file_path" => "/workspace/app.ex",
          "old_string" => old,
          "new_string" => new
        })

      assert length(String.split(r.detail, "\n")) <= 8
    end

    test "Grep tool with path" do
      r = ToolEnrichment.enrich("Grep", %{"pattern" => "TODO", "path" => "/workspace/lib"})
      assert r.icon == :magnifying_glass
      assert r.summary == "Searched <code>TODO</code> in <strong>lib</strong>"
    end

    test "Grep tool without path" do
      r = ToolEnrichment.enrich("Grep", %{"pattern" => "TODO"})
      assert r.summary == "Searched <code>TODO</code>"
    end

    test "Glob tool" do
      r = ToolEnrichment.enrich("Glob", %{"pattern" => "**/*.ex"})
      assert r.icon == :folder_open
      assert r.summary == "Found files <code>**/*.ex</code>"
    end
  end

  describe "enrich/2 — web tools" do
    test "WebSearch" do
      r = ToolEnrichment.enrich("WebSearch", %{"query" => "elixir genserver"})
      assert r.icon == :globe_alt
      assert r.summary == "Web search: <code>elixir genserver</code>"
    end

    test "WebFetch" do
      r = ToolEnrichment.enrich("WebFetch", %{"url" => "https://example.com/path"})
      assert r.icon == :globe_alt
      assert r.summary == "Fetched <strong>https://example.com/path</strong>"
      assert r.detail == "https://example.com/path"
    end

    test "WebFetch truncates long URLs in summary" do
      long_url = "https://example.com/" <> String.duplicate("a", 100)
      r = ToolEnrichment.enrich("WebFetch", %{"url" => long_url})
      assert r.summary =~ "..."
      assert byte_size(r.summary) < byte_size(long_url) + 20
    end

    test "WebFetch with nil url" do
      r = ToolEnrichment.enrich("WebFetch", %{})
      assert r.summary == "Fetched <strong>unknown</strong>"
    end
  end

  describe "enrich/2 — Agent and Skill" do
    test "Agent tool" do
      r =
        ToolEnrichment.enrich("Agent", %{
          "subagent_type" => "Explore",
          "prompt" => "Find all\nAPI endpoints\nin the codebase"
        })

      assert r.icon == :cpu_chip
      assert r.summary == "Launched <strong>Explore</strong> agent"
      assert r.detail == "Find all\nAPI endpoints"
    end

    test "Agent tool with missing type" do
      r = ToolEnrichment.enrich("Agent", %{"prompt" => "Do something"})
      assert r.summary == "Launched <strong>unknown</strong> agent"
    end

    test "Skill tool" do
      r = ToolEnrichment.enrich("Skill", %{"skill" => "deploy"})
      assert r.icon == :bolt
      assert r.summary == "Invoked skill <strong>deploy</strong>"
    end
  end

  describe "enrich/2 — Playwright tools" do
    test "browser_click" do
      r = ToolEnrichment.enrich("mcp__playwright__browser_click", %{})
      assert r.icon == :computer_desktop
      assert r.summary == "Browser: <strong>click</strong>"
    end

    test "browser_navigate" do
      r = ToolEnrichment.enrich("mcp__playwright__browser_navigate", %{})
      assert r.summary == "Browser: <strong>navigate</strong>"
    end

    test "browser_take_screenshot" do
      r = ToolEnrichment.enrich("mcp__playwright__browser_take_screenshot", %{})
      assert r.summary == "Browser: <strong>take screenshot</strong>"
    end

    test "browser_fill_form" do
      r = ToolEnrichment.enrich("mcp__playwright__browser_fill_form", %{})
      assert r.summary == "Browser: <strong>fill form</strong>"
    end
  end

  describe "enrich/2 — catch-all" do
    test "unknown tool shows key=value pairs" do
      r = ToolEnrichment.enrich("some_custom_tool", %{"arg1" => "val1", "arg2" => "val2"})
      assert r.icon == :wrench
      assert r.summary == "Used <strong>some_custom_tool</strong>"
      assert r.detail =~ "arg1=val1"
    end

    test "unknown tool with empty input" do
      r = ToolEnrichment.enrich("some_custom_tool", %{})
      assert r.icon == :wrench
      assert r.summary == "Used <strong>some_custom_tool</strong>"
      assert r.detail == nil
    end

    test "unknown tool limits detail to 3 entries" do
      input = %{"a" => 1, "b" => 2, "c" => 3, "d" => 4}
      r = ToolEnrichment.enrich("custom", input)
      entry_count = r.detail |> String.split(", ") |> length()
      assert entry_count <= 3
    end

    test "Bash tool shows description" do
      r = ToolEnrichment.enrich("Bash", %{"command" => "ls -la", "description" => "List files"})
      assert r.icon == :command_line
      assert r.summary =~ "List files"
      assert r.detail == "ls -la"
    end

    test "ToolSearch tool shows query" do
      r = ToolEnrichment.enrich("ToolSearch", %{"query" => "slack send"})
      assert r.icon == :magnifying_glass
      assert r.summary =~ "slack send"
    end
  end

  describe "enrich/1 — default input" do
    test "works with single argument" do
      r = ToolEnrichment.enrich("mcp__hive__list_agents")
      assert r.summary == "Listed agents"
    end
  end
end
