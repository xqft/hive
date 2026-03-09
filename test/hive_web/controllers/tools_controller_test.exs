defmodule HiveWeb.ToolsControllerTest do
  use HiveWeb.ConnCase, async: false

  @moduledoc """
  Tests for the Tools API controller.

  Tests that don't require GenServers (write_skill, read_skill, delete_skill,
  write_claude_md) exercise the full request lifecycle. Auth and permission
  checks are tested with any tool since they run before dispatch.

  Tests that require the full app stack (create_topic, send_message,
  list_agents, list_topics) use the persistence layer and topic GenServers
  started by the application supervisor.
  """

  # Compute the same HMAC secret the Hive.Agent module will produce.
  defp mcp_secret(agent_name) do
    app_secret = Application.get_env(:hive, :secret_key_base)

    :crypto.mac(:hmac, :sha256, app_secret, "mcp:#{agent_name}")
    |> Base.url_encode64(padding: false)
  end

  defp authed_conn(conn, agent_name) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{mcp_secret(agent_name)}")
  end

  defp tool_call(conn, agent, tool, params) do
    conn
    |> authed_conn(agent)
    |> post("/api/tools", %{agent: agent, tool: tool, params: params})
  end

  defp agent_dir(agent) do
    Path.join(["priv", "agents", agent])
  end

  defp skill_dir(agent, skill) do
    Path.join([agent_dir(agent), ".claude", "skills", skill])
  end

  # Unique within a VM via unique_integer, unique across VMs via system_time fragment
  defp unique(prefix) do
    ts = rem(System.system_time(:millisecond), 100_000)
    n = :erlang.unique_integer([:positive])
    "#{prefix}-#{ts}n#{n}"
  end

  defp put_hive_env(key, value) do
    previous = Application.get_env(:hive, key)
    Application.put_env(:hive, key, value)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:hive, key)
      else
        Application.put_env(:hive, key, previous)
      end
    end)
  end

  defp cleanup_topic(name) do
    on_exit(fn ->
      case Registry.lookup(Hive.TopicRegistry, name) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(Hive.TopicSup, pid)
        [] -> :ok
      end

      Hive.Persistence.delete_topic(name)
    end)
  end

  defp cleanup_agent(name) do
    on_exit(fn ->
      Hive.Persistence.delete_agent(name)
    end)
  end

  setup %{conn: conn} do
    conn = put_req_header(conn, "content-type", "application/json")

    on_exit(fn ->
      File.rm_rf(agent_dir("test-agent"))
      File.rm_rf(agent_dir("test-agent2"))
      Hive.Persistence.delete_agent("test-agent")
      Hive.Persistence.delete_agent("test-agent2")
    end)

    {:ok, conn: conn}
  end

  # ---------------------------------------------------------------------------
  # Authentication
  # ---------------------------------------------------------------------------

  describe "HMAC authentication" do
    test "rejects requests without authorization header", %{conn: conn} do
      conn =
        conn
        |> post("/api/tools", %{agent: "test-agent", tool: "read_skill", params: %{name: "x"}})

      assert json_response(conn, 401) == %{"ok" => false, "error" => "unauthorized"}
    end

    test "rejects requests with wrong authorization header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer wrong-secret")
        |> post("/api/tools", %{agent: "test-agent", tool: "read_skill", params: %{name: "x"}})

      assert json_response(conn, 401) == %{"ok" => false, "error" => "unauthorized"}
    end

    test "accepts requests with correct HMAC secret", %{conn: conn} do
      # read_skill on a non-existent skill will return an error, but it should
      # pass auth and permission checks (200 with ok: false, not 401/403)
      conn =
        conn
        |> authed_conn("test-agent")
        |> post("/api/tools", %{
          agent: "test-agent",
          tool: "read_skill",
          params: %{name: "nonexistent"}
        })

      body = json_response(conn, 200)
      assert body["ok"] == false
      assert body["error"] =~ "not found"
    end
  end

  # ---------------------------------------------------------------------------
  # Permission check
  # ---------------------------------------------------------------------------

  describe "tool permission check" do
    test "rejects unknown tool names", %{conn: conn} do
      conn =
        conn
        |> authed_conn("test-agent")
        |> post("/api/tools", %{
          agent: "test-agent",
          tool: "rm_rf_slash",
          params: %{}
        })

      assert json_response(conn, 403) == %{"ok" => false, "error" => "forbidden"}
    end

    test "accepts all known tool names (permission check only)", %{conn: conn} do
      # We verify the permission check passes (no 403). Tools that require
      # running GenServers (Topic, Container, etc.) may crash with exits,
      # so we only test filesystem-based tools that won't crash and verify
      # the rest don't return 403 by catching any exits.
      known_tools = ~w(
        send_message send_dm create_topic join_topic leave_topic
        get_topic_history list_agents list_topics
        execute_in_container check_execution
        write_skill read_skill delete_skill write_claude_md
        upload_media extract_container_file view_image
      )

      event_source_tools = ~w(create_event_source list_event_sources delete_event_source)

      for tool <- known_tools ++ event_source_tools do
        result =
          try do
            test_conn =
              conn
              |> recycle()
              |> authed_conn("test-agent")
              |> post("/api/tools", %{
                agent: "test-agent",
                tool: tool,
                params: %{
                  "name" => "x",
                  "topic" => "x",
                  "text" => "x",
                  "to" => "x",
                  "content" => "x",
                  "container_id" => "x"
                }
              })

            {:ok, test_conn.status}
          catch
            :exit, _ ->
              # Tool dispatched (passed auth + permission) but the target
              # GenServer isn't running. That's expected in tests.
              {:ok, :exit}
          end

        case result do
          {:ok, 403} ->
            flunk("Tool '#{tool}' should not be forbidden but got 403")

          {:ok, _} ->
            :ok
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Malformed requests
  # ---------------------------------------------------------------------------

  describe "malformed requests" do
    test "returns 400 when agent field is missing", %{conn: conn} do
      conn =
        conn
        |> post("/api/tools", %{tool: "read_skill", params: %{name: "x"}})

      assert json_response(conn, 400) == %{
               "ok" => false,
               "error" => "missing required fields: agent, tool, params"
             }
    end

    test "returns 400 when tool field is missing", %{conn: conn} do
      conn =
        conn
        |> post("/api/tools", %{agent: "test-agent", params: %{name: "x"}})

      assert json_response(conn, 400) == %{
               "ok" => false,
               "error" => "missing required fields: agent, tool, params"
             }
    end

    test "returns 400 when params field is missing", %{conn: conn} do
      conn =
        conn
        |> post("/api/tools", %{agent: "test-agent", tool: "read_skill"})

      assert json_response(conn, 400) == %{
               "ok" => false,
               "error" => "missing required fields: agent, tool, params"
             }
    end

    test "returns 400 with empty body", %{conn: conn} do
      conn = post(conn, "/api/tools", %{})

      assert json_response(conn, 400) == %{
               "ok" => false,
               "error" => "missing required fields: agent, tool, params"
             }
    end
  end

  # ---------------------------------------------------------------------------
  # Skill tools (filesystem-based, no GenServers needed)
  # ---------------------------------------------------------------------------

  describe "write_skill" do
    test "writes a skill file and returns success", %{conn: conn} do
      conn =
        conn
        |> authed_conn("test-agent")
        |> post("/api/tools", %{
          agent: "test-agent",
          tool: "write_skill",
          params: %{name: "my-skill", content: "# My Skill\nDo the thing."}
        })

      body = json_response(conn, 200)
      assert body["ok"] == true
      assert body["result"] =~ "my-skill"
      assert body["result"] =~ "SKILL.md"

      # Verify the file was actually written
      path = Path.join(skill_dir("test-agent", "my-skill"), "SKILL.md")
      assert File.exists?(path)
      assert File.read!(path) == "# My Skill\nDo the thing."
    end

    test "rejects invalid skill names", %{conn: conn} do
      conn =
        conn
        |> authed_conn("test-agent")
        |> post("/api/tools", %{
          agent: "test-agent",
          tool: "write_skill",
          params: %{name: "../escape", content: "bad"}
        })

      body = json_response(conn, 200)
      assert body["ok"] == false
      assert body["error"] =~ "invalid_name"
    end
  end

  describe "read_skill" do
    test "reads an existing skill", %{conn: conn} do
      # Create the skill first
      dir = skill_dir("test-agent", "readable")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "SKILL.md"), "skill content here")

      conn =
        conn
        |> authed_conn("test-agent")
        |> post("/api/tools", %{
          agent: "test-agent",
          tool: "read_skill",
          params: %{name: "readable"}
        })

      body = json_response(conn, 200)
      assert body["ok"] == true
      assert body["result"] == "skill content here"
    end

    test "returns error for non-existent skill", %{conn: conn} do
      conn =
        conn
        |> authed_conn("test-agent")
        |> post("/api/tools", %{
          agent: "test-agent",
          tool: "read_skill",
          params: %{name: "does-not-exist"}
        })

      body = json_response(conn, 200)
      assert body["ok"] == false
      assert body["error"] =~ "not found"
    end
  end

  describe "delete_skill" do
    test "deletes an existing skill directory", %{conn: conn} do
      # Create the skill first
      dir = skill_dir("test-agent", "deleteme")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "SKILL.md"), "to be deleted")

      conn =
        conn
        |> authed_conn("test-agent")
        |> post("/api/tools", %{
          agent: "test-agent",
          tool: "delete_skill",
          params: %{name: "deleteme"}
        })

      body = json_response(conn, 200)
      assert body["ok"] == true
      assert body["result"] =~ "deleted"

      refute File.exists?(dir)
    end

    test "returns error when deleting non-existent skill", %{conn: conn} do
      conn =
        conn
        |> authed_conn("test-agent")
        |> post("/api/tools", %{
          agent: "test-agent",
          tool: "delete_skill",
          params: %{name: "ghost"}
        })

      body = json_response(conn, 200)
      assert body["ok"] == false
      assert body["error"] =~ "not found"
    end
  end

  describe "write_claude_md" do
    test "writes CLAUDE.md and returns success", %{conn: conn} do
      # Create the agent in persistence so update_agent_personality has a row to update.
      Hive.Persistence.create_agent("test-agent", "test", "default personality")

      conn =
        conn
        |> authed_conn("test-agent")
        |> post("/api/tools", %{
          agent: "test-agent",
          tool: "write_claude_md",
          params: %{content: "# My Agent\nI am a helpful agent."}
        })

      body = json_response(conn, 200)
      assert body["ok"] == true
      assert body["result"] =~ "CLAUDE.md updated"

      # Verify the file was actually written
      path = Path.join(agent_dir("test-agent"), "CLAUDE.md")
      assert File.exists?(path)
      assert File.read!(path) == "# My Agent\nI am a helpful agent."
    end

    test "updates personality in persistence", %{conn: conn} do
      Hive.Persistence.create_agent("test-agent", "test desc", "old personality")

      new_content = "# Updated Agent\nNew personality content."

      conn
      |> tool_call("test-agent", "write_claude_md", %{content: new_content})
      |> json_response(200)

      # Verify personality was updated in the database
      {:ok, agent} = Hive.Persistence.get_agent("test-agent")
      assert agent.personality == new_content
    end
  end

  # ---------------------------------------------------------------------------
  # write_skill + read_skill round-trip
  # ---------------------------------------------------------------------------

  describe "skill round-trip" do
    test "write then read returns the same content", %{conn: conn} do
      content = "# Round Trip Skill\n\nStep 1: Do thing\nStep 2: Done"

      # Write
      write_conn =
        conn
        |> authed_conn("test-agent")
        |> post("/api/tools", %{
          agent: "test-agent",
          tool: "write_skill",
          params: %{name: "roundtrip", content: content}
        })

      assert json_response(write_conn, 200)["ok"] == true

      # Read
      read_conn =
        conn
        |> recycle()
        |> authed_conn("test-agent")
        |> post("/api/tools", %{
          agent: "test-agent",
          tool: "read_skill",
          params: %{name: "roundtrip"}
        })

      body = json_response(read_conn, 200)
      assert body["ok"] == true
      assert body["result"] == content
    end

    test "write, delete, then read returns not found", %{conn: conn} do
      # Write
      conn
      |> authed_conn("test-agent")
      |> post("/api/tools", %{
        agent: "test-agent",
        tool: "write_skill",
        params: %{name: "ephemeral", content: "temp"}
      })

      # Delete
      conn
      |> recycle()
      |> authed_conn("test-agent")
      |> post("/api/tools", %{
        agent: "test-agent",
        tool: "delete_skill",
        params: %{name: "ephemeral"}
      })

      # Read
      read_conn =
        conn
        |> recycle()
        |> authed_conn("test-agent")
        |> post("/api/tools", %{
          agent: "test-agent",
          tool: "read_skill",
          params: %{name: "ephemeral"}
        })

      body = json_response(read_conn, 200)
      assert body["ok"] == false
      assert body["error"] =~ "not found"
    end
  end

  describe "execute_in_container" do
    setup do
      put_hive_env(:container_docker_available, true)
      put_hive_env(:container_image_available, true)
      put_hive_env(:claude_oauth_token, "test-oauth-token")
      :ok
    end

    test "accepts empty task as interactive session", %{conn: conn} do
      body =
        conn
        |> tool_call("test-agent", "execute_in_container", %{"task" => "   "})
        |> json_response(200)

      assert body["ok"] == true
    end

    test "rejects timeout outside allowed bounds", %{conn: conn} do
      body =
        conn
        |> tool_call("test-agent", "execute_in_container", %{
          "task" => "run tests",
          "timeout_minutes" => 0
        })
        |> json_response(200)

      assert body["ok"] == false
      assert body["error"] =~ "timeout_minutes must be between 1 and 60"
    end

    test "rejects when docker is unavailable", %{conn: conn} do
      put_hive_env(:container_docker_available, false)

      body =
        conn
        |> tool_call("test-agent", "execute_in_container", %{"task" => "run tests"})
        |> json_response(200)

      assert body == %{"ok" => false, "error" => "docker is not installed or not on PATH"}
    end

    test "rejects when image is unavailable", %{conn: conn} do
      put_hive_env(:container_image_available, false)

      body =
        conn
        |> tool_call("test-agent", "execute_in_container", %{"task" => "run tests"})
        |> json_response(200)

      assert body["ok"] == false
      assert body["error"] =~ "container image hive-claude-code:latest is not available locally"
    end

    test "rejects when oauth token is missing", %{conn: conn} do
      put_hive_env(:claude_oauth_token, nil)

      body =
        conn
        |> tool_call("test-agent", "execute_in_container", %{"task" => "run tests"})
        |> json_response(200)

      assert body == %{"ok" => false, "error" => "CLAUDE_CODE_OAUTH_TOKEN is not configured"}
    end
  end

  # ---------------------------------------------------------------------------
  # create_topic (requires persistence + TopicSup)
  # ---------------------------------------------------------------------------

  describe "create_topic" do
    test "creates a topic with a valid name", %{conn: conn} do
      topic = unique("test-topic")
      cleanup_topic(topic)

      body =
        conn
        |> tool_call("test-agent", "create_topic", %{
          name: topic,
          description: "A test topic"
        })
        |> json_response(200)

      assert body["ok"] == true
      assert body["result"] =~ topic
      assert body["result"] =~ "created"

      {:ok, persisted} = Hive.Persistence.get_topic(topic)
      assert persisted.name == topic
      assert persisted.description == "A test topic"

      assert [{_pid, _}] = Registry.lookup(Hive.TopicRegistry, topic)
    end

    test "rejects invalid topic name", %{conn: conn} do
      body =
        conn
        |> tool_call("test-agent", "create_topic", %{
          name: "bad name!",
          description: "invalid"
        })
        |> json_response(200)

      assert body["ok"] == false
      assert body["error"] =~ "invalid_name"
    end

    test "rejects duplicate topic name", %{conn: conn} do
      topic = unique("dup-topic")

      :ok = Hive.Persistence.create_topic(topic, "first", "topic", "test-agent")

      start_supervised!(
        {Hive.Topic, name: topic, description: "first", type: :topic, created_by: "test-agent"}
      )

      on_exit(fn -> Hive.Persistence.delete_topic(topic) end)

      body =
        conn
        |> tool_call("test-agent", "create_topic", %{
          name: topic,
          description: "duplicate"
        })
        |> json_response(200)

      assert body["ok"] == false
      assert body["error"] =~ "name_taken"
    end
  end

  # ---------------------------------------------------------------------------
  # send_message (requires a running Topic GenServer)
  # ---------------------------------------------------------------------------

  describe "send_message" do
    setup %{conn: conn} do
      topic_name = unique("msg-topic")
      :ok = Hive.Persistence.create_topic(topic_name, "messages", "topic", "test-agent")

      start_supervised!(
        {Hive.Topic,
         name: topic_name, description: "messages", type: :topic, created_by: "test-agent"}
      )

      Hive.Topic.join(topic_name, "test-agent")

      on_exit(fn -> Hive.Persistence.delete_topic(topic_name) end)

      {:ok, conn: conn, topic_name: topic_name}
    end

    test "sends a message to an existing topic", %{conn: conn, topic_name: topic_name} do
      body =
        conn
        |> tool_call("test-agent", "send_message", %{
          topic: topic_name,
          text: "hello from test"
        })
        |> json_response(200)

      assert body["ok"] == true
      assert body["result"] =~ "Message sent"
      assert body["result"] =~ topic_name
    end

    test "message is persisted and retrievable", %{conn: conn, topic_name: topic_name} do
      conn
      |> tool_call("test-agent", "send_message", %{
        topic: topic_name,
        text: "persisted message"
      })
      |> json_response(200)

      # Persistence write_message is a cast, so flush the GenServer state
      :sys.get_state(Hive.Persistence)

      {:ok, messages} = Hive.Persistence.get_messages(topic_name)
      assert length(messages) >= 1
      assert Enum.any?(messages, fn m -> m.body == "persisted message" end)
    end
  end

  # ---------------------------------------------------------------------------
  # list_agents
  # ---------------------------------------------------------------------------

  describe "list_agents" do
    test "returns a JSON list of agents", %{conn: conn} do
      a = unique("list-agent-a")
      b = unique("list-agent-b")
      Hive.Persistence.create_agent(a, "Agent A", "personality A")
      Hive.Persistence.create_agent(b, "Agent B", "personality B")
      cleanup_agent(a)
      cleanup_agent(b)

      body =
        conn
        |> tool_call("test-agent", "list_agents", %{})
        |> json_response(200)

      assert body["ok"] == true

      agents = Jason.decode!(body["result"])
      agent_names = Enum.map(agents, & &1["name"])

      assert a in agent_names
      assert b in agent_names
    end
  end

  # ---------------------------------------------------------------------------
  # list_topics
  # ---------------------------------------------------------------------------

  describe "list_topics" do
    test "returns a JSON list of topics", %{conn: conn} do
      a = unique("list-topic-a")
      b = unique("list-topic-b")
      :ok = Hive.Persistence.create_topic(a, "Topic A", "topic", nil)
      :ok = Hive.Persistence.create_topic(b, "Topic B", "topic", nil)
      cleanup_topic(a)
      cleanup_topic(b)

      body =
        conn
        |> tool_call("test-agent", "list_topics", %{})
        |> json_response(200)

      assert body["ok"] == true

      topics = Jason.decode!(body["result"])
      topic_names = Enum.map(topics, & &1["name"])

      assert a in topic_names
      assert b in topic_names
    end
  end

  # ---------------------------------------------------------------------------
  # Media tools
  # ---------------------------------------------------------------------------

  # 1x1 red pixel PNG
  @tiny_png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0,
              0, 1, 8, 2, 0, 0, 0, 144, 119, 83, 222, 0, 0, 0, 12, 73, 68, 65, 84, 8, 215, 99,
              248, 207, 192, 0, 0, 0, 2, 0, 1, 226, 33, 188, 51, 0, 0, 0, 0, 73, 69, 78, 68,
              174, 66, 96, 130>>

  describe "upload_media" do
    test "uploads a base64 PNG and returns a URL", %{conn: conn} do
      base64 = Base.encode64(@tiny_png)

      body =
        conn
        |> tool_call("test-agent", "upload_media", %{
          "data" => base64,
          "media_type" => "image/png"
        })
        |> json_response(200)

      assert body["ok"] == true
      assert "/uploads/" <> filename = body["result"]
      assert String.ends_with?(filename, ".png")

      # Cleanup uploaded file
      path = Path.join(Hive.Media.upload_dir(), filename)
      on_exit(fn -> File.rm(path) end)
    end

    test "rejects invalid base64 data", %{conn: conn} do
      body =
        conn
        |> tool_call("test-agent", "upload_media", %{
          "data" => "not-valid-base64!!!",
          "media_type" => "image/png"
        })
        |> json_response(200)

      assert body["ok"] == false
      assert body["error"] =~ "invalid base64"
    end

    test "rejects unsupported media types", %{conn: conn} do
      base64 = Base.encode64("not an image")

      body =
        conn
        |> tool_call("test-agent", "upload_media", %{
          "data" => base64,
          "media_type" => "text/plain"
        })
        |> json_response(200)

      assert body["ok"] == false
      assert body["error"] =~ "unsupported media type"
    end
  end

  describe "view_image" do
    test "returns base64 and media_type for an existing upload", %{conn: conn} do
      # Upload an image first
      base64 = Base.encode64(@tiny_png)

      upload_body =
        conn
        |> tool_call("test-agent", "upload_media", %{
          "data" => base64,
          "media_type" => "image/png"
        })
        |> json_response(200)

      url = upload_body["result"]

      # Now view it
      view_body =
        conn
        |> recycle()
        |> tool_call("test-agent", "view_image", %{"url" => url})
        |> json_response(200)

      assert view_body["ok"] == true
      assert view_body["result"]["base64"] == base64
      assert view_body["result"]["media_type"] == "image/png"

      # Cleanup
      "/uploads/" <> filename = url
      on_exit(fn -> File.rm(Path.join(Hive.Media.upload_dir(), filename)) end)
    end

    test "returns error for non-existent image", %{conn: conn} do
      body =
        conn
        |> tool_call("test-agent", "view_image", %{"url" => "/uploads/nonexistent.png"})
        |> json_response(200)

      assert body["ok"] == false
      assert body["error"] =~ "not found"
    end

    test "rejects non-upload URLs", %{conn: conn} do
      body =
        conn
        |> tool_call("test-agent", "view_image", %{"url" => "https://example.com/image.png"})
        |> json_response(200)

      assert body["ok"] == false
      assert body["error"] =~ "only /uploads/"
    end
  end

  # ---------------------------------------------------------------------------
  # Event source tools
  # ---------------------------------------------------------------------------

  defp cleanup_event_source(name) do
    on_exit(fn ->
      Hive.Persistence.delete_event_source(name)
    end)
  end

  describe "create_event_source" do
    test "creates a webhook event source and returns webhook URL", %{conn: conn} do
      name = unique("es-webhook")
      topic = unique("es-topic")
      :ok = Hive.Persistence.create_topic(topic, "test", "topic", nil)
      cleanup_event_source(name)
      cleanup_topic(topic)

      body =
        conn
        |> tool_call("test-agent", "create_event_source", %{
          "name" => name,
          "type" => "webhook",
          "topic" => topic
        })
        |> json_response(200)

      assert body["ok"] == true
      result = Jason.decode!(body["result"])
      assert result["name"] == name
      assert result["type"] == "webhook"
      assert result["topic"] == topic
      assert result["webhook_url"] =~ "/api/hooks/#{name}/"

      # Verify persisted
      {:ok, source} = Hive.Persistence.get_event_source(name)
      assert source.name == name
      assert source.type == "webhook"
      assert source.webhook_secret != nil
    end

    test "creates a poll event source without webhook URL", %{conn: conn} do
      name = unique("es-poll")
      topic = unique("es-poll-t")
      :ok = Hive.Persistence.create_topic(topic, "test", "topic", nil)
      cleanup_event_source(name)
      cleanup_topic(topic)

      body =
        conn
        |> tool_call("test-agent", "create_event_source", %{
          "name" => name,
          "type" => "poll",
          "topic" => topic,
          "config" => %{"command" => "echo", "args" => ["hello"], "interval_ms" => 60_000}
        })
        |> json_response(200)

      assert body["ok"] == true
      result = Jason.decode!(body["result"])
      assert result["name"] == name
      assert result["type"] == "poll"
      refute Map.has_key?(result, "webhook_url")
    end

    test "rejects invalid name", %{conn: conn} do
      body =
        conn
        |> tool_call("test-agent", "create_event_source", %{
          "name" => "../bad",
          "type" => "webhook",
          "topic" => "test-topic"
        })
        |> json_response(200)

      assert body["ok"] == false
      assert body["error"] =~ "invalid_name"
    end
  end

  describe "list_event_sources" do
    test "returns all event sources", %{conn: conn} do
      name1 = unique("es-list1")
      name2 = unique("es-list2")
      topic = unique("es-list-t")
      :ok = Hive.Persistence.create_topic(topic, "test", "topic", nil)
      cleanup_topic(topic)

      :ok =
        Hive.Persistence.create_event_source(name1, %{
          type: "webhook",
          topic: topic,
          webhook_secret: "s1",
          enabled: 1
        })

      :ok =
        Hive.Persistence.create_event_source(name2, %{
          type: "poll",
          topic: topic,
          enabled: 1
        })

      cleanup_event_source(name1)
      cleanup_event_source(name2)

      body =
        conn
        |> tool_call("test-agent", "list_event_sources", %{})
        |> json_response(200)

      assert body["ok"] == true
      sources = Jason.decode!(body["result"])
      names = Enum.map(sources, & &1["name"])
      assert name1 in names
      assert name2 in names
    end
  end

  describe "delete_event_source" do
    test "deletes an existing event source", %{conn: conn} do
      name = unique("es-del")
      topic = unique("es-del-t")
      :ok = Hive.Persistence.create_topic(topic, "test", "topic", nil)
      cleanup_topic(topic)

      :ok =
        Hive.Persistence.create_event_source(name, %{
          type: "webhook",
          topic: topic,
          webhook_secret: "s1",
          enabled: 1
        })

      body =
        conn
        |> tool_call("test-agent", "delete_event_source", %{"name" => name})
        |> json_response(200)

      assert body["ok"] == true
      assert body["result"] =~ "deleted"

      # Verify removed from persistence
      {:ok, nil} = Hive.Persistence.get_event_source(name)
    end
  end
end
