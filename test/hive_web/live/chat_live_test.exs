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
          start_supervised!(%{
            id: {Hive.Topic, name},
            start:
              {Hive.Topic, :start_link,
               [[name: name, description: "Test: #{name}", type: :topic, created_by: "test"]]}
          })
      end

    pid
  end

  defp cleanup_topic(name) do
    case Registry.lookup(Hive.TopicRegistry, name) do
      [{pid, _}] ->
        try do
          GenServer.stop(pid, :normal)
        catch
          :exit, _ -> :ok
        end

      [] ->
        :ok
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

    test "shows members badge", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "members"
    end

    test "shows navigation links", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Overview"
      assert html =~ "Agents"
      assert html =~ "Connectors"
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

    test "off-screen messages increment unread and appear when reopening the topic", %{conn: conn} do
      active_topic = "lv-active-#{:erlang.unique_integer([:positive])}"
      inactive_topic = "lv-inactive-#{:erlang.unique_integer([:positive])}"

      create_topic(active_topic)
      create_topic(inactive_topic)

      on_exit(fn ->
        cleanup_topic(active_topic)
        cleanup_topic(inactive_topic)
      end)

      {:ok, view, _html} = live(conn, "/")

      view |> element("#topic-#{active_topic}") |> render_click()
      Hive.Topic.post(inactive_topic, "alice", "buffered off-screen message")

      assert has_element?(view, "#topic-unread-#{inactive_topic}", "1")

      html = view |> element("#topic-#{inactive_topic}") |> render_click()
      assert html =~ "buffered off-screen message"
      refute has_element?(view, "#topic-unread-#{inactive_topic}")
    end

    test "buffered messages do not duplicate when the topic is reopened", %{conn: conn} do
      active_topic = "lv-active-dedup-#{:erlang.unique_integer([:positive])}"
      buffered_topic = "lv-buffered-dedup-#{:erlang.unique_integer([:positive])}"

      create_topic(active_topic)
      create_topic(buffered_topic)

      on_exit(fn ->
        cleanup_topic(active_topic)
        cleanup_topic(buffered_topic)
      end)

      {:ok, view, _html} = live(conn, "/")

      view |> element("#topic-#{active_topic}") |> render_click()
      Hive.Topic.post(buffered_topic, "alice", "dedup message")

      html = view |> element("#topic-#{buffered_topic}") |> render_click()
      assert length(String.split(html, ~s(data-mention-body="dedup message"))) == 2
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

    test "submitting the form in a DM renders the message and subsequent agent reply", %{
      conn: conn
    } do
      agent = "dm-agent-#{:erlang.unique_integer([:positive])}"
      dm_name = Hive.Topic.dm_channel_name("human", agent)

      create_agent(agent)

      on_exit(fn ->
        cleanup_agent(agent)
        cleanup_topic(dm_name)
      end)

      {:ok, view, _html} = live(conn, "/")

      view |> element("button[phx-click=toggle_new_dm]") |> render_click()
      view |> element("#start-dm-#{agent}") |> render_click()

      view
      |> form("#msg-form-0", %{text: "hello in dm"})
      |> render_submit()

      assert render(view) =~ "hello in dm"

      :ok = Hive.Topic.post(dm_name, agent, "reply in dm")

      assert render(view) =~ "reply in dm"
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

      assert has_element?(view, "#typing-indicator", "alice, bob are thinking")
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
