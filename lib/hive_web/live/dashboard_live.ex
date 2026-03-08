defmodule HiveWeb.DashboardLive do
  use HiveWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hive.PubSub, "agents")
      Phoenix.PubSub.subscribe(Hive.PubSub, "containers")
    end

    agents = load_agents()
    statuses = build_status_map(agents)
    containers = load_containers()

    {:ok,
     assign(socket,
       page_title: "Dashboard",
       agents: agents,
       statuses: statuses,
       containers: containers
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6">
      <div class="flex justify-between items-center mb-6">
        <h1 class="text-2xl font-bold">Dashboard</h1>
        <.link navigate={~p"/agents"} class="btn btn-primary btn-sm">+ New Agent</.link>
      </div>

      <h2 class="text-lg font-semibold mb-3">Agents</h2>
      <div :if={@agents == []} class="text-base-content/50 mb-8">No agents configured.</div>
      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4 mb-8">
        <div :for={agent <- @agents} class="card bg-base-200 shadow-sm">
          <div class="card-body p-4">
            <div class="flex items-center justify-between">
              <h3 class="card-title text-base">{agent.name}</h3>
              <.status_badge status={Map.get(@statuses, agent.name, :unknown)} />
            </div>
            <p class="text-sm text-base-content/70 line-clamp-2">{agent.description}</p>
            <div class="card-actions justify-end mt-2">
              <.link navigate={~p"/agents"} class="btn btn-ghost btn-xs">
                Edit
              </.link>
              <button
                phx-click="restart_agent"
                phx-value-name={agent.name}
                class="btn btn-outline btn-xs"
                data-confirm={"Restart agent #{agent.name}?"}
              >
                Restart
              </button>
            </div>
          </div>
        </div>
      </div>

      <h2 class="text-lg font-semibold mb-3">Active Containers</h2>
      <div :if={@containers == []} class="text-base-content/50">No active containers.</div>
      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <div :for={c <- @containers} class="card bg-base-200 shadow-sm">
          <div class="card-body p-4">
            <div class="flex items-center justify-between">
              <.link navigate={~p"/containers/#{c.id}"} class="font-mono text-sm link link-hover">
                {c.id}
              </.link>
              <span class="badge badge-neutral badge-sm">{c.agent}</span>
            </div>
            <p class="text-sm text-base-content/70 truncate">{c.task}</p>
            <div class="card-actions justify-end mt-2">
              <button
                phx-click="kill_container"
                phx-value-id={c.id}
                class="btn btn-error btn-xs"
                data-confirm={"Kill container #{c.id}?"}
              >
                Kill
              </button>
              <.link navigate={~p"/containers/#{c.id}"} class="btn btn-ghost btn-xs">
                View Output
              </.link>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # -- Status badge component --------------------------------------------------

  defp status_badge(assigns) do
    ~H"""
    <span :if={@status == :idle} class="badge badge-success badge-sm">idle</span>
    <span :if={@status == :thinking} class="badge badge-warning badge-sm animate-pulse">
      thinking
    </span>
    <span :if={@status == :unknown} class="badge badge-ghost badge-sm">offline</span>
    """
  end

  # -- PubSub handlers --------------------------------------------------------

  @impl true
  def handle_info({:status, name, status}, socket) do
    statuses = Map.put(socket.assigns.statuses, name, status)
    {:noreply, assign(socket, :statuses, statuses)}
  end

  def handle_info({:started, agent, id, task}, socket) do
    container = %{id: id, agent: agent, task: task}
    containers = socket.assigns.containers ++ [container]
    {:noreply, assign(socket, :containers, containers)}
  end

  def handle_info({:stopped, id, _reason}, socket) do
    containers = Enum.reject(socket.assigns.containers, &(&1.id == id))
    {:noreply, assign(socket, :containers, containers)}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # -- Events -----------------------------------------------------------------

  @impl true
  def handle_event("restart_agent", %{"name" => name}, socket) do
    # Find the agent's config before stopping
    agent = Enum.find(socket.assigns.agents, &(&1.name == name))

    try do
      Hive.Agent.stop(name)
    catch
      :exit, _ -> :ok
    end

    if agent do
      DynamicSupervisor.start_child(
        Hive.AgentSup,
        {Hive.Agent,
         name: agent.name, description: agent.description, personality: agent.personality}
      )
    end

    {:noreply, socket}
  end

  def handle_event("kill_container", %{"id" => id}, socket) do
    Hive.Container.kill(id)
    {:noreply, socket}
  end

  # -- Data loading ------------------------------------------------------------

  defp load_agents do
    case Hive.Persistence.get_agents() do
      {:ok, agents} -> agents
      _ -> []
    end
  end

  defp build_status_map(agents) do
    Map.new(agents, fn agent ->
      status =
        try do
          Hive.Agent.status(agent.name)
        catch
          :exit, _ -> :unknown
        end

      {agent.name, status}
    end)
  end

  defp load_containers do
    # Walk the ContainerRegistry to find all running containers
    Registry.select(Hive.ContainerRegistry, [
      {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$3"}}]}
    ])
    |> Enum.map(fn {id, agent_name} ->
      task =
        try do
          {:ok, status_string} = Hive.Container.check(id)
          # Extract just the task line from the status string
          status_string
          |> String.split("\n")
          |> Enum.find("", &String.starts_with?(&1, "Task: "))
          |> String.replace_prefix("Task: ", "")
        catch
          _, _ -> ""
        end

      %{id: id, agent: agent_name, task: task}
    end)
  end
end
