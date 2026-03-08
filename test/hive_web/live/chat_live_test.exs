defmodule HiveWeb.ChatLiveTest do
  use HiveWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduledoc """
  Tests for the ChatLive LiveView.

  Requires the full application stack (Persistence, Registries, TopicSup, etc.)
  since the LiveView loads topics, agents, and messages on mount.
  """

  defp create_topic(name) do
    case Hive.Persistence.create_topic(name, "Test: #{name}", "topic", nil) do
      :ok ->
        :ok

      {:error, :name_taken} ->
        :ok
    end

    pid =
      case Registry.lookup(Hive.TopicRegistry, name) do
        [{existing_pid, _}] ->
          existing_pid

        [] ->
          {:ok, started_pid} =
            DynamicSupervisor.start_child(
              Hive.TopicSup,
              {Hive.Topic,
               name: name, description: "Test: #{name}", type: :topic, created_by: "test"}
            )

          started_pid
      end

    pid
  end

  defp cleanup_topic(name) do
    case Registry.lookup(Hive.TopicRegistry, name) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end

    Hive.Persistence.delete_topic(name)
  end

  defp create_agent(name) do
    case Hive.Persistence.create_agent(name, "Agent #{name}", "Helpful #{name}") do
      :ok -> :ok
      {:error, :name_taken} -> :ok
    end
  end

  defp cleanup_agent(name) do
    Hive.Persistence.delete_agent(name)
  end

  describe "mount" do
    test "renders with Hive text", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Hive"
    end

    test "shows Topics section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Topics"
    end

    test "shows Direct Messages section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Direct messages"
    end

    test "shows Members section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Members"
    end

    test "shows navigation links", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Overview"
      assert html =~ "Agents"
      assert html =~ "MCP"
    end
  end

  describe "topic selection" do
    test "selecting a topic updates the active topic display", %{conn: conn} do
      topic = "lv-sel-#{:erlang.unique_integer([:positive])}"
      create_topic(topic)
      on_exit(fn -> cleanup_topic(topic) end)

      {:ok, view, _html} = live(conn, "/")

      view |> element("#topic-#{topic}") |> render_click()
      assert has_element?(view, ".ui-chat-panel__title", "##{topic}")
    end

    test "selecting a topic loads its messages", %{conn: conn} do
      topic = "lv-msg-#{:erlang.unique_integer([:positive])}"
      create_topic(topic)
      on_exit(fn -> cleanup_topic(topic) end)

      Hive.Topic.join(topic, "alice")
      Hive.Topic.post(topic, "alice", "hello from alice in liveview test")

      {:ok, view, _html} = live(conn, "/")

      html = view |> element("#topic-#{topic}") |> render_click()
      assert html =~ "hello from alice in liveview test"
      assert html =~ "alice"
    end
  end

  describe "sending messages" do
    test "submitting the form sends a message to the active topic", %{conn: conn} do
      topic = "lv-send-#{:erlang.unique_integer([:positive])}"
      create_topic(topic)
      on_exit(fn -> cleanup_topic(topic) end)

      {:ok, view, _html} = live(conn, "/")

      # Select the topic first
      view |> element("#topic-#{topic}") |> render_click()

      # Submit the message form
      view
      |> form("#msg-form-0", %{text: "hello from liveview"})
      |> render_submit()

      # The PubSub message is delivered asynchronously to the LiveView process.
      # render/1 flushes any pending messages, so the view should reflect it.
      html = render(view)
      assert html =~ "hello from liveview"
    end

    test "submitting empty text does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Submit empty message -- should be handled gracefully
      view
      |> form("#msg-form-0", %{text: ""})
      |> render_submit()

      # View should still be alive
      assert render(view) =~ "Hive"
    end

    test "renders markdown safely", %{conn: conn} do
      topic = "lv-md-#{:erlang.unique_integer([:positive])}"
      create_topic(topic)
      on_exit(fn -> cleanup_topic(topic) end)

      Hive.Topic.post(topic, "alice", "**bold**\n\n`code`\n\n<script>alert('x')</script>")

      {:ok, view, _html} = live(conn, "/")

      view |> element("#topic-#{topic}") |> render_click()

      assert has_element?(view, ".ui-markdown strong", "bold")
      assert has_element?(view, ".ui-markdown code", "code")
      refute render(view) =~ "<script>alert('x')</script>"
    end

    test "exposes agent mention metadata to the chat UI", %{conn: conn} do
      agent = "mention_agent_#{:erlang.unique_integer([:positive])}"

      create_agent(agent)

      on_exit(fn -> cleanup_agent(agent) end)

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "chat-composer-shell"
      assert html =~ "data-agent-profiles"
      assert html =~ agent
    end

    test "member join event updates sidebar and appends a system message", %{conn: conn} do
      topic = "lv-join-#{:erlang.unique_integer([:positive])}"
      create_topic(topic)
      on_exit(fn -> cleanup_topic(topic) end)

      {:ok, view, _html} = live(conn, "/")
      view |> element("#topic-#{topic}") |> render_click()

      send(view.pid, {:member_joined, %{topic: topic, agent: "alice", ts: DateTime.utc_now()}})

      html = render(view)
      assert html =~ "alice joined"
      assert html =~ "alice"
    end

    test "typing events render a summary for the active topic", %{conn: conn} do
      topic = "lv-typing-#{:erlang.unique_integer([:positive])}"
      create_topic(topic)
      on_exit(fn -> cleanup_topic(topic) end)

      {:ok, view, _html} = live(conn, "/")
      view |> element("#topic-#{topic}") |> render_click()

      send(view.pid, {:typing, %{topic: topic, agent: "alice", typing: true}})
      send(view.pid, {:typing, %{topic: topic, agent: "bob", typing: true}})

      assert has_element?(view, "#typing-indicator", "alice, bob are typing")
    end

    test "container events update the sidebar immediately", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:started, "builder", "container-123", "Run tests"})

      html = render(view)
      assert html =~ "container-123"
      assert html =~ "Run tests"
      assert html =~ "builder"
    end
  end
end
