defmodule HiveWeb.ContainerLive do
  use HiveWeb, :live_view

  @impl true
  def mount(%{"name" => agent_name}, _session, socket) do
    container_name = "hive-agent-#{agent_name}"
    status = check_container_status(container_name)

    {:ok,
     assign(socket,
       page_title: "Terminal: #{agent_name}",
       agent_name: agent_name,
       container_name: container_name,
       status: status,
       relay: nil
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.app_shell current={:chat} title={"Terminal: #{@agent_name}"}>
        <div class="ui-stack">
          <div class="ui-section-row">
            <h1 class="ui-page-title">Terminal — {@agent_name}</h1>
            <.button navigate={~p"/"} variant="ghost">Back</.button>
          </div>
          <div class="ui-card ui-section-row">
            <div>
              <p class="ui-section-label">Agent container</p>
              <p class="mt-1 font-mono text-sm text-[var(--ui-text-strong)]">{@container_name}</p>
            </div>
            <.container_status_badge status={@status} />
          </div>

          <div
            :if={@status == :running}
            id="terminal"
            phx-hook="Terminal"
            class="ui-terminal"
            phx-update="ignore"
          />

          <div :if={@status == :stopped} class="ui-empty">
            Agent container is not running. Send a message to the agent to wake it up.
          </div>
        </div>
      </.app_shell>
    </Layouts.app>
    """
  end

  # -- Status badge component --------------------------------------------------

  defp container_status_badge(assigns) do
    ~H"""
    <span :if={@status == :running} class="ui-pill" style="color: var(--ui-success)">running</span>
    <span :if={@status == :stopped} class="ui-pill" style="color: var(--ui-text-soft)">stopped</span>
    """
  end

  # -- Terminal relay handlers -------------------------------------------------

  @impl true
  def handle_info({:terminal_output, data}, socket) do
    {:noreply, push_event(socket, "terminal_output", %{data: Base.encode64(data)})}
  end

  def handle_info(:terminal_closed, socket) do
    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # -- Events -----------------------------------------------------------------

  @impl true
  def handle_event("terminal_input", %{"data" => data}, socket) do
    if socket.assigns.relay do
      Hive.TerminalRelay.send_input(socket.assigns.relay, Base.decode64!(data))
    end

    {:noreply, socket}
  end

  def handle_event("terminal_resize", %{"cols" => cols, "rows" => rows}, socket) do
    case socket.assigns.relay do
      nil ->
        # First resize event from xterm.js — start relay with correct dimensions
        relay = start_relay(socket.assigns.container_name, cols, rows)
        {:noreply, assign(socket, :relay, relay)}

      pid when is_pid(pid) ->
        Hive.TerminalRelay.resize(pid, cols, rows)
        {:noreply, socket}
    end
  end

  # -- Private ----------------------------------------------------------------

  defp start_relay(container_name, cols, rows) do
    case Hive.TerminalRelay.start_link(
           container_id: container_name,
           viewer: self(),
           cols: cols,
           rows: rows,
           session: "shell"
         ) do
      {:ok, pid} -> pid
      {:error, _} -> nil
    end
  end

  defp check_container_status(container_name) do
    docker = docker_executable()

    case System.cmd(docker, ["inspect", "--format", "{{.State.Running}}", container_name],
           stderr_to_stdout: true
         ) do
      {"true\n", 0} -> :running
      _ -> :stopped
    end
  end

  defp docker_executable do
    Application.get_env(:hive, :container_docker_executable) ||
      System.find_executable("docker") ||
      "docker"
  end
end
