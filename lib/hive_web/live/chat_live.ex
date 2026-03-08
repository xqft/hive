defmodule HiveWeb.ChatLive do
  use HiveWeb, :live_view

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to global PubSub channels
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hive.PubSub, "registry")
      Phoenix.PubSub.subscribe(Hive.PubSub, "agents")
      Phoenix.PubSub.subscribe(Hive.PubSub, "containers")
    end

    # Load topics and agents from persistence
    all_topics = load_topics()
    all_agents = load_agents()

    topics = Enum.filter(all_topics, fn t -> t.type != "dm" end)
    dms = Enum.filter(all_topics, fn t -> t.type == "dm" end)

    # Pick default active topic
    active_topic =
      case Enum.find(topics, fn t -> t.name == "general" end) do
        nil -> if topics != [], do: hd(topics).name, else: nil
        t -> t.name
      end

    # Build agent statuses map
    agent_statuses = build_agent_statuses(all_agents)

    # Load messages and members for active topic
    {messages, members} = load_topic_data(active_topic)

    # Subscribe to the active topic's PubSub channel
    if connected?(socket) && active_topic do
      Phoenix.PubSub.subscribe(Hive.PubSub, "topic:#{active_topic}")
    end

    # Load containers from registry
    containers = load_containers()

    socket =
      socket
      |> assign(:topics, topics)
      |> assign(:dms, dms)
      |> assign(:active_topic, active_topic)
      |> assign(:messages, messages)
      |> assign(:members, members)
      |> assign(:agents, all_agents)
      |> assign(:agent_statuses, agent_statuses)
      |> assign(:containers, containers)
      |> assign(:page_title, "Chat")
      |> assign(:show_create_topic, false)
      |> assign(:show_new_dm, false)
      |> assign(:new_topic_name, "")
      |> assign(:new_topic_error, nil)
      |> assign(:form_reset, 0)

    {:ok, socket, layout: false}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-200">
      <!-- Left sidebar -->
      <div class="w-64 bg-base-100 border-r border-base-300 flex flex-col">
        <div class="p-4 font-bold text-lg border-b border-base-300">Hive</div>
        <!-- Navigation links -->
        <div class="p-2">
          <a href="/dashboard" class="btn btn-ghost btn-sm w-full justify-start">Dashboard</a>
          <a href="/agents" class="btn btn-ghost btn-sm w-full justify-start">Agents</a>
          <a href="/mcp" class="btn btn-ghost btn-sm w-full justify-start">MCP Servers</a>
        </div>
        <div class="divider my-0"></div>
        <!-- Topics -->
        <div class="p-2 flex-1 overflow-y-auto">
          <div class="flex items-center justify-between px-2 mb-1">
            <span class="text-xs font-bold text-base-content/50 uppercase tracking-wide">Topics</span>
            <button phx-click="toggle_create_topic" class="btn btn-ghost btn-xs">+</button>
          </div>

          <div :if={@show_create_topic} class="px-2 mb-2">
            <form phx-submit="create_topic" class="flex flex-col gap-1">
              <input
                name="name"
                value={@new_topic_name}
                placeholder="topic-name"
                class={"input input-bordered input-xs w-full #{if @new_topic_error, do: "input-error"}"}
                phx-change="validate_topic_name"
                autocomplete="off"
              />
              <div :if={@new_topic_error} class="text-error text-xs">{@new_topic_error}</div>
              <div class="flex gap-1">
                <button type="submit" class="btn btn-primary btn-xs flex-1">Create</button>
                <button type="button" phx-click="toggle_create_topic" class="btn btn-ghost btn-xs">
                  Cancel
                </button>
              </div>
            </form>
          </div>

          <button
            :for={topic <- @topics}
            phx-click="select_topic"
            phx-value-name={topic.name}
            class={"btn btn-ghost btn-sm w-full justify-start #{if @active_topic == topic.name, do: "btn-active"}"}
          >
            # {topic.name}
          </button>

          <div class="flex items-center justify-between px-2 mb-1 mt-3">
            <span class="text-xs font-bold text-base-content/50 uppercase tracking-wide">
              Direct Messages
            </span>
            <button phx-click="toggle_new_dm" class="btn btn-ghost btn-xs">+</button>
          </div>

          <div :if={@show_new_dm} class="px-2 mb-2">
            <div :if={@agents == []} class="text-xs text-base-content/50">No agents yet.</div>
            <button
              :for={agent <- @agents}
              phx-click="start_dm"
              phx-value-name={agent.name}
              class="btn btn-ghost btn-xs w-full justify-start"
            >
              {agent.name}
            </button>
          </div>

          <button
            :for={dm <- @dms}
            phx-click="select_topic"
            phx-value-name={dm.name}
            class={"btn btn-ghost btn-sm w-full justify-start #{if @active_topic == dm.name, do: "btn-active"}"}
          >
            {dm_display_name(dm.name)}
          </button>
        </div>
      </div>
      
    <!-- Center: messages -->
      <div class="flex-1 flex flex-col">
        <div class="p-4 border-b border-base-300 font-semibold">
          {if @active_topic, do: @active_topic, else: "Select a topic"}
        </div>
        <div class="flex-1 overflow-y-auto p-4 space-y-2" id="messages" phx-hook="ScrollBottom">
          <div :for={msg <- @messages} class="chat chat-start">
            <div class="chat-header">
              {msg.sender}
              <time class="text-xs opacity-50">{format_time(msg.ts)}</time>
            </div>
            <div class={"chat-bubble #{if msg.sender == "human", do: "chat-bubble-primary"}"}>
              {msg.body}
            </div>
          </div>
        </div>
        <!-- Input -->
        <form
          id={"msg-form-#{@form_reset}"}
          phx-submit="send_message"
          class="p-4 border-t border-base-300"
        >
          <div class="join w-full">
            <input
              name="text"
              placeholder="Type a message..."
              class="input input-bordered join-item flex-1"
              autocomplete="off"
            />
            <button type="submit" class="btn btn-primary join-item">Send</button>
          </div>
        </form>
      </div>
      
    <!-- Right sidebar: members -->
      <div class="w-56 bg-base-100 border-l border-base-300 p-4 overflow-y-auto">
        <div class="text-xs font-bold text-base-content/50 uppercase tracking-wide mb-2">Members</div>
        <div :for={member <- @members} class="flex items-center gap-2 py-1">
          <div class={"w-2 h-2 rounded-full #{status_color(@agent_statuses[member])}"} />
          <span class="text-sm">{member}</span>
        </div>

        <div class="divider"></div>
        <div class="text-xs font-bold text-base-content/50 uppercase tracking-wide mb-2">
          Containers
        </div>
        <div :for={container <- @containers} class="text-xs mb-2">
          <div class="font-mono">{container.id}</div>
          <div class="text-base-content/50">{container.task}</div>
          <button
            phx-click="kill_container"
            phx-value-id={container.id}
            class="btn btn-ghost btn-xs text-error"
          >
            Kill
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Event handlers
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("select_topic", %{"name" => name}, socket) do
    old_topic = socket.assigns.active_topic

    # Unsubscribe from old topic PubSub
    if old_topic do
      Phoenix.PubSub.unsubscribe(Hive.PubSub, "topic:#{old_topic}")
    end

    # Subscribe to new topic PubSub
    Phoenix.PubSub.subscribe(Hive.PubSub, "topic:#{name}")

    # Load messages and members for new topic
    {messages, members} = load_topic_data(name)

    socket =
      socket
      |> assign(:active_topic, name)
      |> assign(:messages, messages)
      |> assign(:members, members)

    {:noreply, socket}
  end

  def handle_event("send_message", %{"text" => text}, socket) when text != "" do
    active_topic = socket.assigns.active_topic

    if active_topic do
      if String.starts_with?(active_topic, "dm:") do
        other = dm_other_party(active_topic, "human")
        {:ok, dm_name} = Hive.Topic.ensure_dm("human", other)
        Hive.Topic.post(dm_name, "human", text)
      else
        Hive.Topic.post(active_topic, "human", text)
      end
    end

    {:noreply, assign(socket, :form_reset, socket.assigns.form_reset + 1)}
  end

  def handle_event("send_message", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_create_topic", _params, socket) do
    {:noreply,
     assign(socket,
       show_create_topic: !socket.assigns.show_create_topic,
       new_topic_name: "",
       new_topic_error: nil
     )}
  end

  def handle_event("validate_topic_name", %{"name" => name}, socket) do
    error =
      case Hive.Validation.validate_name(name) do
        :ok ->
          if Hive.Persistence.name_exists?(name), do: "Name already taken", else: nil

        {:error, _} ->
          if name == "", do: nil, else: "Invalid name"
      end

    {:noreply, assign(socket, new_topic_name: name, new_topic_error: error)}
  end

  def handle_event("create_topic", %{"name" => name}, socket) do
    name = String.trim(name)

    case Hive.Validation.validate_name(name) do
      {:error, _} ->
        {:noreply, assign(socket, new_topic_error: "Invalid name")}

      :ok ->
        case Hive.Persistence.create_topic(name, "", "topic", "human") do
          :ok ->
            DynamicSupervisor.start_child(
              Hive.TopicSup,
              {Hive.Topic, name: name, description: "", type: :topic, created_by: "human"}
            )

            all_topics = load_topics()
            topics = Enum.filter(all_topics, fn t -> t.type != "dm" end)

            socket =
              socket
              |> assign(:topics, topics)
              |> assign(:show_create_topic, false)
              |> assign(:new_topic_name, "")
              |> assign(:new_topic_error, nil)

            {:noreply, socket}

          {:error, :name_taken} ->
            {:noreply, assign(socket, new_topic_error: "Name already taken")}

          {:error, reason} ->
            {:noreply, assign(socket, new_topic_error: to_string(reason))}
        end
    end
  end

  def handle_event("toggle_new_dm", _params, socket) do
    {:noreply, assign(socket, show_new_dm: !socket.assigns.show_new_dm)}
  end

  def handle_event("start_dm", %{"name" => agent_name}, socket) do
    {:ok, dm_name} = Hive.Topic.ensure_dm("human", agent_name)

    # Reload DMs and switch to the new one
    all_topics = load_topics()
    dms = Enum.filter(all_topics, fn t -> t.type == "dm" end)

    old_topic = socket.assigns.active_topic
    if old_topic, do: Phoenix.PubSub.unsubscribe(Hive.PubSub, "topic:#{old_topic}")
    Phoenix.PubSub.subscribe(Hive.PubSub, "topic:#{dm_name}")

    {messages, members} = load_topic_data(dm_name)

    socket =
      socket
      |> assign(:dms, dms)
      |> assign(:active_topic, dm_name)
      |> assign(:messages, messages)
      |> assign(:members, members)
      |> assign(:show_new_dm, false)

    {:noreply, socket}
  end

  def handle_event("kill_container", %{"id" => id}, socket) do
    Hive.Container.kill(id)
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # PubSub handlers
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:message, msg}, socket) do
    # Only append if the message is for the active topic
    if msg.topic == socket.assigns.active_topic do
      new_msg = %{sender: msg.sender, body: msg.body, ts: msg.ts}
      messages = socket.assigns.messages ++ [new_msg]
      {:noreply, assign(socket, :messages, messages)}
    else
      {:noreply, socket}
    end
  end

  # Agent status changes
  def handle_info({:status, name, status}, socket) do
    agent_statuses = Map.put(socket.assigns.agent_statuses, name, status)
    {:noreply, assign(socket, :agent_statuses, agent_statuses)}
  end

  # Registry changes: new topic created
  def handle_info({:topic_created, name, _created_by}, socket) do
    # Reload topics from persistence
    all_topics = load_topics()
    topics = Enum.filter(all_topics, fn t -> t.type != "dm" end)
    dms = Enum.filter(all_topics, fn t -> t.type == "dm" end)

    socket =
      socket
      |> assign(:topics, topics)
      |> assign(:dms, dms)

    Logger.debug("Topic created: #{name}")
    {:noreply, socket}
  end

  # Container started
  def handle_info({:started, agent_name, id, task}, socket) do
    container = %{id: id, task: task, agent: agent_name}
    containers = socket.assigns.containers ++ [container]
    {:noreply, assign(socket, :containers, containers)}
  end

  # Container stopped
  def handle_info({:stopped, id, _status}, socket) do
    containers = Enum.reject(socket.assigns.containers, fn c -> c.id == id end)
    {:noreply, assign(socket, :containers, containers)}
  end

  # Catch-all for unhandled PubSub messages
  def handle_info(msg, socket) do
    Logger.debug("ChatLive unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Helper functions
  # ---------------------------------------------------------------------------

  defp load_topics do
    case Hive.Persistence.get_topics() do
      {:ok, topics} -> topics
      _ -> []
    end
  end

  defp load_agents do
    case Hive.Persistence.get_agents() do
      {:ok, agents} -> agents
      _ -> []
    end
  end

  defp load_topic_data(nil), do: {[], []}

  defp load_topic_data(topic_name) do
    messages =
      try do
        topic_name
        |> Hive.Topic.recent(50)
        |> Enum.reverse()
      catch
        :exit, _ -> []
      end

    members =
      try do
        topic_name
        |> Hive.Topic.subscribers()
        |> MapSet.to_list()
        |> Enum.sort()
      catch
        :exit, _ -> []
      end

    {messages, members}
  end

  defp build_agent_statuses(agents) do
    Map.new(agents, fn a ->
      status =
        try do
          Hive.Agent.status(a.name)
        catch
          _, _ -> :unknown
        end

      {a.name, status}
    end)
  end

  defp load_containers do
    # Get all containers from the registry
    try do
      Hive.ContainerRegistry
      |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
      |> Enum.map(fn {id, pid, agent_name} ->
        task =
          try do
            {:ok, status_str} = GenServer.call(pid, :check)
            # Extract task line from the status string
            status_str
            |> String.split("\n")
            |> Enum.find_value("", fn line ->
              case String.split(line, "Task: ", parts: 2) do
                [_, task] -> task
                _ -> nil
              end
            end)
          catch
            _, _ -> ""
          end

        %{id: id, task: task, agent: agent_name}
      end)
    rescue
      _ -> []
    end
  end

  defp status_color(:idle), do: "bg-success"
  defp status_color(:thinking), do: "bg-warning animate-pulse"
  defp status_color(_), do: "bg-base-content/30"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_time(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> ts
    end
  end

  defp format_time(_), do: ""

  defp dm_display_name("dm:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [a, b] -> "#{a} <-> #{b}"
      _ -> rest
    end
  end

  defp dm_display_name(name), do: name

  defp dm_other_party("dm:" <> rest, self_name) do
    case String.split(rest, ":", parts: 2) do
      [a, b] -> if a == self_name, do: b, else: a
      _ -> self_name
    end
  end

  defp dm_other_party(_, _), do: "unknown"
end
