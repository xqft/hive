defmodule HiveWeb.Router do
  use HiveWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HiveWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", HiveWeb do
    pipe_through :browser

    live "/", ChatLive
    live "/dashboard", DashboardLive
    live "/agents", AgentEditorLive
    live "/connectors", ConnectorsLive
    live "/containers/:id", ContainerLive
  end

  scope "/api", HiveWeb do
    pipe_through :api

    post "/tools", ToolsController, :call_tool
    post "/hooks/:event_source_name/:secret", WebhookController, :receive_event
  end
end
