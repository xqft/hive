defmodule HiveWeb.McpServersLive do
  use HiveWeb, :live_view

  require Logger

  alias Hive.Persistence

  @impl true
  def mount(_params, _session, socket) do
    mcp_servers = load_mcp_servers()

    socket =
      socket
      |> assign(:page_title, "MCP Servers")
      |> assign(:mcp_servers, mcp_servers)
      |> assign_new_form()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.app_shell
        current={:mcp}
        title="MCP Servers"
      >
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <!-- Left: Server list -->
          <div class={["ui-card", @mobile_view == :editor && "ui-mobile-hidden"]}>
            <.button phx-click="new_server" class="w-full mb-4">Install MCP server</.button>

            <div :if={@mcp_servers == []} class="ui-empty">
              No MCP servers installed yet.
            </div>

            <div
              :for={server <- @mcp_servers}
              phx-click="select_server"
              phx-value-name={server.name}
              class={[
                "ui-card mb-2 cursor-pointer",
                @selected_server == server.name && "ring-2 ring-[var(--ui-accent)]"
              ]}
            >
              <div class="font-semibold">{server.name}</div>
              <div :if={server.description} class="text-xs text-base-content/50 line-clamp-2">
                {server.description}
              </div>
              <div class="text-xs font-mono text-base-content/40 mt-1">
                {server.command} {format_args_preview(server.args)}
              </div>
              <div :if={assigned_agents(server.name) != []} class="flex flex-wrap gap-1 mt-1">
                <span
                  :for={agent <- assigned_agents(server.name)}
                  class="badge badge-sm badge-outline"
                >
                  {agent}
                </span>
              </div>
            </div>
          </div>
          
    <!-- Right: Editor form -->
          <div class={[@mobile_view == :list && "ui-mobile-hidden"]}>
            <div class="ui-card">
              <button
                type="button"
                phx-click="mobile_back"
                class="ui-mobile-back-btn"
              >
                <.icon name="hero-arrow-left" class="size-4" /> Back
              </button>
              <h2 class="text-lg font-semibold mb-4 text-[var(--ui-text-strong)]">
                {if @editing_existing, do: "Edit: #{@form_name}", else: "Install MCP Server"}
              </h2>

              <form phx-submit="save_server" phx-change="validate">
                <div class="form-control mb-4">
                  <label class="mb-2 block text-sm font-medium text-[var(--ui-text-strong)]">
                    Name
                  </label>
                  <input
                    name="name"
                    value={@form_name}
                    class={["ui-input w-full", @name_error && "ui-input--error"]}
                    disabled={@editing_existing}
                    placeholder="e.g. obsidian-mcp, github-mcp"
                  />
                  <div :if={@name_error} class="text-error text-sm mt-1">{@name_error}</div>
                </div>

                <div class="form-control mb-4">
                  <label class="mb-2 block text-sm font-medium text-[var(--ui-text-strong)]">
                    Description
                  </label>
                  <input
                    name="description"
                    value={@form_description}
                    class="ui-input w-full"
                    placeholder="What this MCP server provides"
                  />
                </div>

                <div class="form-control mb-4">
                  <label class="mb-2 block text-sm font-medium text-[var(--ui-text-strong)]">
                    Command
                  </label>
                  <input
                    name="command"
                    value={@form_command}
                    class={["ui-input w-full font-mono", @command_error && "ui-input--error"]}
                    placeholder="e.g. npx, node, python"
                  />
                  <div :if={@command_error} class="text-error text-sm mt-1">{@command_error}</div>
                </div>

                <div class="form-control mb-4">
                  <label class="mb-2 block text-sm font-medium text-[var(--ui-text-strong)]">
                    Args
                  </label>
                  <input
                    name="args"
                    value={@form_args}
                    class={["ui-input w-full font-mono", @args_error && "ui-input--error"]}
                    placeholder={~s(e.g. ["-y", "mcp-obsidian", "/path"])}
                  />
                  <div :if={@args_error} class="text-error text-sm mt-1">{@args_error}</div>
                  <div :if={!@args_error} class="text-xs text-base-content/50 mt-1">
                    JSON array of strings
                  </div>
                </div>

                <div class="form-control mb-4">
                  <label class="mb-2 block text-sm font-medium text-[var(--ui-text-strong)]">
                    Environment Variables
                  </label>
                  <input
                    name="env"
                    value={@form_env}
                    class={["ui-input w-full font-mono", @env_error && "ui-input--error"]}
                    placeholder={~s(e.g. {"API_KEY": "sk-..."})}
                  />
                  <div :if={@env_error} class="text-error text-sm mt-1">{@env_error}</div>
                  <div :if={!@env_error} class="text-xs text-base-content/50 mt-1">
                    JSON object (optional)
                  </div>
                </div>

                <div class="flex gap-2 mt-6">
                  <.button type="submit">
                    {if @editing_existing, do: "Update", else: "Install"}
                  </.button>
                  <.button
                    :if={@editing_existing}
                    type="button"
                    phx-click="delete_server"
                    variant="danger"
                    data-confirm={delete_confirm_message(@selected_server)}
                  >
                    Delete
                  </.button>
                  <.button type="button" phx-click="new_server" variant="ghost">
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
  def handle_event("new_server", _params, socket) do
    {:noreply, socket |> assign_new_form() |> assign(:mobile_view, :editor)}
  end

  def handle_event("mobile_back", _params, socket) do
    {:noreply, assign(socket, :mobile_view, :list)}
  end

  def handle_event("select_server", %{"name" => name}, socket) do
    server = Enum.find(socket.assigns.mcp_servers, fn s -> s.name == name end)

    if server do
      args_str = format_json_field(server.args, "[]")
      env_str = format_json_field(server.env, "{}")

      socket =
        socket
        |> assign(:selected_server, name)
        |> assign(:editing_existing, true)
        |> assign(:form_name, server.name)
        |> assign(:form_description, server.description || "")
        |> assign(:form_command, server.command || "")
        |> assign(:form_args, args_str)
        |> assign(:form_env, env_str)
        |> assign(:name_error, nil)
        |> assign(:command_error, nil)
        |> assign(:args_error, nil)
        |> assign(:env_error, nil)
        |> assign(:mobile_view, :editor)

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, "MCP server not found")}
    end
  end

  def handle_event("validate", params, socket) do
    name = Map.get(params, "name", "")
    command = Map.get(params, "command", "")
    args = Map.get(params, "args", "[]")
    env = Map.get(params, "env", "{}")

    name_error =
      if socket.assigns.editing_existing do
        nil
      else
        validate_server_name(name, socket.assigns.mcp_servers)
      end

    args_error = validate_json_array(args)
    env_error = validate_json_object(env)

    socket =
      socket
      |> assign(:form_name, name)
      |> assign(:form_description, Map.get(params, "description", ""))
      |> assign(:form_command, command)
      |> assign(:form_args, args)
      |> assign(:form_env, env)
      |> assign(:name_error, name_error)
      |> assign(:command_error, nil)
      |> assign(:args_error, args_error)
      |> assign(:env_error, env_error)

    {:noreply, socket}
  end

  def handle_event("save_server", params, socket) do
    name = String.trim(params["name"] || "")
    description = String.trim(params["description"] || "")
    command = String.trim(params["command"] || "")
    args_str = String.trim(params["args"] || "[]")
    env_str = String.trim(params["env"] || "{}")

    # Validate
    command_error = if command == "", do: "Command is required", else: nil
    args_error = validate_json_array(args_str)
    env_error = validate_json_object(env_str)

    name_error =
      if socket.assigns.editing_existing do
        nil
      else
        validate_server_name(name, socket.assigns.mcp_servers)
      end

    has_errors = name_error || command_error || args_error || env_error

    if has_errors do
      socket =
        socket
        |> assign(:name_error, name_error)
        |> assign(:command_error, command_error)
        |> assign(:args_error, args_error)
        |> assign(:env_error, env_error)

      {:noreply, socket}
    else
      args = Jason.decode!(args_str)
      env = if env_str == "" || env_str == "{}", do: %{}, else: Jason.decode!(env_str)

      if socket.assigns.editing_existing do
        handle_update_server(socket, name, description, command, args, env)
      else
        handle_create_server(socket, name, description, command, args, env)
      end
    end
  end

  def handle_event("delete_server", _params, socket) do
    name = socket.assigns.selected_server

    case Persistence.delete_mcp_server(name) do
      :ok ->
        mcp_servers = load_mcp_servers()

        socket =
          socket
          |> assign(:mcp_servers, mcp_servers)
          |> assign_new_form()
          |> put_flash(:info, "MCP server \"#{name}\" deleted")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete MCP server: #{inspect(reason)}")}
    end
  end

  # ---------------------------------------------------------------------------
  # Create / Update helpers
  # ---------------------------------------------------------------------------

  defp handle_create_server(socket, name, description, command, args, env) do
    case Persistence.create_mcp_server(name, description, command, args, env) do
      :ok ->
        mcp_servers = load_mcp_servers()

        socket =
          socket
          |> assign(:mcp_servers, mcp_servers)
          |> assign_new_form()
          |> put_flash(:info, "MCP server \"#{name}\" installed")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create MCP server: #{inspect(reason)}")}
    end
  end

  defp handle_update_server(socket, name, description, command, args, env) do
    attrs = %{
      description: description,
      command: command,
      args: args,
      env: env
    }

    case Persistence.update_mcp_server(name, attrs) do
      :ok ->
        mcp_servers = load_mcp_servers()

        socket =
          socket
          |> assign(:mcp_servers, mcp_servers)
          |> put_flash(:info, "MCP server \"#{name}\" updated")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update MCP server: #{inspect(reason)}")}
    end
  end

  # ---------------------------------------------------------------------------
  # Validation helpers
  # ---------------------------------------------------------------------------

  defp validate_server_name("", _servers), do: nil

  defp validate_server_name(name, servers) do
    cond do
      not Regex.match?(~r/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,30}$/, name) ->
        "Invalid name. Use alphanumeric characters, hyphens, and underscores (1-31 chars)"

      Enum.any?(servers, fn s -> s.name == name end) ->
        "Name is already taken"

      true ->
        nil
    end
  end

  defp validate_json_array(""), do: nil
  defp validate_json_array("[]"), do: nil

  defp validate_json_array(str) do
    case Jason.decode(str) do
      {:ok, list} when is_list(list) -> nil
      {:ok, _} -> "Must be a JSON array"
      {:error, _} -> "Invalid JSON"
    end
  end

  defp validate_json_object(""), do: nil
  defp validate_json_object("{}"), do: nil

  defp validate_json_object(str) do
    case Jason.decode(str) do
      {:ok, map} when is_map(map) -> nil
      {:ok, _} -> "Must be a JSON object"
      {:error, _} -> "Invalid JSON"
    end
  end

  # ---------------------------------------------------------------------------
  # Data loading
  # ---------------------------------------------------------------------------

  defp load_mcp_servers do
    case Persistence.get_mcp_servers() do
      {:ok, servers} -> servers
      _ -> []
    end
  end

  defp assigned_agents(mcp_server_name) do
    # Query all agents and check their MCP assignments
    case Persistence.get_agents() do
      {:ok, agents} ->
        Enum.filter(agents, fn agent ->
          case Persistence.get_agent_mcp_servers(agent.name) do
            {:ok, assignments} ->
              Enum.any?(assignments, fn a -> a.name == mcp_server_name end)

            _ ->
              false
          end
        end)
        |> Enum.map(& &1.name)

      _ ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # Formatting helpers
  # ---------------------------------------------------------------------------

  defp format_json_field(nil, default), do: default

  defp format_json_field(value, default) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, parsed} -> Jason.encode!(parsed, pretty: true)
      _ -> default
    end
  end

  defp format_json_field(value, _default) when is_list(value) or is_map(value) do
    Jason.encode!(value, pretty: true)
  end

  defp format_json_field(_, default), do: default

  defp format_args_preview(nil), do: ""

  defp format_args_preview(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, list} when is_list(list) -> Enum.join(list, " ")
      _ -> args
    end
  end

  defp format_args_preview(args) when is_list(args), do: Enum.join(args, " ")
  defp format_args_preview(_), do: ""

  defp delete_confirm_message(server_name) do
    agents = assigned_agents(server_name)

    if agents == [] do
      "Are you sure you want to delete this MCP server?"
    else
      "This MCP server is assigned to: #{Enum.join(agents, ", ")}. Are you sure you want to delete it?"
    end
  end

  # ---------------------------------------------------------------------------
  # Assign helpers
  # ---------------------------------------------------------------------------

  defp assign_new_form(socket) do
    socket
    |> assign(:selected_server, nil)
    |> assign(:editing_existing, false)
    |> assign(:form_name, "")
    |> assign(:form_description, "")
    |> assign(:form_command, "")
    |> assign(:form_args, "[]")
    |> assign(:form_env, "{}")
    |> assign(:name_error, nil)
    |> assign(:command_error, nil)
    |> assign(:args_error, nil)
    |> assign(:env_error, nil)
    |> assign(:mobile_view, :list)
  end
end
