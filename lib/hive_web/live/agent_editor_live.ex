defmodule HiveWeb.AgentEditorLive do
  use HiveWeb, :live_view

  require Logger

  alias Hive.Persistence
  alias Hive.Validation

  @impl true
  def mount(_params, _session, socket) do
    agents = load_agents()

    socket =
      socket
      |> assign(:page_title, "Agents")
      |> assign(:agents, agents)
      |> assign_new_form()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.app_shell
        current={:agents}
        title="Agents"
      >
        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <!-- Left: Agent list -->
          <div class={["col-span-1 ui-card", @mobile_view == :editor && "ui-mobile-hidden"]}>
            <.button phx-click="new_agent" class="w-full mb-4">New agent</.button>

            <div :if={@agents == []} class="ui-empty">
              No agents yet. Create one to get started.
            </div>

            <div
              :for={agent <- @agents}
              phx-click="select_agent"
              phx-value-name={agent.name}
              class={[
                "ui-card mb-2 cursor-pointer",
                @selected_agent == agent.name && "ring-2 ring-[var(--ui-accent)]"
              ]}
            >
              <div class="flex items-center justify-between">
                <div class="font-semibold">{agent.name}</div>
                <div class={"w-2 h-2 rounded-full #{status_dot(agent.name)}"}></div>
              </div>
              <div class="text-xs text-base-content/50 line-clamp-2">{agent.description}</div>
            </div>
          </div>
          
    <!-- Right: Editor form -->
          <div class={["col-span-1 lg:col-span-2", @mobile_view == :list && "ui-mobile-hidden"]}>
            <div class="ui-card">
              <button
                type="button"
                phx-click="mobile_back"
                class="ui-mobile-back-btn"
              >
                <.icon name="hero-arrow-left" class="size-4" /> Back
              </button>
              <h2 class="text-lg font-semibold mb-4 text-[var(--ui-text-strong)]">
                {if @editing_existing, do: "Edit Agent: #{@form_name}", else: "New Agent"}
              </h2>

              <form phx-submit="save_agent" phx-change="validate">
                <div class="form-control mb-4">
                  <label class="mb-2 block text-sm font-medium text-[var(--ui-text-strong)]">
                    Name
                  </label>
                  <input
                    name="name"
                    value={@form_name}
                    class={["ui-input w-full", @name_error && "ui-input--error"]}
                    disabled={@editing_existing}
                    placeholder="e.g. researcher, coder-01"
                  />
                  <div :if={@name_error} class="text-error text-sm mt-1">{@name_error}</div>
                  <div
                    :if={!@editing_existing && !@name_error}
                    class="text-xs text-base-content/50 mt-1"
                  >
                    Alphanumeric, hyphens, underscores. 1-31 characters.
                  </div>
                </div>

                <div class="form-control mb-4">
                  <label class="mb-2 block text-sm font-medium text-[var(--ui-text-strong)]">
                    Description
                  </label>
                  <input
                    name="description"
                    value={@form_description}
                    class="ui-input w-full"
                    placeholder="Brief description of the agent's role"
                  />
                </div>

                <div class="form-control mb-4">
                  <div class="mb-2 flex items-center justify-between gap-3">
                    <label class="text-sm font-medium text-[var(--ui-text-strong)]">
                      Personality / CLAUDE.md
                    </label>
                    <.button
                      type="button"
                      phx-click="generate_personality"
                      variant="secondary"
                      size="sm"
                      disabled={@generating}
                    >
                      <span :if={@generating} class="loading loading-spinner loading-xs"></span>
                      {if @generating, do: "Generating...", else: "Generate with AI"}
                    </.button>
                  </div>
                  <textarea
                    name="personality"
                    class="ui-textarea w-full h-48 font-mono text-sm"
                    placeholder="Instructions, personality, objectives..."
                  >{@form_personality}</textarea>
                </div>
                <div class="flex gap-2 mt-6">
                  <.button type="submit">
                    {if @editing_existing, do: "Update", else: "Create"}
                  </.button>
                  <.button
                    :if={@editing_existing}
                    type="button"
                    phx-click="delete_agent"
                    variant="danger"
                    data-confirm="Are you sure you want to delete this agent?"
                  >
                    Delete
                  </.button>
                  <.button type="button" phx-click="new_agent" variant="ghost">
                    Cancel
                  </.button>
                </div>
              </form>
            </div>
          </div>
        </div>
      </.app_shell>
    </Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("new_agent", _params, socket) do
    {:noreply, socket |> assign_new_form() |> assign(:mobile_view, :editor)}
  end

  def handle_event("mobile_back", _params, socket) do
    {:noreply, assign(socket, :mobile_view, :list)}
  end

  def handle_event("select_agent", %{"name" => name}, socket) do
    case Persistence.get_agent(name) do
      {:ok, nil} ->
        {:noreply, put_flash(socket, :error, "Agent not found")}

      {:ok, agent} ->
        socket =
          socket
          |> assign(:selected_agent, name)
          |> assign(:editing_existing, true)
          |> assign(:form_name, agent.name)
          |> assign(:form_description, agent.description || "")
          |> assign(:form_personality, agent.personality || "")
          |> assign(:name_error, nil)
          |> assign(:mobile_view, :editor)

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

    socket =
      socket
      |> assign(:name_error, name_error)
      |> assign(:form_name, name)
      |> assign(:form_description, Map.get(params, "description", ""))
      |> assign(:form_personality, Map.get(params, "personality", ""))

    {:noreply, socket}
  end

  def handle_event("save_agent", params, socket) do
    name = String.trim(params["name"] || "")
    description = String.trim(params["description"] || "")
    personality = String.trim(params["personality"] || "")

    if socket.assigns.editing_existing do
      handle_update_agent(socket, name, description, personality)
    else
      handle_create_agent(socket, name, description, personality)
    end
  end

  def handle_event("generate_personality", _params, socket) do
    name = String.trim(socket.assigns.form_name || "")
    description = String.trim(socket.assigns.form_description || "")

    Logger.debug("generate_personality: name=#{inspect(name)} desc=#{inspect(description)}")

    if name == "" and description == "" do
      {:noreply, put_flash(socket, :error, "Enter a name or description first")}
    else
      task =
        Task.async(fn ->
          generate_personality(name, description)
        end)

      {:noreply, assign(socket, generating: true, generate_task: task)}
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
  # Async task result
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({ref, result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    Logger.debug("generate task result: #{inspect(result, limit: 200)}")

    socket =
      socket
      |> assign(:generating, false)
      |> assign(:generate_task, nil)

    case result do
      {:ok, personality} ->
        {:noreply, assign(socket, :form_personality, personality)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Generation failed: #{reason}")}
    end
  end

  def handle_info(msg, socket) do
    Logger.debug("unhandled info: #{inspect(msg, limit: 200)}")
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Create / Update helpers
  # ---------------------------------------------------------------------------

  defp handle_create_agent(socket, name, description, personality) do
    name_error = validate_name_field(name, socket.assigns.agents)

    if name_error do
      {:noreply, assign(socket, :name_error, name_error)}
    else
      case Persistence.create_agent(name, description, personality) do
        :ok ->
          # Start the agent GenServer
          start_agent_process(name, description, personality)

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

  defp handle_update_agent(socket, name, description, personality) do
    old_personality = socket.assigns.form_personality

    attrs =
      %{}
      |> Map.put(:description, description)
      |> Map.put(:personality, personality)

    case Persistence.update_agent(name, attrs) do
      :ok ->
        # If personality changed, restart the agent to pick up new CLAUDE.md
        if personality != old_personality do
          restart_agent_process(name, description, personality)
        end

        agents = load_agents()

        socket =
          socket
          |> assign(:agents, agents)
          |> assign(:form_description, description)
          |> assign(:form_personality, personality)
          |> put_flash(:info, "Agent \"#{name}\" updated")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update agent: #{inspect(reason)}")}
    end
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

  # ---------------------------------------------------------------------------
  # AI personality generation
  # ---------------------------------------------------------------------------

  defp generate_personality(name, description) do
    prompt = """
    Generate a CLAUDE.md personality file for a Hive agent with the following details:

    Name: #{name}
    Description: #{description}

    The agent operates in a multi-agent orchestration system called Hive where agents communicate via topics and DMs, and run inside persistent Docker containers with full shell access.

    Write a concise, focused personality that includes:
    - The agent's role and expertise
    - How it should behave and communicate
    - Any specific guidelines or constraints

    Output ONLY the markdown content for the CLAUDE.md file, nothing else.
    """

    # Pass prompt via env var to avoid shell escaping issues.
    # Redirect stdin from /dev/null so claude doesn't hang waiting for input.
    case System.cmd("bash", ["-c", ~s(claude -p "$HIVE_PROMPT" --output-format text < /dev/null)],
           stderr_to_stdout: true,
           env:
             [
               {"HIVE_PROMPT", prompt},
               {"CLAUDECODE", nil}
             ] ++ oauth_env()
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, "claude exited #{code}: #{String.slice(output, 0, 200)}"}
    end
  end

  defp oauth_env do
    case Application.get_env(:hive, :claude_oauth_token) do
      token when is_binary(token) and token != "" -> [{"CLAUDE_CODE_OAUTH_TOKEN", token}]
      _ -> []
    end
  end

  defp assign_new_form(socket) do
    socket
    |> assign(:selected_agent, nil)
    |> assign(:editing_existing, false)
    |> assign(:form_name, "")
    |> assign(:form_description, "")
    |> assign(:form_personality, "")
    |> assign(:name_error, nil)
    |> assign(:generating, false)
    |> assign(:generate_task, nil)
    |> assign(:mobile_view, :list)
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
