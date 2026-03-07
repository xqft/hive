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
    <div class="p-6">
      <div class="flex justify-between items-center mb-4">
        <div class="flex items-center gap-3">
          <h1 class="text-xl font-bold font-mono">{@container_id}</h1>
          <.container_status_badge status={@status} />
        </div>
        <div class="flex gap-2">
          <button
            :if={@status == :running}
            phx-click="kill"
            class="btn btn-error btn-sm"
            data-confirm="Kill this container?"
          >
            Kill
          </button>
          <.link navigate={~p"/dashboard"} class="btn btn-ghost btn-sm">Back</.link>
        </div>
      </div>

      <div
        class="mockup-code bg-base-300 overflow-y-auto max-h-[75vh]"
        id="output"
        phx-hook="ScrollBottom"
      >
        <pre :for={line <- @output}><code>{line}</code></pre>
        <pre :if={@output == []}><code class="text-base-content/50">Waiting for output...</code></pre>
      </div>
    </div>
    """
  end

  # -- Status badge component --------------------------------------------------

  defp container_status_badge(assigns) do
    ~H"""
    <span :if={@status == :running} class="badge badge-info badge-sm animate-pulse">running</span>
    <span :if={@status == :completed} class="badge badge-success badge-sm">completed</span>
    <span :if={@status == :failed} class="badge badge-error badge-sm">failed</span>
    <span :if={@status == :not_found} class="badge badge-ghost badge-sm">not found</span>
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
