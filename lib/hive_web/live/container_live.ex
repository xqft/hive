defmodule HiveWeb.ContainerLive do
  use HiveWeb, :live_view

  @impl true
  def mount(%{"id" => container_id}, _session, socket) do
    relay =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Hive.PubSub, "container:#{container_id}")
        Phoenix.PubSub.subscribe(Hive.PubSub, "containers")

        case Hive.Container.check(container_id) do
          {:ok, _} ->
            case Hive.TerminalRelay.start_link(
                   container_id: container_id,
                   viewer: self()
                 ) do
              {:ok, pid} -> pid
              {:error, _} -> nil
            end

          {:error, :not_found} ->
            nil
        end
      end

    {status, _} = load_initial_state(container_id)

    {:ok,
     assign(socket,
       page_title: container_id,
       container_id: container_id,
       status: status,
       relay: relay
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.app_shell
        current={:dashboard}
        title="Container"
        subtitle={@container_id}
      >
        <:actions>
          <.button
            :if={@status == :running}
            phx-click="kill"
            variant="danger"
            data-confirm="Kill this container?"
          >
            Kill
          </.button>
          <.button navigate={~p"/dashboard"} variant="ghost">Back</.button>
        </:actions>

        <div class="ui-stack">
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
    if socket.assigns.relay do
      Hive.TerminalRelay.resize(socket.assigns.relay, cols, rows)
    end

    {:noreply, socket}
  end

  def handle_event("kill", _params, socket) do
    Hive.Container.kill(socket.assigns.container_id)
    {:noreply, push_navigate(socket, to: ~p"/dashboard")}
  end

  # -- Data loading ------------------------------------------------------------

  defp load_initial_state(container_id) do
    case Hive.Container.check(container_id) do
      {:ok, _status_string} -> {:running, []}
      {:error, :not_found} -> {:not_found, []}
    end
  end
end
