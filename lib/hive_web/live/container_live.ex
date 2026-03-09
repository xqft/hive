defmodule HiveWeb.ContainerLive do
  use HiveWeb, :live_view

  @impl true
  def mount(%{"name" => agent_name}, _session, socket) do
    container_name = "hive-agent-#{agent_name}"

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hive.PubSub, "container:#{container_name}")
    end

    status = check_container_status(container_name)

    {:ok,
     assign(socket,
       page_title: "Terminal: #{agent_name}",
       container_id: container_name,
       agent_name: agent_name,
       status: status,
       relay: nil
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.app_shell
        current={:dashboard}
        title="Container"
      >
        <div class="ui-stack">
          <div class="ui-section-row">
            <h1 class="ui-page-title">Container</h1>
            <div class="flex items-center gap-2">
              <.button
                :if={@status == :running}
                phx-click="kill"
                variant="danger"
                data-confirm="Kill this container?"
              >
                Kill
              </.button>
              <.button navigate={~p"/dashboard"} variant="ghost">Back</.button>
            </div>
          </div>
          <div class="ui-card ui-section-row">
            <div>
              <p class="ui-section-label">Container id</p>
              <p class="mt-1 font-mono text-lg text-[var(--ui-text-strong)]">{@container_id}</p>
            </div>
            <.container_status_badge status={@status} />
          </div>

          <div
            :if={@status in [:running, :completed, :failed]}
            id="terminal"
            phx-hook="Terminal"
            class="ui-terminal"
            phx-update="ignore"
          />

          <div :if={@status == :not_found} class="ui-empty">
            Container not found
          </div>
        </div>
      </.app_shell>
    </Layouts.app>
    """
  end

  # -- Status badge component --------------------------------------------------

  defp container_status_badge(assigns) do
    ~H"""
    <span :if={@status == :running} class="ui-pill" style="color: var(--ui-warning)">running</span>
    <span :if={@status == :completed} class="ui-pill" style="color: var(--ui-success)">
      completed
    </span>
    <span :if={@status == :failed} class="ui-pill" style="color: var(--ui-danger)">failed</span>
    <span :if={@status == :not_found} class="ui-pill">not found</span>
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

  # Container status updates from PubSub
  def handle_info({:stopped, container_id, status}, socket)
      when container_id == socket.assigns.container_id do
    {:noreply, assign(socket, :status, status)}
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
        relay = start_relay(socket.assigns.container_id, cols, rows)
        {:noreply, assign(socket, :relay, relay)}

      pid when is_pid(pid) ->
        Hive.TerminalRelay.resize(pid, cols, rows)
        {:noreply, socket}
    end
  end

  def handle_event("kill", _params, socket) do
    # Persistent containers are managed by the Agent GenServer; navigate back
    {:noreply, push_navigate(socket, to: ~p"/dashboard")}
  end

  # -- Private ----------------------------------------------------------------

  defp start_relay(container_id, cols, rows) do
    case check_container_status(container_id) do
      :running ->
        case Hive.TerminalRelay.start_link(
               container_id: container_id,
               viewer: self(),
               cols: cols,
               rows: rows
             ) do
          {:ok, pid} -> pid
          {:error, _} -> nil
        end

      _ ->
        nil
    end
  end

  defp check_container_status(container_name) do
    docker =
      Application.get_env(:hive, :container_docker_executable) ||
        System.find_executable("docker") ||
        "docker"

    case System.cmd(docker, ["container", "inspect", "-f", "{{.State.Running}}", container_name],
           stderr_to_stdout: true
         ) do
      {"true\n", 0} -> :running
      _ -> :not_found
    end
  end
end
