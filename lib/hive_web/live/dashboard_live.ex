defmodule HiveWeb.DashboardLive do
  use HiveWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hive.PubSub, "agents")
      Phoenix.PubSub.subscribe(Hive.PubSub, "registry")
    end

    agents = load_agents()
    statuses = build_status_map(agents)

    {:ok,
     assign(socket,
       page_title: "Dashboard",
       agents: agents,
       statuses: statuses
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.app_shell
        current={:dashboard}
        title="Overview"
      >
        <div class="ui-stack">
          <div class="ui-section-row">
            <h1 class="ui-page-title">Overview</h1>
            <.button navigate={~p"/agents"}>New agent</.button>
          </div>
          <section class="ui-card-grid">
            <div class="ui-card ui-card--stat">
              <p class="ui-section-label">Agents</p>
              <p class="ui-metric">{length(@agents)}</p>
              <p class="ui-helper-text">Configured workers available in the workspace.</p>
            </div>
            <div class="ui-card ui-card--stat">
              <p class="ui-section-label">Thinking</p>
              <p class="ui-metric">
                {Enum.count(@statuses, fn {_name, status} -> status == :thinking end)}
              </p>
              <p class="ui-helper-text">Agents actively working right now.</p>
            </div>
          </section>

          <section class="ui-card ui-stack">
            <.header>
              Agents
              <:subtitle>Quick status scan with direct actions.</:subtitle>
            </.header>
            <div :if={@agents == []} class="ui-empty">No agents configured yet.</div>
            <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
              <div :for={agent <- @agents} class="ui-card ui-stack">
                <div class="ui-section-row">
                  <div>
                    <.link navigate={~p"/agent/#{agent.name}"} class="font-semibold text-[var(--ui-text-strong)] hover:text-[var(--ui-accent)]">{agent.name}</.link>
                    <p class="ui-helper-text line-clamp-2">{agent.description}</p>
                  </div>
                  <.status_badge status={Map.get(@statuses, agent.name, :unknown)} />
                </div>
                <div class="ui-section-row">
                  <.button navigate={~p"/agents"} variant="ghost" size="sm">Edit</.button>
                  <.button
                    variant="secondary"
                    size="sm"
                    phx-click="restart_agent"
                    phx-value-name={agent.name}
                    data-confirm={"Restart agent #{agent.name}?"}
                  >
                    Restart
                  </.button>
                </div>
              </div>
            </div>
          </section>
        </div>
      </.app_shell>
    </Layouts.app>
    """
  end

  # -- Status badge component --------------------------------------------------

  defp status_badge(assigns) do
    ~H"""
    <span :if={@status == :idle} class="ui-pill" style="color: var(--ui-success)">idle</span>
    <span :if={@status == :thinking} class="ui-pill" style="color: var(--ui-warning)">thinking</span>
    <span :if={@status == :unknown} class="ui-pill">offline</span>
    """
  end

  # -- PubSub handlers --------------------------------------------------------

  @impl true
  def handle_info({:status, name, status}, socket) do
    statuses = Map.put(socket.assigns.statuses, name, status)
    {:noreply, assign(socket, :statuses, statuses)}
  end

  def handle_info({:agent_created, _name}, socket) do
    agents = load_agents()
    statuses = build_status_map(agents)
    {:noreply, assign(socket, agents: agents, statuses: statuses)}
  end

  def handle_info({:agent_deleted, _name}, socket) do
    agents = load_agents()
    statuses = build_status_map(agents)
    {:noreply, assign(socket, agents: agents, statuses: statuses)}
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
end
