defmodule HiveWeb.ConnectorsLive do
  use HiveWeb, :live_view

  require Logger

  alias Hive.Persistence
  alias Hive.Connector.Templates

  @impl true
  def mount(_params, _session, socket) do
    mcp_servers = load_mcp_servers()
    event_sources = load_event_sources()
    templates = Templates.list()

    socket =
      socket
      |> assign(:page_title, "Connectors")
      |> assign(:mcp_servers, mcp_servers)
      |> assign(:event_sources, event_sources)
      |> assign(:templates, templates)
      |> assign(:panel, :catalog)
      |> assign_new_mcp_form()
      |> assign_new_event_form()
      |> assign(:selected_item, nil)
      |> assign(:selected_type, nil)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.app_shell current={:connectors} title="Connectors">
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <!-- Left column: lists -->
          <div class="space-y-4">
            <!-- Connectors (MCP + linked event) -->
            <div class="ui-card">
              <h3 class="text-sm font-semibold text-[var(--ui-text-strong)] mb-3">Connectors</h3>
              <% connectors = linked_connectors(@mcp_servers, @event_sources) %>
              <div :if={connectors == []} class="ui-empty text-sm">
                No connectors yet. Use a template to create one.
              </div>
              <div
                :for={{mcp, event} <- connectors}
                phx-click="select_item"
                phx-value-type="connector"
                phx-value-name={mcp.name}
                class={[
                  "ui-card mb-2 cursor-pointer",
                  @selected_item == mcp.name && @selected_type == "connector" &&
                    "ring-2 ring-[var(--ui-accent)]"
                ]}
              >
                <div class="font-semibold">{mcp.name}</div>
                <div :if={mcp.description} class="text-xs text-base-content/50 line-clamp-1">
                  {mcp.description}
                </div>
                <div class="flex flex-wrap gap-1 mt-1">
                  <span class="badge badge-sm badge-outline">{event.type}</span>
                  <span class="badge badge-sm badge-outline">#{event.topic}</span>
                  <span class={[
                    "badge badge-sm",
                    if(event.enabled == 1, do: "badge-success", else: "badge-ghost")
                  ]}>
                    {if event.enabled == 1, do: "enabled", else: "disabled"}
                  </span>
                </div>
              </div>
            </div>

            <!-- Standalone MCP Servers -->
            <div class="ui-card">
              <div class="flex items-center justify-between mb-3">
                <h3 class="text-sm font-semibold text-[var(--ui-text-strong)]">MCP Servers</h3>
                <.button phx-click="new_mcp" size="sm">Add</.button>
              </div>
              <% standalone_mcps = standalone_mcp_servers(@mcp_servers, @event_sources) %>
              <div :if={standalone_mcps == []} class="ui-empty text-sm">
                No standalone MCP servers.
              </div>
              <div
                :for={server <- standalone_mcps}
                phx-click="select_item"
                phx-value-type="mcp"
                phx-value-name={server.name}
                class={[
                  "ui-card mb-2 cursor-pointer",
                  @selected_item == server.name && @selected_type == "mcp" &&
                    "ring-2 ring-[var(--ui-accent)]"
                ]}
              >
                <div class="font-semibold">{server.name}</div>
                <div :if={server.description} class="text-xs text-base-content/50 line-clamp-1">
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

            <!-- Standalone Event Sources -->
            <div class="ui-card">
              <div class="flex items-center justify-between mb-3">
                <h3 class="text-sm font-semibold text-[var(--ui-text-strong)]">Event Sources</h3>
                <.button phx-click="new_event" size="sm">Add</.button>
              </div>
              <% standalone_events = standalone_event_sources(@mcp_servers, @event_sources) %>
              <div :if={standalone_events == []} class="ui-empty text-sm">
                No standalone event sources.
              </div>
              <div
                :for={event <- standalone_events}
                phx-click="select_item"
                phx-value-type="event"
                phx-value-name={event.name}
                class={[
                  "ui-card mb-2 cursor-pointer",
                  @selected_item == event.name && @selected_type == "event" &&
                    "ring-2 ring-[var(--ui-accent)]"
                ]}
              >
                <div class="flex items-center justify-between">
                  <div class="font-semibold">{event.name}</div>
                  <span class={[
                    "badge badge-sm",
                    if(event.enabled == 1, do: "badge-success", else: "badge-ghost")
                  ]}>
                    {if event.enabled == 1, do: "enabled", else: "disabled"}
                  </span>
                </div>
                <div class="flex flex-wrap gap-1 mt-1">
                  <span class="badge badge-sm badge-outline">{event.type}</span>
                  <span class="badge badge-sm badge-outline">#{event.topic}</span>
                </div>
              </div>
            </div>
          </div>

          <!-- Right column: panels -->
          <div>
            <%= case @panel do %>
              <% :catalog -> %>
                <.template_catalog templates={@templates} />
              <% :mcp_form -> %>
                <.mcp_form
                  editing={@mcp_editing}
                  form_name={@mcp_form_name}
                  form_description={@mcp_form_description}
                  form_command={@mcp_form_command}
                  form_args={@mcp_form_args}
                  form_env={@mcp_form_env}
                  name_error={@mcp_name_error}
                  command_error={@mcp_command_error}
                  args_error={@mcp_args_error}
                  env_error={@mcp_env_error}
                />
              <% :event_form -> %>
                <.event_form
                  editing={@event_editing}
                  form_name={@event_form_name}
                  form_type={@event_form_type}
                  form_topic={@event_form_topic}
                  form_command={@event_form_command}
                  form_args={@event_form_args}
                  form_interval={@event_form_interval}
                  form_mcp_server={@event_form_mcp_server}
                  form_webhook_secret={@event_form_webhook_secret}
                  form_enabled={@event_form_enabled}
                  name_error={@event_name_error}
                  topic_error={@event_topic_error}
                  mcp_servers={@mcp_servers}
                />
              <% :template_wizard -> %>
                <.template_wizard
                  template={@wizard_template}
                  wizard_config={@wizard_config}
                  wizard_topic={@wizard_topic}
                />
            <% end %>
          </div>
        </div>
      </.app_shell>
    </Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # Sub-components
  # ---------------------------------------------------------------------------

  defp template_catalog(assigns) do
    ~H"""
    <div class="ui-card">
      <h2 class="text-lg font-semibold mb-4 text-[var(--ui-text-strong)]">Templates</h2>
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3 mb-4">
        <div
          :for={tmpl <- @templates}
          phx-click="use_template"
          phx-value-slug={tmpl["slug"]}
          class="ui-card cursor-pointer hover:ring-1 hover:ring-[var(--ui-accent)]"
        >
          <div class="font-semibold">{tmpl["name"]}</div>
          <div class="text-xs text-base-content/50 line-clamp-2">{tmpl["description"]}</div>
        </div>
      </div>
      <div class="flex gap-2">
        <.button phx-click="new_mcp" variant="secondary" class="flex-1">
          Custom MCP Server
        </.button>
        <.button phx-click="new_event" variant="secondary" class="flex-1">
          Custom Event Source
        </.button>
      </div>
    </div>
    """
  end

  defp mcp_form(assigns) do
    ~H"""
    <div class="ui-card">
      <h2 class="text-lg font-semibold mb-4 text-[var(--ui-text-strong)]">
        {if @editing, do: "Edit: #{@form_name}", else: "Install MCP Server"}
      </h2>

      <form phx-submit="save_mcp" phx-change="validate_mcp">
        <div class="form-control mb-4">
          <label class="mb-2 block text-sm font-medium text-[var(--ui-text-strong)]">Name</label>
          <input
            name="name"
            value={@form_name}
            class={["ui-input w-full", @name_error && "ui-input--error"]}
            disabled={@editing}
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
          <label class="mb-2 block text-sm font-medium text-[var(--ui-text-strong)]">Command</label>
          <input
            name="command"
            value={@form_command}
            class={["ui-input w-full font-mono", @command_error && "ui-input--error"]}
            placeholder="e.g. npx, node, python"
          />
          <div :if={@command_error} class="text-error text-sm mt-1">{@command_error}</div>
        </div>

        <div class="form-control mb-4">
          <label class="mb-2 block text-sm font-medium text-[var(--ui-text-strong)]">Args</label>
          <input
            name="args"
            value={@form_args}
            class={["ui-input w-full font-mono", @args_error && "ui-input--error"]}
            placeholder={~s(e.g. ["-y", "mcp-obsidian", "/path"])}
          />
          <div :if={@args_error} class="text-error text-sm mt-1">{@args_error}</div>
          <div :if={!@args_error} class="text-xs text-base-content/50 mt-1">JSON array of strings</div>
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
          <.button type="submit">{if @editing, do: "Update", else: "Install"}</.button>
          <.button
            :if={@editing}
            type="button"
            phx-click="delete_mcp"
            variant="danger"
            data-confirm="Are you sure you want to delete this MCP server?"
          >
            Delete
          </.button>
          <.button type="button" phx-click="show_catalog" variant="ghost">Cancel</.button>
        </div>
      </form>
    </div>
    """
  end

  defp event_form(assigns) do
    ~H"""
    <div class="ui-card">
      <h2 class="text-lg font-semibold mb-4 text-[var(--ui-text-strong)]">
        {if @editing, do: "Edit: #{@form_name}", else: "New Event Source"}
      </h2>

      <form phx-submit="save_event" phx-change="validate_event">
        <div class="form-control mb-4">
          <label class="mb-2 block text-sm font-medium text-[var(--ui-text-strong)]">Name</label>
          <input
            name="name"
            value={@form_name}
            class={["ui-input w-full", @name_error && "ui-input--error"]}
            disabled={@editing}
            placeholder="e.g. github-webhooks"
          />
          <div :if={@name_error} class="text-error text-sm mt-1">{@name_error}</div>
        </div>

        <div class="form-control mb-4">
          <label class="mb-2 block text-sm font-medium text-[var(--ui-text-strong)]">Type</label>
          <select name="type" class="ui-input w-full">
            <option value="webhook" selected={@form_type == "webhook"}>Webhook</option>
            <option value="poll" selected={@form_type == "poll"}>Poll</option>
          </select>
        </div>

        <div class="form-control mb-4">
          <label class="mb-2 block text-sm font-medium text-[var(--ui-text-strong)]">
            Target Topic
          </label>
          <input
            name="topic"
            value={@form_topic}
            class={["ui-input w-full", @topic_error && "ui-input--error"]}
            placeholder="e.g. github-events"
          />
          <div :if={@topic_error} class="text-error text-sm mt-1">{@topic_error}</div>
        </div>

        <!-- Poll config (shown when type is poll) -->
        <div :if={@form_type == "poll"} class="space-y-4">
          <div class="form-control">
            <label class="mb-2 block text-sm font-medium text-[var(--ui-text-strong)]">
              Poll Command
            </label>
            <input name="poll_command" value={@form_command} class="ui-input w-full font-mono" placeholder="e.g. curl, python" />
          </div>
          <div class="form-control">
            <label class="mb-2 block text-sm font-medium text-[var(--ui-text-strong)]">
              Poll Args
            </label>
            <input
              name="poll_args"
              value={@form_args}
              class="ui-input w-full font-mono"
              placeholder={~s(e.g. ["-s", "https://api.example.com/check"])}
            />
            <div class="text-xs text-base-content/50 mt-1">JSON array of strings</div>
          </div>
          <div class="form-control">
            <label class="mb-2 block text-sm font-medium text-[var(--ui-text-strong)]">
              Interval (seconds)
            </label>
            <input
              name="poll_interval"
              type="number"
              value={@form_interval}
              class="ui-input w-full"
              min="10"
              placeholder="60"
            />
          </div>
        </div>

        <!-- Webhook info (shown when type is webhook and editing) -->
        <div :if={@form_type == "webhook" && @editing && @form_webhook_secret} class="ui-card mt-4 bg-[var(--ui-surface-muted)]">
          <div class="text-sm font-medium text-[var(--ui-text-strong)] mb-1">Webhook URL</div>
          <code class="text-xs break-all">/api/webhooks/{@form_name}</code>
          <div class="text-sm font-medium text-[var(--ui-text-strong)] mt-2 mb-1">Secret</div>
          <code class="text-xs break-all">{@form_webhook_secret}</code>
        </div>

        <div class="form-control mb-4 mt-4">
          <label class="mb-2 block text-sm font-medium text-[var(--ui-text-strong)]">
            Link to MCP Server (optional)
          </label>
          <select name="mcp_server" class="ui-input w-full">
            <option value="">None</option>
            <option
              :for={mcp <- @mcp_servers}
              value={mcp.name}
              selected={@form_mcp_server == mcp.name}
            >
              {mcp.name}
            </option>
          </select>
        </div>

        <div class="form-control mb-4">
          <label class="flex items-center gap-2 cursor-pointer">
            <input
              type="checkbox"
              name="enabled"
              value="true"
              checked={@form_enabled}
              class="checkbox checkbox-sm checkbox-primary"
            />
            <span class="text-sm font-medium text-[var(--ui-text-strong)]">Enabled</span>
          </label>
        </div>

        <div class="flex gap-2 mt-6">
          <.button type="submit">{if @editing, do: "Update", else: "Create"}</.button>
          <.button
            :if={@editing}
            type="button"
            phx-click="delete_event"
            variant="danger"
            data-confirm="Are you sure you want to delete this event source?"
          >
            Delete
          </.button>
          <.button type="button" phx-click="show_catalog" variant="ghost">Cancel</.button>
        </div>
      </form>
    </div>
    """
  end

  defp template_wizard(assigns) do
    ~H"""
    <div class="ui-card">
      <h2 class="text-lg font-semibold mb-4 text-[var(--ui-text-strong)]">
        Setup: {@template["name"]}
      </h2>
      <p class="text-sm text-base-content/50 mb-4">{@template["description"]}</p>

      <form phx-submit="save_connector" phx-change="validate_wizard">
        <div :if={@template["config_schema"]} class="space-y-4 mb-4">
          <div :for={{key, schema} <- @template["config_schema"]} class="form-control">
            <label class="mb-2 block text-sm font-medium text-[var(--ui-text-strong)]">
              {schema["label"]}
            </label>
            <input
              name={"config[#{key}]"}
              type={if schema["secret"], do: "password", else: "text"}
              value={Map.get(@wizard_config, key, "")}
              class="ui-input w-full font-mono"
              required={schema["required"]}
            />
          </div>
        </div>

        <div class="form-control mb-4">
          <label class="mb-2 block text-sm font-medium text-[var(--ui-text-strong)]">
            Target Topic
          </label>
          <input
            name="topic"
            value={@wizard_topic}
            class="ui-input w-full"
            placeholder={@template["event"]["default_topic"] || "events"}
          />
        </div>

        <div class="flex gap-2 mt-6">
          <.button type="submit">Create Connector</.button>
          <.button type="button" phx-click="show_catalog" variant="ghost">Cancel</.button>
        </div>
      </form>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Events — panel navigation
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("show_catalog", _params, socket) do
    socket =
      socket
      |> assign(:panel, :catalog)
      |> assign(:selected_item, nil)
      |> assign(:selected_type, nil)

    {:noreply, socket}
  end

  def handle_event("new_mcp", _params, socket) do
    socket =
      socket
      |> assign(:panel, :mcp_form)
      |> assign_new_mcp_form()
      |> assign(:selected_item, nil)
      |> assign(:selected_type, nil)

    {:noreply, socket}
  end

  def handle_event("new_event", _params, socket) do
    socket =
      socket
      |> assign(:panel, :event_form)
      |> assign_new_event_form()
      |> assign(:selected_item, nil)
      |> assign(:selected_type, nil)

    {:noreply, socket}
  end

  def handle_event("use_template", %{"slug" => slug}, socket) do
    case Templates.get(slug) do
      nil ->
        {:noreply, put_flash(socket, :error, "Template not found")}

      template ->
        default_topic =
          case template["event"] do
            %{"default_topic" => t} -> t
            _ -> ""
          end

        socket =
          socket
          |> assign(:panel, :template_wizard)
          |> assign(:wizard_template, template)
          |> assign(:wizard_config, %{})
          |> assign(:wizard_topic, default_topic)

        {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Events — item selection
  # ---------------------------------------------------------------------------

  def handle_event("select_item", %{"type" => "connector", "name" => name}, socket) do
    server = Enum.find(socket.assigns.mcp_servers, fn s -> s.name == name end)

    if server do
      socket =
        socket
        |> assign(:selected_item, name)
        |> assign(:selected_type, "connector")
        |> assign(:panel, :mcp_form)
        |> load_mcp_into_form(server)

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, "Connector not found")}
    end
  end

  def handle_event("select_item", %{"type" => "mcp", "name" => name}, socket) do
    server = Enum.find(socket.assigns.mcp_servers, fn s -> s.name == name end)

    if server do
      socket =
        socket
        |> assign(:selected_item, name)
        |> assign(:selected_type, "mcp")
        |> assign(:panel, :mcp_form)
        |> load_mcp_into_form(server)

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, "MCP server not found")}
    end
  end

  def handle_event("select_item", %{"type" => "event", "name" => name}, socket) do
    event = Enum.find(socket.assigns.event_sources, fn e -> e.name == name end)

    if event do
      socket =
        socket
        |> assign(:selected_item, name)
        |> assign(:selected_type, "event")
        |> assign(:panel, :event_form)
        |> load_event_into_form(event)

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, "Event source not found")}
    end
  end

  # ---------------------------------------------------------------------------
  # Events — MCP CRUD
  # ---------------------------------------------------------------------------

  def handle_event("validate_mcp", params, socket) do
    name = Map.get(params, "name", "")

    name_error =
      if socket.assigns.mcp_editing do
        nil
      else
        validate_server_name(name, socket.assigns.mcp_servers)
      end

    socket =
      socket
      |> assign(:mcp_form_name, name)
      |> assign(:mcp_form_description, Map.get(params, "description", ""))
      |> assign(:mcp_form_command, Map.get(params, "command", ""))
      |> assign(:mcp_form_args, Map.get(params, "args", "[]"))
      |> assign(:mcp_form_env, Map.get(params, "env", "{}"))
      |> assign(:mcp_name_error, name_error)
      |> assign(:mcp_command_error, nil)
      |> assign(:mcp_args_error, validate_json_array(Map.get(params, "args", "[]")))
      |> assign(:mcp_env_error, validate_json_object(Map.get(params, "env", "{}")))

    {:noreply, socket}
  end

  def handle_event("save_mcp", params, socket) do
    name =
      if socket.assigns.mcp_editing,
        do: socket.assigns.mcp_form_name,
        else: String.trim(params["name"] || "")

    description = String.trim(params["description"] || "")
    command = String.trim(params["command"] || "")
    args_str = String.trim(params["args"] || "[]")
    env_str = String.trim(params["env"] || "{}")

    command_error = if command == "", do: "Command is required", else: nil
    args_error = validate_json_array(args_str)
    env_error = validate_json_object(env_str)

    name_error =
      if socket.assigns.mcp_editing, do: nil, else: validate_server_name(name, socket.assigns.mcp_servers)

    if name_error || command_error || args_error || env_error do
      socket =
        socket
        |> assign(:mcp_name_error, name_error)
        |> assign(:mcp_command_error, command_error)
        |> assign(:mcp_args_error, args_error)
        |> assign(:mcp_env_error, env_error)

      {:noreply, socket}
    else
      args = Jason.decode!(args_str)
      env = if env_str == "" || env_str == "{}", do: %{}, else: Jason.decode!(env_str)

      if socket.assigns.mcp_editing do
        handle_update_mcp(socket, name, description, command, args, env)
      else
        handle_create_mcp(socket, name, description, command, args, env)
      end
    end
  end

  def handle_event("delete_mcp", _params, socket) do
    name = socket.assigns.selected_item

    case Persistence.delete_mcp_server(name) do
      :ok ->
        socket =
          socket
          |> reload_data()
          |> assign(:panel, :catalog)
          |> assign(:selected_item, nil)
          |> assign(:selected_type, nil)
          |> put_flash(:info, "MCP server \"#{name}\" deleted")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete: #{inspect(reason)}")}
    end
  end

  # ---------------------------------------------------------------------------
  # Events — Event source CRUD
  # ---------------------------------------------------------------------------

  def handle_event("validate_event", params, socket) do
    name = Map.get(params, "name", "")
    type = Map.get(params, "type", "webhook")

    name_error =
      if socket.assigns.event_editing do
        nil
      else
        validate_event_name(name, socket.assigns.event_sources)
      end

    topic_error = if String.trim(Map.get(params, "topic", "")) == "", do: nil, else: nil

    socket =
      socket
      |> assign(:event_form_name, name)
      |> assign(:event_form_type, type)
      |> assign(:event_form_topic, Map.get(params, "topic", ""))
      |> assign(:event_form_command, Map.get(params, "poll_command", ""))
      |> assign(:event_form_args, Map.get(params, "poll_args", "[]"))
      |> assign(:event_form_interval, Map.get(params, "poll_interval", "60"))
      |> assign(:event_form_mcp_server, Map.get(params, "mcp_server", ""))
      |> assign(:event_form_enabled, Map.has_key?(params, "enabled"))
      |> assign(:event_name_error, name_error)
      |> assign(:event_topic_error, topic_error)

    {:noreply, socket}
  end

  def handle_event("save_event", params, socket) do
    name =
      if socket.assigns.event_editing,
        do: socket.assigns.event_form_name,
        else: String.trim(params["name"] || "")

    type = params["type"] || "webhook"
    topic = String.trim(params["topic"] || "")
    mcp_server = String.trim(params["mcp_server"] || "")
    enabled = Map.has_key?(params, "enabled")

    name_error =
      if socket.assigns.event_editing, do: nil, else: validate_event_name(name, socket.assigns.event_sources)

    topic_error = if topic == "", do: "Topic is required", else: nil

    if name_error || topic_error do
      socket =
        socket
        |> assign(:event_name_error, name_error)
        |> assign(:event_topic_error, topic_error)

      {:noreply, socket}
    else
      config = build_event_config(type, params)
      webhook_secret = if type == "webhook" && !socket.assigns.event_editing, do: generate_webhook_secret(), else: nil

      attrs = %{
        type: type,
        topic: topic,
        config: config,
        mcp_server: if(mcp_server == "", do: nil, else: mcp_server),
        enabled: enabled
      }

      attrs = if webhook_secret, do: Map.put(attrs, :webhook_secret, webhook_secret), else: attrs

      if socket.assigns.event_editing do
        handle_update_event(socket, name, attrs)
      else
        handle_create_event(socket, name, attrs)
      end
    end
  end

  def handle_event("delete_event", _params, socket) do
    name = socket.assigns.selected_item

    case Persistence.delete_event_source(name) do
      :ok ->
        socket =
          socket
          |> reload_data()
          |> assign(:panel, :catalog)
          |> assign(:selected_item, nil)
          |> assign(:selected_type, nil)
          |> put_flash(:info, "Event source \"#{name}\" deleted")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_enabled", %{"name" => name}, socket) do
    event = Enum.find(socket.assigns.event_sources, fn e -> e.name == name end)

    if event do
      new_enabled = event.enabled != 1

      case Persistence.update_event_source(name, %{enabled: new_enabled}) do
        :ok ->
          {:noreply, reload_data(socket)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to toggle: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Event source not found")}
    end
  end

  # ---------------------------------------------------------------------------
  # Events — Template wizard
  # ---------------------------------------------------------------------------

  def handle_event("validate_wizard", params, socket) do
    config = Map.get(params, "config", %{})
    topic = Map.get(params, "topic", "")

    socket =
      socket
      |> assign(:wizard_config, config)
      |> assign(:wizard_topic, topic)

    {:noreply, socket}
  end

  def handle_event("save_connector", params, socket) do
    template = socket.assigns.wizard_template
    config = Map.get(params, "config", %{})
    topic = String.trim(Map.get(params, "topic", ""))

    topic =
      if topic == "" do
        case template["event"] do
          %{"default_topic" => t} -> t
          _ -> template["slug"] <> "-events"
        end
      else
        topic
      end

    user_config = Map.put(config, "topic", topic)
    applied = Templates.apply_config(template, user_config)
    slug = template["slug"]

    # Create MCP server if template has one
    mcp_result =
      if applied.mcp do
        mcp = applied.mcp
        Persistence.create_mcp_server(slug, mcp.description || template["description"], mcp.command, mcp.args, mcp.env || %{})
      else
        :ok
      end

    case mcp_result do
      :ok ->
        # Create event source if template has one
        if applied.event do
          ev = applied.event
          webhook_secret = if ev.type == "webhook", do: generate_webhook_secret(), else: nil

          attrs = %{
            type: ev.type,
            topic: ev.topic,
            config: ev.config || %{},
            webhook_secret: webhook_secret,
            mcp_server: if(applied.mcp, do: slug, else: nil),
            enabled: true
          }

          event_name = slug <> "-events"
          Persistence.create_event_source(event_name, attrs)
        end

        socket =
          socket
          |> reload_data()
          |> assign(:panel, :catalog)
          |> put_flash(:info, "Connector \"#{slug}\" created")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create connector: #{inspect(reason)}")}
    end
  end

  # ---------------------------------------------------------------------------
  # MCP create/update helpers
  # ---------------------------------------------------------------------------

  defp handle_create_mcp(socket, name, description, command, args, env) do
    case Persistence.create_mcp_server(name, description, command, args, env) do
      :ok ->
        socket =
          socket
          |> reload_data()
          |> assign(:panel, :catalog)
          |> put_flash(:info, "MCP server \"#{name}\" installed")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create MCP server: #{inspect(reason)}")}
    end
  end

  defp handle_update_mcp(socket, name, description, command, args, env) do
    attrs = %{description: description, command: command, args: args, env: env}

    case Persistence.update_mcp_server(name, attrs) do
      :ok ->
        socket =
          socket
          |> reload_data()
          |> put_flash(:info, "MCP server \"#{name}\" updated")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update MCP server: #{inspect(reason)}")}
    end
  end

  # ---------------------------------------------------------------------------
  # Event source create/update helpers
  # ---------------------------------------------------------------------------

  defp handle_create_event(socket, name, attrs) do
    case Persistence.create_event_source(name, attrs) do
      :ok ->
        socket =
          socket
          |> reload_data()
          |> assign(:panel, :catalog)
          |> put_flash(:info, "Event source \"#{name}\" created")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create event source: #{inspect(reason)}")}
    end
  end

  defp handle_update_event(socket, name, attrs) do
    case Persistence.update_event_source(name, attrs) do
      :ok ->
        socket =
          socket
          |> reload_data()
          |> put_flash(:info, "Event source \"#{name}\" updated")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update event source: #{inspect(reason)}")}
    end
  end

  # ---------------------------------------------------------------------------
  # Data helpers
  # ---------------------------------------------------------------------------

  defp load_mcp_servers do
    case Persistence.get_mcp_servers() do
      {:ok, servers} -> servers
      _ -> []
    end
  end

  defp load_event_sources do
    case Persistence.get_event_sources() do
      {:ok, sources} -> sources
      _ -> []
    end
  end

  defp reload_data(socket) do
    socket
    |> assign(:mcp_servers, load_mcp_servers())
    |> assign(:event_sources, load_event_sources())
  end

  defp linked_connectors(mcp_servers, event_sources) do
    mcp_names = MapSet.new(mcp_servers, fn s -> s.name end)

    event_sources
    |> Enum.filter(fn e -> e.mcp_server && e.mcp_server in mcp_names end)
    |> Enum.map(fn e ->
      mcp = Enum.find(mcp_servers, fn s -> s.name == e.mcp_server end)
      {mcp, e}
    end)
  end

  defp standalone_mcp_servers(mcp_servers, event_sources) do
    linked_mcp_names = MapSet.new(
      Enum.filter(event_sources, fn e -> e.mcp_server end),
      fn e -> e.mcp_server end
    )

    Enum.reject(mcp_servers, fn s -> s.name in linked_mcp_names end)
  end

  defp standalone_event_sources(_mcp_servers, event_sources) do
    Enum.filter(event_sources, fn e -> is_nil(e.mcp_server) || e.mcp_server == "" end)
  end

  defp assigned_agents(mcp_server_name) do
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
  # Form helpers
  # ---------------------------------------------------------------------------

  defp load_mcp_into_form(socket, server) do
    args_str = format_json_field(server.args, "[]")
    env_str = format_json_field(server.env, "{}")

    socket
    |> assign(:mcp_editing, true)
    |> assign(:mcp_form_name, server.name)
    |> assign(:mcp_form_description, server.description || "")
    |> assign(:mcp_form_command, server.command || "")
    |> assign(:mcp_form_args, args_str)
    |> assign(:mcp_form_env, env_str)
    |> assign(:mcp_name_error, nil)
    |> assign(:mcp_command_error, nil)
    |> assign(:mcp_args_error, nil)
    |> assign(:mcp_env_error, nil)
  end

  defp load_event_into_form(socket, event) do
    config = parse_config(event.config)

    socket
    |> assign(:event_editing, true)
    |> assign(:event_form_name, event.name)
    |> assign(:event_form_type, event.type || "webhook")
    |> assign(:event_form_topic, event.topic || "")
    |> assign(:event_form_command, get_in(config, ["command"]) || "")
    |> assign(:event_form_args, format_json_field(get_in(config, ["args"]), "[]"))
    |> assign(:event_form_interval, to_string(get_in(config, ["interval_seconds"]) || 60))
    |> assign(:event_form_mcp_server, event.mcp_server || "")
    |> assign(:event_form_webhook_secret, event.webhook_secret)
    |> assign(:event_form_enabled, event.enabled == 1)
    |> assign(:event_name_error, nil)
    |> assign(:event_topic_error, nil)
  end

  defp assign_new_mcp_form(socket) do
    socket
    |> assign(:mcp_editing, false)
    |> assign(:mcp_form_name, "")
    |> assign(:mcp_form_description, "")
    |> assign(:mcp_form_command, "")
    |> assign(:mcp_form_args, "[]")
    |> assign(:mcp_form_env, "{}")
    |> assign(:mcp_name_error, nil)
    |> assign(:mcp_command_error, nil)
    |> assign(:mcp_args_error, nil)
    |> assign(:mcp_env_error, nil)
  end

  defp assign_new_event_form(socket) do
    socket
    |> assign(:event_editing, false)
    |> assign(:event_form_name, "")
    |> assign(:event_form_type, "webhook")
    |> assign(:event_form_topic, "")
    |> assign(:event_form_command, "")
    |> assign(:event_form_args, "[]")
    |> assign(:event_form_interval, "60")
    |> assign(:event_form_mcp_server, "")
    |> assign(:event_form_webhook_secret, nil)
    |> assign(:event_form_enabled, true)
    |> assign(:event_name_error, nil)
    |> assign(:event_topic_error, nil)
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

  defp validate_event_name("", _sources), do: nil

  defp validate_event_name(name, sources) do
    cond do
      not Regex.match?(~r/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,30}$/, name) ->
        "Invalid name. Use alphanumeric characters, hyphens, and underscores (1-31 chars)"

      Enum.any?(sources, fn s -> s.name == name end) ->
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

  defp parse_config(nil), do: %{}

  defp parse_config(config) when is_binary(config) do
    case Jason.decode(config) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp parse_config(config) when is_map(config), do: config
  defp parse_config(_), do: %{}

  defp build_event_config("poll", params) do
    %{
      "command" => Map.get(params, "poll_command", ""),
      "args" => parse_json_or_default(Map.get(params, "poll_args", "[]"), []),
      "interval_seconds" => parse_int_or_default(Map.get(params, "poll_interval", "60"), 60)
    }
  end

  defp build_event_config(_type, _params), do: %{}

  defp parse_json_or_default(str, default) do
    case Jason.decode(str) do
      {:ok, val} -> val
      _ -> default
    end
  end

  defp parse_int_or_default(str, default) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> default
    end
  end

  defp generate_webhook_secret do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
