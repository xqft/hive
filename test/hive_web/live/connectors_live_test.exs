defmodule HiveWeb.ConnectorsLiveTest do
  use HiveWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  defp find_mcp_server(name) do
    {:ok, servers} = Hive.Persistence.get_mcp_servers()
    Enum.find(servers, fn s -> s.name == name end)
  end

  describe "mount" do
    test "renders page with title Connectors", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/connectors")
      assert html =~ "Connectors"
    end

    test "shows template catalog by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/connectors")
      assert html =~ "Templates"
      assert html =~ "Custom MCP Server"
      assert html =~ "Custom Event Source"
    end

    test "shows MCP Servers section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/connectors")
      assert html =~ "MCP Servers"
    end

    test "shows Event Sources section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/connectors")
      assert html =~ "Event Sources"
    end
  end

  describe "MCP server CRUD" do
    test "creating an MCP server", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/connectors")

      view |> element("button", "Custom MCP Server") |> render_click()
      assert has_element?(view, "h2", "Install MCP Server")

      view
      |> form("form", %{
        name: "test-mcp",
        description: "Test server",
        command: "echo",
        args: ~s(["hello"]),
        env: "{}"
      })
      |> render_submit()

      html = render(view)
      assert html =~ "test-mcp"

      server = find_mcp_server("test-mcp")
      assert server != nil
      assert server.command == "echo"

      Hive.Persistence.delete_mcp_server("test-mcp")
    end

    test "selecting and editing an MCP server", %{conn: conn} do
      :ok = Hive.Persistence.create_mcp_server("edit-mcp", "old desc", "echo", [], %{})
      on_exit(fn -> Hive.Persistence.delete_mcp_server("edit-mcp") end)

      {:ok, view, _html} = live(conn, "/connectors")

      view
      |> element("[phx-click=select_item][phx-value-name=edit-mcp]")
      |> render_click()

      assert has_element?(view, "h2", "Edit: edit-mcp")

      view
      |> form("form", %{
        description: "new desc",
        command: "node",
        args: "[]",
        env: "{}"
      })
      |> render_submit()

      server = find_mcp_server("edit-mcp")
      assert server.description == "new desc"
      assert server.command == "node"
    end

    test "deleting an MCP server", %{conn: conn} do
      :ok = Hive.Persistence.create_mcp_server("del-mcp", "to delete", "echo", [], %{})

      {:ok, view, _html} = live(conn, "/connectors")

      view
      |> element("[phx-click=select_item][phx-value-name=del-mcp]")
      |> render_click()

      view |> element("button", "Delete") |> render_click()

      # Verify deleted from persistence
      assert find_mcp_server("del-mcp") == nil
    end

    test "validation rejects empty command", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/connectors")

      view |> element("button", "Custom MCP Server") |> render_click()

      view
      |> form("form", %{
        name: "no-cmd",
        command: "",
        args: "[]",
        env: "{}"
      })
      |> render_submit()

      assert has_element?(view, ".text-error", "Command is required")
    end
  end

  describe "event source CRUD" do
    test "creating a webhook event source", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/connectors")

      view |> element("button", "Custom Event Source") |> render_click()
      assert has_element?(view, "h2", "New Event Source")

      view
      |> form("form", %{
        name: "test-events",
        type: "webhook",
        topic: "my-topic",
        enabled: "true"
      })
      |> render_submit()

      {:ok, es} = Hive.Persistence.get_event_source("test-events")
      assert es.type == "webhook"
      assert es.topic == "my-topic"
      assert es.webhook_secret != nil

      Hive.Persistence.delete_event_source("test-events")
    end

    test "creating a poll event source", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/connectors")

      view |> element("button", "Custom Event Source") |> render_click()

      # Change type to poll so poll fields render
      view |> form("form", %{type: "poll", name: "poll-src", topic: "poll-topic"}) |> render_change()

      view
      |> form("form", %{
        name: "poll-src",
        type: "poll",
        topic: "poll-topic",
        poll_command: "curl",
        poll_args: ~s(["-s", "https://example.com"]),
        poll_interval: "30",
        enabled: "true"
      })
      |> render_submit()

      {:ok, es} = Hive.Persistence.get_event_source("poll-src")
      assert es.type == "poll"
      assert es.topic == "poll-topic"

      Hive.Persistence.delete_event_source("poll-src")
    end

    test "deleting an event source", %{conn: conn} do
      :ok =
        Hive.Persistence.create_event_source("del-event", %{
          type: "webhook",
          topic: "test-topic",
          config: %{},
          enabled: true
        })

      on_exit(fn -> Hive.Persistence.delete_event_source("del-event") end)

      {:ok, view, _html} = live(conn, "/connectors")
      assert render(view) =~ "del-event"

      view
      |> element("[phx-click=select_item][phx-value-name=del-event]")
      |> render_click()

      view |> element("button", "Delete") |> render_click()

      {:ok, nil} = Hive.Persistence.get_event_source("del-event")
    end

    test "validation rejects missing topic", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/connectors")

      view |> element("button", "Custom Event Source") |> render_click()

      view
      |> form("form", %{name: "no-topic", type: "webhook", topic: ""})
      |> render_submit()

      assert has_element?(view, ".text-error", "Topic is required")
    end
  end

  describe "toggle enable/disable" do
    test "toggling event source enabled state", %{conn: conn} do
      :ok =
        Hive.Persistence.create_event_source("toggle-ev", %{
          type: "webhook",
          topic: "toggle-topic",
          config: %{},
          enabled: true
        })

      on_exit(fn -> Hive.Persistence.delete_event_source("toggle-ev") end)

      {:ok, view, _html} = live(conn, "/connectors")
      assert render(view) =~ "toggle-ev"

      view |> render_hook("toggle_enabled", %{"name" => "toggle-ev"})

      {:ok, updated} = Hive.Persistence.get_event_source("toggle-ev")
      assert updated.enabled == 0
    end
  end

  describe "webhook display" do
    test "webhook URL displayed for webhook event sources", %{conn: conn} do
      :ok =
        Hive.Persistence.create_event_source("wh-display", %{
          type: "webhook",
          topic: "wh-topic",
          config: %{},
          webhook_secret: "test-secret-123",
          enabled: true
        })

      on_exit(fn -> Hive.Persistence.delete_event_source("wh-display") end)

      {:ok, view, _html} = live(conn, "/connectors")

      view
      |> element("[phx-click=select_item][phx-value-name=wh-display]")
      |> render_click()

      html = render(view)
      assert html =~ "/api/webhooks/wh-display"
      assert html =~ "test-secret-123"
    end
  end

  describe "template catalog" do
    test "shows templates from Templates module", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/connectors")
      assert html =~ "Templates"
    end

    test "clicking a template opens the wizard", %{conn: conn} do
      templates = Hive.Connector.Templates.list()

      if templates != [] do
        {:ok, view, _html} = live(conn, "/connectors")
        template = hd(templates)

        view
        |> element("[phx-click=use_template][phx-value-slug=#{template["slug"]}]")
        |> render_click()

        assert has_element?(view, "h2", "Setup: #{template["name"]}")
      end
    end
  end
end
