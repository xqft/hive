defmodule HiveWeb.AgentEditorLive do
  use HiveWeb, :live_view

  require Logger

  alias Hive.Persistence
  alias Hive.Validation

  @impl true
  def mount(_params, _session, socket) do
    agents = load_agents()
    mcp_servers = load_mcp_servers()

    socket =
      socket
      |> assign(:page_title, "Agents")
      |> assign(:agents, agents)
      |> assign(:mcp_servers, mcp_servers)
      |> assign_new_form()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6">
      <h1 class="text-2xl font-bold mb-6">Agents</h1>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <!-- Left: Agent list -->
        <div class="col-span-1">
          <button phx-click="new_agent" class="btn btn-primary btn-sm w-full mb-4">+ New Agent</button>

          <div :if={@agents == []} class="text-sm text-base-content/50 text-center py-4">
            No agents yet. Create one to get started.
          </div>

          <div
            :for={agent <- @agents}
            phx-click="select_agent"
            phx-value-name={agent.name}
            class={"card bg-base-100 shadow-sm mb-2 cursor-pointer hover:shadow-md transition-shadow #{if @selected_agent == agent.name, do: "ring-2 ring-primary"}"}
          >
            <div class="card-body p-3">
              <div class="flex items-center justify-between">
                <div class="font-semibold">{agent.name}</div>
                <div class={"w-2 h-2 rounded-full #{status_dot(agent.name)}"}></div>
              </div>
              <div class="text-xs text-base-content/50 line-clamp-2">{agent.description}</div>
            </div>
          </div>
        </div>

        <!-- Right: Editor form -->
        <div class="col-span-1 lg:col-span-2">
          <div class="card bg-base-100 shadow-sm">
            <div class="card-body">
              <h2 class="card-title text-lg mb-2">
                {if @editing_existing, do: "Edit Agent: #{@form_name}", else: "New Agent"}
              </h2>

              <form phx-submit="save_agent" phx-change="validate">
                <div class="form-control mb-4">
                  <label class="label">
                    <span class="label-text font-medium">Name</span>
                  </label>
                  <input
                    name="name"
                    value={@form_name}
                    class={"input input-bordered w-full #{if @name_error, do: "input-error"}"}
                    disabled={@editing_existing}
                    placeholder="e.g. researcher, coder-01"
                  />
                  <div :if={@name_error} class="text-error text-sm mt-1">{@name_error}</div>
                  <div :if={!@editing_existing && !@name_error} class="text-xs text-base-content/50 mt-1">
                    Alphanumeric, hyphens, underscores. 1-31 characters.
                  </div>
                </div>

                <div class="form-control mb-4">
                  <label class="label">
                    <span class="label-text font-medium">Description</span>
                  </label>
                  <input
                    name="description"
                    value={@form_description}
                    class="input input-bordered w-full"
                    placeholder="Brief description of the agent's role"
                  />
                </div>

                <div class="form-control mb-4">
                  <label class="label">
                    <span class="label-text font-medium">Personality / CLAUDE.md</span>
                  </label>
                  <textarea
                    name="personality"
                    class="textarea textarea-bordered w-full h-48 font-mono text-sm"
                    placeholder="Instructions, personality, objectives..."
                  >{@form_personality}</textarea>
                </div>

                <!-- MCP Server assignment -->
                <div class="form-control mb-4">
                  <label class="label">
                    <span class="label-text font-medium">MCP Servers</span>
                  </label>
                  <div :if={@mcp_servers == []} class="text-sm text-base-content/50">
                    No MCP servers installed. <a href="/mcp" class="link link-primary">Install one</a>.
                  </div>
                  <div :for={mcp <- @mcp_servers} class="rounded-lg border border-base-300 p-3 mb-2">
                    <label class="flex items-center gap-2 cursor-pointer">
                      <input
                        type="checkbox"
                        name="mcp_servers[]"
                        value={mcp.name}
                        checked={mcp.name in @assigned_mcps}
                        class="checkbox checkbox-sm checkbox-primary"
                      />
                      <span class="font-medium">{mcp.name}</span>
                      <span class="text-xs text-base-content/50">{mcp.description}</span>
                    </label>
                    <div :if={mcp.name in @assigned_mcps} class="mt-2 ml-7">
                      <label class="label">
                        <span class="label-text text-xs">Allowed tools (comma-separated, blank = all)</span>
                      </label>
                      <input
                        name={"mcp_tools[#{mcp.name}]"}
                        value={Map.get(@assigned_mcp_tools, mcp.name, "")}
                        class="input input-bordered input-sm w-full"
                        placeholder="tool1, tool2, ..."
                      />
                    </div>
                  </div>
                </div>

                <div class="flex gap-2 mt-6">
                  <button type="submit" class="btn btn-primary">
                    {if @editing_existing, do: "Update", else: "Create"}
                  </button>
                  <button :if={@editing_existing} type="button" phx-click="delete_agent" class="btn btn-error btn-outline" data-confirm="Are you sure you want to delete this agent?">
                    Delete
                  </button>
                  <button type="button" phx-click="new_agent" class="btn btn-ghost">
                    Cancel
                  </button>
                </div>
              </form>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("new_agent", _params, socket) do
    {:noreply, assign_new_form(socket)}
  end

  def handle_event("select_agent", %{"name" => name}, socket) do
    case Persistence.get_agent(name) do
      {:ok, nil} ->
        {:noreply, put_flash(socket, :error, "Agent not found")}

      {:ok, agent} ->
        {assigned_mcps, assigned_mcp_tools} = load_agent_mcp_assignments(name)

        socket =
          socket
          |> assign(:selected_agent, name)
          |> assign(:editing_existing, true)
          |> assign(:form_name, agent.name)
          |> assign(:form_description, agent.description || "")
          |> assign(:form_personality, agent.personality || "")
          |> assign(:assigned_mcps, assigned_mcps)
          |> assign(:assigned_mcp_tools, assigned_mcp_tools)
          |> assign(:name_error, nil)

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to load agent")}
    end
  end

  def handle_event("validate", %{"name" => name} = params, socket) do
    name_error =
      if socket.assigns.editing_existing do
        nil
      else
        validate_name_field(name, socket.assigns.agents)
      end

    # Track checkbox state for MCP servers during validation
    checked_mcps = Map.get(params, "mcp_servers", [])
    mcp_tools = Map.get(params, "mcp_tools", %{})

    socket =
      socket
      |> assign(:name_error, name_error)
      |> assign(:form_name, name)
      |> assign(:form_description, Map.get(params, "description", ""))
      |> assign(:form_personality, Map.get(params, "personality", ""))
      |> assign(:assigned_mcps, MapSet.new(checked_mcps))
      |> assign(:assigned_mcp_tools, mcp_tools)

    {:noreply, socket}
  end

  def handle_event("save_agent", params, socket) do
    name = String.trim(params["name"] || "")
    description = String.trim(params["description"] || "")
    personality = String.trim(params["personality"] || "")
    checked_mcps = Map.get(params, "mcp_servers", [])
    mcp_tools = Map.get(params, "mcp_tools", %{})

    if socket.assigns.editing_existing do
      handle_update_agent(socket, name, description, personality, checked_mcps, mcp_tools)
    else
      handle_create_agent(socket, name, description, personality, checked_mcps, mcp_tools)
    end
  end

  def handle_event("delete_agent", _params, socket) do
    name = socket.assigns.selected_agent

    # Stop the running GenServer
    stop_agent_process(name)

    case Persistence.delete_agent(name) do
      :ok ->
        agents = load_agents()

        socket =
          socket
          |> assign(:agents, agents)
          |> assign_new_form()
          |> put_flash(:info, "Agent \"#{name}\" deleted")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete agent: #{inspect(reason)}")}
    end
  end

  # ---------------------------------------------------------------------------
  # Create / Update helpers
  # ---------------------------------------------------------------------------

  defp handle_create_agent(socket, name, description, personality, checked_mcps, mcp_tools) do
    name_error = validate_name_field(name, socket.assigns.agents)

    if name_error do
      {:noreply, assign(socket, :name_error, name_error)}
    else
      case Persistence.create_agent(name, description, personality) do
        :ok ->
          # Start the agent GenServer
          start_agent_process(name, description, personality)

          # Handle MCP assignments
          sync_mcp_assignments(name, MapSet.new(), checked_mcps, mcp_tools)

          agents = load_agents()

          socket =
            socket
            |> assign(:agents, agents)
            |> assign_new_form()
            |> put_flash(:info, "Agent \"#{name}\" created")

          {:noreply, socket}

        {:error, :name_taken} ->
          {:noreply, assign(socket, :name_error, "Name is already taken")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to create agent: #{inspect(reason)}")}
      end
    end
  end

  defp handle_update_agent(socket, name, description, personality, checked_mcps, mcp_tools) do
    old_personality = socket.assigns.form_personality

    attrs =
      %{}
      |> Map.put(:description, description)
      |> Map.put(:personality, personality)

    case Persistence.update_agent(name, attrs) do
      :ok ->
        # Sync MCP assignments
        {old_mcps, _old_tools} = load_agent_mcp_assignments(name)
        sync_mcp_assignments(name, old_mcps, checked_mcps, mcp_tools)

        # If personality changed, restart the agent to pick up new CLAUDE.md
        if personality != old_personality do
          restart_agent_process(name, description, personality)
        end

        agents = load_agents()
        {assigned_mcps, assigned_mcp_tools} = load_agent_mcp_assignments(name)

        socket =
          socket
          |> assign(:agents, agents)
          |> assign(:form_description, description)
          |> assign(:form_personality, personality)
          |> assign(:assigned_mcps, assigned_mcps)
          |> assign(:assigned_mcp_tools, assigned_mcp_tools)
          |> put_flash(:info, "Agent \"#{name}\" updated")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update agent: #{inspect(reason)}")}
    end
  end

  # ---------------------------------------------------------------------------
  # MCP assignment sync
  # ---------------------------------------------------------------------------

  defp sync_mcp_assignments(agent_name, old_mcps, new_mcp_list, mcp_tools) do
    new_mcps = MapSet.new(new_mcp_list)

    # Unassign removed
    old_mcps
    |> MapSet.difference(new_mcps)
    |> Enum.each(fn mcp_name ->
      Persistence.unassign_mcp_server(agent_name, mcp_name)
    end)

    # Assign new or update existing (allowed_tools might have changed)
    Enum.each(new_mcp_list, fn mcp_name ->
      tools_str = Map.get(mcp_tools, mcp_name, "")

      allowed_tools =
        tools_str
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      Persistence.assign_mcp_server(agent_name, mcp_name, allowed_tools)
    end)
  end

  # ---------------------------------------------------------------------------
  # Agent process management
  # ---------------------------------------------------------------------------

  defp start_agent_process(name, description, personality) do
    case DynamicSupervisor.start_child(
           Hive.AgentSup,
           {Hive.Agent, name: name, description: description, personality: personality}
         ) do
      {:ok, _pid} -> :ok
      {:error, reason} -> Logger.error("Failed to start agent #{name}: #{inspect(reason)}")
    end
  end

  defp stop_agent_process(name) do
    try do
      Hive.Agent.stop(name)
    catch
      :exit, _ -> :ok
    end
  end

  defp restart_agent_process(name, description, personality) do
    stop_agent_process(name)
    start_agent_process(name, description, personality)
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp validate_name_field("", _agents), do: nil

  defp validate_name_field(name, agents) do
    case Validation.validate_name(name) do
      {:error, :invalid_name} ->
        "Invalid name. Use alphanumeric characters, hyphens, and underscores (1-31 chars)"

      :ok ->
        if Enum.any?(agents, fn a -> a.name == name end) do
          "Name is already taken"
        else
          nil
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Data loading
  # ---------------------------------------------------------------------------

  defp load_agents do
    case Persistence.get_agents() do
      {:ok, agents} -> agents
      _ -> []
    end
  end

  defp load_mcp_servers do
    case Persistence.get_mcp_servers() do
      {:ok, servers} -> servers
      _ -> []
    end
  end

  defp load_agent_mcp_assignments(agent_name) do
    case Persistence.get_agent_mcp_servers(agent_name) do
      {:ok, assignments} ->
        mcps = MapSet.new(assignments, fn a -> a.name end)

        tools =
          Map.new(assignments, fn a ->
            allowed = parse_json_field(a.allowed_tools, [])
            {a.name, Enum.join(allowed, ", ")}
          end)

        {mcps, tools}

      _ ->
        {MapSet.new(), %{}}
    end
  end

  defp parse_json_field(nil, default), do: default

  defp parse_json_field(value, default) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, parsed} -> parsed
      _ -> default
    end
  end

  defp parse_json_field(value, _default), do: value

  # ---------------------------------------------------------------------------
  # Assign helpers
  # ---------------------------------------------------------------------------

  defp assign_new_form(socket) do
    socket
    |> assign(:selected_agent, nil)
    |> assign(:editing_existing, false)
    |> assign(:form_name, "")
    |> assign(:form_description, "")
    |> assign(:form_personality, "")
    |> assign(:assigned_mcps, MapSet.new())
    |> assign(:assigned_mcp_tools, %{})
    |> assign(:name_error, nil)
  end

  defp status_dot(agent_name) do
    try do
      case Hive.Agent.status(agent_name) do
        :idle -> "bg-success"
        :thinking -> "bg-warning animate-pulse"
        _ -> "bg-base-content/30"
      end
    catch
      _, _ -> "bg-base-content/30"
    end
  end
end
