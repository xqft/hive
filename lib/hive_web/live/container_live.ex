defmodule HiveWeb.ContainerLive do
  use HiveWeb, :live_view

  @impl true
  def mount(%{"id" => container_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hive.PubSub, "container:#{container_id}")
    end

    {status, initial_output} = load_initial_state(container_id)

    {:ok,
     assign(socket,
       page_title: container_id,
       container_id: container_id,
       status: status,
       output: initial_output
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.app_shell
        current={:dashboard}
        title="Container"
        subtitle="Live runtime output with a quieter, terminal-forward presentation."
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

          <div class="ui-code-terminal" id="output" phx-hook="ScrollBottom">
            <pre :for={line <- @output}><code>{line}</code></pre>
            <pre :if={@output == []}><code class="text-slate-400">Waiting for output...</code></pre>
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

  # -- PubSub handlers --------------------------------------------------------

  @impl true
  def handle_info({:output, data}, socket) do
    new_lines = String.split(data, "\n", trim: true)
    output = socket.assigns.output ++ new_lines
    {:noreply, assign(socket, :output, output)}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # -- Events -----------------------------------------------------------------

  @impl true
  def handle_event("kill", _params, socket) do
    Hive.Container.kill(socket.assigns.container_id)
    {:noreply, push_navigate(socket, to: ~p"/dashboard")}
  end

  # -- Data loading ------------------------------------------------------------

  defp load_initial_state(container_id) do
    case Hive.Container.check(container_id) do
      {:ok, status_string} ->
        lines = String.split(status_string, "\n", trim: true)
        {:running, lines}

      {:error, :not_found} ->
        {:not_found, []}
    end
  end
end
