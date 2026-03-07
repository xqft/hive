defmodule HiveWeb.ChatLiveTest do
  use HiveWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduledoc """
  Tests for the ChatLive LiveView.

  Requires the full application stack (Persistence, Registries, TopicSup, etc.)
  since the LiveView loads topics, agents, and messages on mount.
  """

  defp create_topic(name) do
    :ok = Hive.Persistence.create_topic(name, "Test: #{name}", "topic", nil)

    {:ok, pid} =
      DynamicSupervisor.start_child(
        Hive.TopicSup,
        {Hive.Topic, name: name, description: "Test: #{name}", type: :topic, created_by: "test"}
      )

    pid
  end

  defp cleanup_topic(name) do
    case Registry.lookup(Hive.TopicRegistry, name) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end

    Hive.Persistence.delete_topic(name)
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
      assert html =~ "Direct Messages"
    end

    test "shows Members section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Members"
    end

    test "shows navigation links", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Dashboard"
      assert html =~ "Agents"
      assert html =~ "MCP Servers"
    end
  end

  describe "topic selection" do
    test "selecting a topic updates the active topic display", %{conn: conn} do
      topic = "lv-sel-#{:erlang.unique_integer([:positive])}"
      create_topic(topic)
      on_exit(fn -> cleanup_topic(topic) end)

      {:ok, view, _html} = live(conn, "/")

      html = view |> element("button[phx-value-name=#{topic}]") |> render_click()
      assert html =~ topic
    end

    test "selecting a topic loads its messages", %{conn: conn} do
      topic = "lv-msg-#{:erlang.unique_integer([:positive])}"
      create_topic(topic)
      on_exit(fn -> cleanup_topic(topic) end)

      Hive.Topic.join(topic, "alice")
      Hive.Topic.post(topic, "alice", "hello from alice in liveview test")

      {:ok, view, _html} = live(conn, "/")

      html = view |> element("button[phx-value-name=#{topic}]") |> render_click()
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
      view |> element("button[phx-value-name=#{topic}]") |> render_click()

      # Submit the message form
      view
      |> form("form[phx-submit=send_message]", %{text: "hello from liveview"})
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
      |> form("form[phx-submit=send_message]", %{text: ""})
      |> render_submit()

      # View should still be alive
      assert render(view) =~ "Hive"
    end
  end
end
