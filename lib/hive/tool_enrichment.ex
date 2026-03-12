defmodule Hive.ToolEnrichment do
  @moduledoc "Transform raw tool calls into human-readable summaries."

  @doc "Enrich a tool call with human-readable summary, preview, and optional link."
  def enrich(tool_name, input \\ %{})

  def enrich("mcp__hive__" <> _ = tool_name, input), do: do_enrich(tool_name, input)
  def enrich("mcp__playwright__" <> _ = tool_name, input), do: do_enrich(tool_name, input)
  def enrich(tool_name, input), do: do_enrich(tool_name, input)

  # -------------------------------------------------------------------
  # Hive tools
  # -------------------------------------------------------------------

  defp do_enrich("mcp__hive__send_message", input) do
    topic = input["topic"]
    text = input["text"] || ""

    result(:chat_bubble_left, "Sent message to <strong>##{esc(topic)}</strong>",
      detail: preview_lines(text, 3),
      body: {:content, text},
      link: {:navigate, "/?topic=#{topic}"}
    )
  end

  defp do_enrich("mcp__hive__send_dm", input) do
    to = input["to"]
    from = input["from"]
    text = input["text"] || ""
    sorted = dm_path(from, to)

    result(:chat_bubble_left_right, "Sent DM to <strong>@#{esc(to)}</strong>",
      detail: preview_lines(text, 3),
      body: {:content, text},
      link: {:navigate, "/?topic=dm:#{sorted}"}
    )
  end

  defp do_enrich("mcp__hive__create_agent", input) do
    name = input["name"]

    result(:user_plus, "Created agent <strong>#{esc(name)}</strong>",
      detail: input["description"],
      link: {:navigate, "/agent/#{name}"}
    )
  end

  defp do_enrich("mcp__hive__delete_agent", input) do
    result(:user_minus, "Deleted agent <strong>#{esc(input["name"])}</strong>")
  end

  defp do_enrich("mcp__hive__create_topic", input) do
    name = input["name"]
    invite = input["invite"]

    detail =
      case invite do
        list when is_list(list) and list != [] -> Enum.join(list, ", ")
        _ -> nil
      end

    result(:hashtag, "Created topic <strong>##{esc(name)}</strong>",
      detail: detail,
      link: {:navigate, "/?topic=#{name}"}
    )
  end

  defp do_enrich("mcp__hive__join_topic", input) do
    topic = input["topic"]

    result(:arrow_right_on_rectangle, "Joined <strong>##{esc(topic)}</strong>",
      link: {:navigate, "/?topic=#{topic}"}
    )
  end

  defp do_enrich("mcp__hive__leave_topic", input) do
    result(:arrow_left_on_rectangle, "Left <strong>##{esc(input["topic"])}</strong>")
  end

  defp do_enrich("mcp__hive__get_topic_history", input) do
    topic = input["topic"]

    result(:clock, "Read history of <strong>##{esc(topic)}</strong>",
      link: {:navigate, "/?topic=#{topic}"}
    )
  end

  defp do_enrich("mcp__hive__list_agents", _input) do
    result(:user_group, "Listed agents", link: {:navigate, "/dashboard"})
  end

  defp do_enrich("mcp__hive__list_topics", _input) do
    result(:rectangle_stack, "Listed topics", link: {:navigate, "/dashboard"})
  end

  defp do_enrich("mcp__hive__write_skill", input) do
    name = input["name"]
    content = input["content"] || ""

    result(:academic_cap, "Wrote skill <strong>#{esc(name)}</strong>",
      detail: preview_lines(content, 5),
      body: {:content, content}
    )
  end

  defp do_enrich("mcp__hive__read_skill", input) do
    result(:academic_cap, "Read skill <strong>#{esc(input["name"])}</strong>")
  end

  defp do_enrich("mcp__hive__delete_skill", input) do
    result(:trash, "Deleted skill <strong>#{esc(input["name"])}</strong>")
  end

  defp do_enrich("mcp__hive__write_claude_md", input) do
    content = input["content"] || ""

    result(:document_text, "Updated CLAUDE.md",
      detail: preview_lines(content, 5),
      body: {:content, content}
    )
  end

  defp do_enrich("mcp__hive__tmux_send", input) do
    result(:command_line, tmux_send_summary(input), link: {:tab, :terminal})
  end

  defp do_enrich("mcp__hive__tmux_read", _input) do
    result(:command_line, "Terminal: read screen", link: {:tab, :terminal})
  end

  # -------------------------------------------------------------------
  # Built-in Claude Code tools
  # -------------------------------------------------------------------

  defp do_enrich("Bash", input) do
    cmd = input["command"] || ""
    desc = input["description"]
    summary = if desc, do: "Ran <code>#{esc(truncate(desc, 60))}</code>", else: "Ran command"

    result(:command_line, summary,
      detail: preview_lines(cmd, 3),
      body: {:content, cmd}
    )
  end

  defp do_enrich("ToolSearch", input) do
    query = input["query"] || ""
    result(:magnifying_glass, "Tool search: <code>#{esc(query)}</code>")
  end

  defp do_enrich("Read", input) do
    path = strip_workspace(input["file_path"])
    result(:document, "Read <strong>#{esc(path)}</strong>")
  end

  defp do_enrich("Write", input) do
    path = strip_workspace(input["file_path"])
    content = input["content"] || ""

    result(:document_plus, "Wrote <strong>#{esc(path)}</strong>",
      detail: preview_lines(content, 8),
      body: {:content, content}
    )
  end

  defp do_enrich("Edit", input) do
    path = strip_workspace(input["file_path"])
    old = input["old_string"]
    new = input["new_string"]

    diff_preview =
      case {old, new} do
        {o, n} when is_binary(o) and is_binary(n) ->
          lines =
            (String.split(o, "\n") |> Enum.map(&"- #{&1}")) ++
              (String.split(n, "\n") |> Enum.map(&"+ #{&1}"))

          lines |> Enum.take(8) |> Enum.join("\n")

        _ ->
          nil
      end

    result(:pencil_square, "Edited <strong>#{esc(path)}</strong>",
      detail: diff_preview,
      body: {:diff, old, new}
    )
  end

  defp do_enrich("Grep", input) do
    pattern = input["pattern"]
    path = input["path"]

    summary =
      if path do
        "Searched <code>#{esc(pattern)}</code> in <strong>#{esc(strip_workspace(path))}</strong>"
      else
        "Searched <code>#{esc(pattern)}</code>"
      end

    result(:magnifying_glass, summary)
  end

  defp do_enrich("Glob", input) do
    result(:folder_open, "Found files <code>#{esc(input["pattern"])}</code>")
  end

  defp do_enrich("WebSearch", input) do
    result(:globe_alt, "Web search: <code>#{esc(input["query"])}</code>")
  end

  defp do_enrich("WebFetch", input) do
    url = truncate_url(input["url"], 80)
    result(:globe_alt, "Fetched <strong>#{esc(url)}</strong>", detail: input["url"])
  end

  defp do_enrich("Agent", input) do
    type = input["subagent_type"] || "unknown"
    prompt = input["prompt"]

    result(:cpu_chip, "Launched <strong>#{esc(type)}</strong> agent",
      detail: preview_lines(prompt, 2)
    )
  end

  defp do_enrich("Skill", input) do
    result(:bolt, "Invoked skill <strong>#{esc(input["skill"])}</strong>")
  end

  # -------------------------------------------------------------------
  # Playwright tools
  # -------------------------------------------------------------------

  defp do_enrich("mcp__playwright__" <> suffix, _input) do
    action = humanize_action(suffix)
    result(:computer_desktop, "Browser: <strong>#{esc(action)}</strong>")
  end

  # -------------------------------------------------------------------
  # Catch-all
  # -------------------------------------------------------------------

  defp do_enrich(tool_name, input) do
    detail =
      input
      |> Enum.take(3)
      |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{truncate(to_string(v), 40)}" end)
      |> case do
        "" -> nil
        s -> s
      end

    result(:wrench, "Used <strong>#{esc(tool_name)}</strong>", detail: detail)
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp result(icon, summary, opts \\ []) do
    %{
      icon: icon,
      summary: summary,
      detail: opts[:detail],
      body: opts[:body],
      link: opts[:link]
    }
  end

  defp tmux_send_summary(input) do
    raw = input["input"] || ""
    wait = input["wait_ms"]

    # Parse {KeyName} segments and literal text
    parts =
      Regex.split(~r/(\{[^}]+\})/, raw, include_captures: true, trim: true)
      |> Enum.map(fn segment ->
        case Regex.run(~r/^\{([^}]+)\}$/, segment) do
          [_, key] -> humanize_key(key)
          nil -> "<code>#{esc(segment)}</code>"
        end
      end)

    suffix = if wait && wait > 0, do: " (read)", else: ""

    "Terminal: #{Enum.join(parts, " ")}#{suffix}"
  end

  defp humanize_key("Enter"), do: "↵"
  defp humanize_key("C-c"), do: "Ctrl+C"
  defp humanize_key("C-d"), do: "Ctrl+D"
  defp humanize_key("Tab"), do: "Tab"
  defp humanize_key("Up"), do: "↑"
  defp humanize_key("Down"), do: "↓"
  defp humanize_key(key), do: key

  defp strip_workspace(path) when is_binary(path) do
    path
    |> String.replace_leading("/workspace/", "")
    |> String.replace_leading("/home/", "~/")
  end

  defp strip_workspace(_), do: "unknown"

  defp truncate_url(url, max) when is_binary(url) and byte_size(url) > max do
    String.slice(url, 0, max) <> "..."
  end

  defp truncate_url(url, _max) when is_binary(url), do: url
  defp truncate_url(_, _), do: "unknown"

  defp preview_lines(text, n) when is_binary(text) do
    text |> String.split("\n") |> Enum.take(n) |> Enum.join("\n")
  end

  defp preview_lines(_, _), do: nil

  defp humanize_action(suffix) do
    suffix
    |> String.replace("browser_", "")
    |> String.replace("_", " ")
  end

  defp dm_path(from, to) do
    names = Enum.sort([from || "unknown", to || "unknown"])
    Enum.join(names, ":")
  end

  defp esc(nil), do: ""

  defp esc(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp esc(other), do: esc(to_string(other))

  defp truncate(text, max) when is_binary(text) and byte_size(text) > max do
    String.slice(text, 0, max) <> "…"
  end

  defp truncate(text, _max) when is_binary(text), do: text
  defp truncate(_, _), do: ""
end
