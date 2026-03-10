defmodule HiveWeb.ContainerLive do
  use HiveWeb, :live_view

  @impl true
  def mount(%{"name" => agent_name}, _session, socket) do
    {:ok, push_navigate(socket, to: ~p"/agent/#{agent_name}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <p>Redirecting…</p>
    """
  end
end
