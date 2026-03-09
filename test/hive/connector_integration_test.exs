defmodule Hive.ConnectorIntegrationTest do
  @moduledoc """
  Integration tests for the connector subsystem: EventSource GenServer,
  webhook controller, template flow, formatter, and agent tools.
  """

  use HiveWeb.ConnCase, async: false

  alias Hive.Persistence
  alias Hive.Connector.EventSource
  alias Hive.Connector.Formatter
  alias Hive.Connector.Templates

  setup do
    ts = rem(System.system_time(:millisecond), 100_000)
    n = :erlang.unique_integer([:positive])
    prefix = "ci#{ts}x#{n}"

    on_exit(fn ->
      cleanup_event_sources(prefix)
      cleanup_mcp_servers(prefix)
      cleanup_topics(prefix)
    end)

    %{p: prefix}
  end

  # ---------------------------------------------------------------------------
  # Poll flow
  # ---------------------------------------------------------------------------

  describe "poll event source flow" do
    test "poll source executes command and posts to topic on change", %{p: p} do
      topic_name = "#{p}-poll-topic"
      es_name = "#{p}-poll"

      # Create the topic so we can subscribe
      :ok = Persistence.create_topic(topic_name, "test poll topic")

      # Start the topic GenServer
      start_topic(topic_name)
      Hive.Topic.join(topic_name, "test-observer")

      # Subscribe to PubSub to catch messages
      Phoenix.PubSub.subscribe(Hive.PubSub, "topic:#{topic_name}")

      # Create event source in persistence
      :ok =
        Persistence.create_event_source(es_name, %{
          type: "poll",
          topic: topic_name,
          config: %{
            "command" => "echo",
            "args" => ["poll-output-#{p}"],
            "interval_ms" => 60_000
          },
          enabled: true
        })

      # Start the EventSource GenServer directly
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Hive.EventSourceSup,
          {EventSource,
           name: es_name,
           type: "poll",
           topic: topic_name,
           config: %{
             "command" => "echo",
             "args" => ["poll-output-#{p}"],
             "interval_ms" => 60_000
           }}
        )

      # Wait for the initial poll + post
      assert_receive {:message, %{topic: ^topic_name, sender: "system", body: body}}, 5_000
      assert body =~ es_name
      assert body =~ "poll-output-#{p}"

      # Get info
      info = EventSource.info(es_name)
      assert info.name == es_name
      assert info.type == "poll"

      # Cleanup
      EventSource.stop(es_name)
    end
  end

  # ---------------------------------------------------------------------------
  # Webhook flow
  # ---------------------------------------------------------------------------

  describe "webhook event source flow" do
    test "webhook POST delivers event to topic via EventSource", %{p: p, conn: conn} do
      topic_name = "#{p}-wh-topic"
      es_name = "#{p}-wh"
      secret = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

      # Create topic and subscribe
      :ok = Persistence.create_topic(topic_name, "test webhook topic")
      start_topic(topic_name)
      Hive.Topic.join(topic_name, "test-observer")
      Phoenix.PubSub.subscribe(Hive.PubSub, "topic:#{topic_name}")

      # Create event source in persistence
      :ok =
        Persistence.create_event_source(es_name, %{
          type: "webhook",
          topic: topic_name,
          config: %{},
          webhook_secret: secret,
          enabled: true
        })

      # Start the webhook EventSource GenServer
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Hive.EventSourceSup,
          {EventSource, name: es_name, type: "webhook", topic: topic_name}
        )

      # POST to webhook endpoint
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/hooks/#{es_name}/#{secret}", %{event: "push", repo: "test/repo"})

      assert json_response(conn, 200) == %{"ok" => true}

      # Should receive the formatted event
      assert_receive {:message, %{topic: ^topic_name, sender: "system", body: body}}, 5_000
      assert body =~ es_name

      # Cleanup
      EventSource.stop(es_name)
    end

    test "webhook rejects invalid secret", %{p: p, conn: conn} do
      es_name = "#{p}-wh-bad"
      secret = "correct-secret"

      :ok =
        Persistence.create_event_source(es_name, %{
          type: "webhook",
          topic: "ignored",
          config: %{},
          webhook_secret: secret,
          enabled: true
        })

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/hooks/#{es_name}/wrong-secret", %{event: "push"})

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "webhook rejects disabled event source", %{p: p, conn: conn} do
      es_name = "#{p}-wh-off"
      secret = "the-secret"

      :ok =
        Persistence.create_event_source(es_name, %{
          type: "webhook",
          topic: "ignored",
          config: %{},
          webhook_secret: secret,
          enabled: false
        })

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/hooks/#{es_name}/#{secret}", %{event: "push"})

      assert json_response(conn, 503) == %{"error" => "event source disabled"}
    end

    test "webhook returns 404 for unknown event source", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/hooks/nonexistent/secret", %{event: "push"})

      assert json_response(conn, 404) == %{"error" => "not found"}
    end
  end

  # ---------------------------------------------------------------------------
  # Formatter
  # ---------------------------------------------------------------------------

  describe "formatter" do
    test "fallback formatter truncates and prefixes" do
      # Ensure no API key so fallback is used
      old = Application.get_env(:hive, :anthropic_api_key)
      Application.delete_env(:hive, :anthropic_api_key)

      on_exit(fn ->
        if old, do: Application.put_env(:hive, :anthropic_api_key, old)
      end)

      {:ok, result} = Formatter.format("my-source", "hello world")
      assert result == "[my-source] hello world"
    end

    test "fallback formatter truncates long payloads" do
      old = Application.get_env(:hive, :anthropic_api_key)
      Application.delete_env(:hive, :anthropic_api_key)

      on_exit(fn ->
        if old, do: Application.put_env(:hive, :anthropic_api_key, old)
      end)

      long = String.duplicate("a", 1000)
      {:ok, result} = Formatter.format("src", long)
      assert result =~ "[src]"
      # Should be truncated to ~500 chars + source prefix + "..."
      assert String.length(result) < 600
      assert result =~ "..."
    end
  end

  # ---------------------------------------------------------------------------
  # Template flow
  # ---------------------------------------------------------------------------

  describe "template flow" do
    test "list returns templates from priv/connector_templates" do
      templates = Templates.list()
      assert is_list(templates)
      # We know github.json exists
      slugs = Enum.map(templates, fn t -> t["slug"] end)
      assert "github" in slugs
    end

    test "get returns a specific template" do
      template = Templates.get("github")
      assert template["name"] == "GitHub"
      assert template["mcp"]["command"] == "npx"
      assert template["event"]["type"] == "webhook"
    end

    test "get returns nil for unknown template" do
      assert Templates.get("nonexistent") == nil
    end

    test "apply_config resolves placeholders" do
      template = Templates.get("github")
      user_config = %{"github_token" => "gh_abc123", "topic" => "my-gh-events"}
      result = Templates.apply_config(template, user_config)

      assert result.mcp.command == "npx"
      assert result.mcp.env["GITHUB_PERSONAL_ACCESS_TOKEN"] == "gh_abc123"
      assert result.event.type == "webhook"
      assert result.event.topic == "my-gh-events"
    end

    test "full template-to-persistence flow", %{p: p} do
      template = Templates.get("github")
      user_config = %{"github_token" => "test-token", "topic" => "#{p}-gh-events"}
      applied = Templates.apply_config(template, user_config)

      mcp_name = "#{p}-github"

      # Create MCP server
      :ok =
        Persistence.create_mcp_server(
          mcp_name,
          template["description"],
          applied.mcp.command,
          applied.mcp.args,
          applied.mcp.env
        )

      # Create event source linked to MCP
      event_name = "#{p}-gh-events"
      secret = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

      :ok =
        Persistence.create_event_source(event_name, %{
          type: applied.event.type,
          topic: applied.event.topic,
          config: %{},
          webhook_secret: secret,
          mcp_server: mcp_name,
          enabled: true
        })

      # Verify the linked pair exists
      {:ok, servers} = Persistence.get_mcp_servers()
      assert Enum.any?(servers, fn s -> s.name == mcp_name end)

      {:ok, es} = Persistence.get_event_source(event_name)
      assert es.mcp_server == mcp_name
      assert es.type == "webhook"
    end
  end

  # ---------------------------------------------------------------------------
  # Agent tools
  # ---------------------------------------------------------------------------

  describe "agent event source tools" do
    setup %{p: p} do
      agent_name = "#{p}-agent"
      :ok = Persistence.create_agent(agent_name, "test agent", "test personality")
      on_exit(fn -> Persistence.delete_agent(agent_name) end)
      %{agent: agent_name}
    end

    test "create_event_source via tools API", %{conn: conn, agent: agent, p: p} do
      es_name = "#{p}-tool-es"

      resp =
        conn
        |> authed_conn(agent)
        |> post("/api/tools", %{
          agent: agent,
          tool: "create_event_source",
          params: %{
            name: es_name,
            type: "webhook",
            topic: "#{p}-tool-topic"
          }
        })

      assert json_response(resp, 200)["ok"] == true

      {:ok, es} = Persistence.get_event_source(es_name)
      assert es.type == "webhook"
      assert es.topic == "#{p}-tool-topic"
    end

    test "list_event_sources via tools API", %{conn: conn, agent: agent, p: p} do
      es_name = "#{p}-list-es"

      :ok =
        Persistence.create_event_source(es_name, %{
          type: "poll",
          topic: "#{p}-list-topic",
          config: %{},
          enabled: true
        })

      resp =
        conn
        |> authed_conn(agent)
        |> post("/api/tools", %{
          agent: agent,
          tool: "list_event_sources",
          params: %{}
        })

      body = json_response(resp, 200)
      assert body["ok"] == true
      sources = Jason.decode!(body["result"])
      assert is_list(sources)
      assert Enum.any?(sources, fn es -> es["name"] == es_name end)
    end

    test "delete_event_source via tools API", %{conn: conn, agent: agent, p: p} do
      es_name = "#{p}-del-es"

      :ok =
        Persistence.create_event_source(es_name, %{
          type: "webhook",
          topic: "#{p}-del-topic",
          config: %{},
          enabled: true
        })

      resp =
        conn
        |> authed_conn(agent)
        |> post("/api/tools", %{
          agent: agent,
          tool: "delete_event_source",
          params: %{name: es_name}
        })

      assert json_response(resp, 200)["ok"] == true
      assert {:ok, nil} = Persistence.get_event_source(es_name)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

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

  defp start_topic(name) do
    case Registry.lookup(Hive.TopicRegistry, name) do
      [{pid, _}] ->
        pid

      [] ->
        pid =
          start_supervised!(%{
            id: {Hive.Topic, name},
            start:
              {Hive.Topic, :start_link,
               [[name: name, description: "Test: #{name}", type: :topic, created_by: "test"]]}
          })

        pid
    end
  end

  defp cleanup_event_sources(prefix) do
    case Persistence.get_event_sources() do
      {:ok, sources} ->
        sources
        |> Enum.filter(&String.starts_with?(&1.name, prefix))
        |> Enum.each(fn es ->
          try do
            EventSource.stop(es.name)
          catch
            :exit, _ -> :ok
          end

          Persistence.delete_event_source(es.name)
        end)

      _ ->
        :ok
    end
  end

  defp cleanup_mcp_servers(prefix) do
    case Persistence.get_mcp_servers() do
      {:ok, servers} ->
        servers
        |> Enum.filter(&String.starts_with?(&1.name, prefix))
        |> Enum.each(&Persistence.delete_mcp_server(&1.name))

      _ ->
        :ok
    end
  end

  defp cleanup_topics(prefix) do
    case Persistence.get_topics() do
      {:ok, topics} ->
        topics
        |> Enum.filter(&String.starts_with?(&1.name, prefix))
        |> Enum.each(fn t ->
          case Registry.lookup(Hive.TopicRegistry, t.name) do
            [{pid, _}] ->
              try do
                GenServer.stop(pid, :normal)
              catch
                :exit, _ -> :ok
              end

            [] ->
              :ok
          end

          Persistence.delete_topic(t.name)
        end)

      _ ->
        :ok
    end
  end
end
