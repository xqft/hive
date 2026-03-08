defmodule HiveWeb.ChatLive do
  use HiveWeb, :live_view

  alias HiveWeb.Markdown

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
      |> assign(:typing_agents, [])

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.app_shell
        current={:chat}
        title={page_heading(@active_topic)}
        subtitle="Fast topic switching, lightweight DMs, and markdown-ready chat without losing scanability."
      >
        <div class="ui-chat-screen">
          <div class="ui-chat-layout">
            <aside class="ui-chat-rail ui-surface">
              <div class="ui-chat-groups">
                <section class="ui-stack">
                  <div class="ui-section-row">
                    <div>
                      <p class="ui-section-label">Topics</p>
                      <p class="ui-helper-text">Persistent spaces for ongoing work.</p>
                    </div>
                    <.button variant="ghost" size="sm" phx-click="toggle_create_topic">New</.button>
                  </div>

                  <div :if={@show_create_topic} class="ui-card">
                    <form
                      id="create-topic-form"
                      phx-submit="create_topic"
                      phx-change="validate_topic_name"
                      class="ui-stack"
                    >
                      <input
                        id="new-topic-name"
                        name="name"
                        value={@new_topic_name}
                        placeholder="topic-name"
                        class={["ui-input w-full", @new_topic_error && "ui-input--error"]}
                        autocomplete="off"
                      />
                      <p :if={@new_topic_error} class="text-sm text-error">{@new_topic_error}</p>
                      <div class="ui-section-row">
                        <.button size="sm">Create</.button>
                        <.button
                          variant="ghost"
                          size="sm"
                          type="button"
                          phx-click="toggle_create_topic"
                        >
                          Cancel
                        </.button>
                      </div>
                    </form>
                  </div>

                  <div id="topic-list" class="ui-topic-list">
                    <button
                      :for={topic <- @topics}
                      id={"topic-#{topic.name}"}
                      phx-click="select_topic"
                      phx-value-name={topic.name}
                      class={["ui-topic-link", @active_topic == topic.name && "is-active"]}
                    >
                      <span>
                        <span class="font-medium text-[var(--ui-text-strong)]"># {topic.name}</span>
                        <span class="ui-topic-link__meta">Topic</span>
                      </span>
                    </button>
                  </div>
                </section>

                <section class="ui-stack">
                  <div class="ui-section-row">
                    <div>
                      <p class="ui-section-label">Direct messages</p>
                      <p class="ui-helper-text">Open a focused thread with one agent.</p>
                    </div>
                    <.button variant="ghost" size="sm" phx-click="toggle_new_dm">New</.button>
                  </div>

                  <div :if={@show_new_dm} class="ui-card ui-stack">
                    <div :if={@agents == []} class="ui-helper-text">No agents available yet.</div>
                    <button
                      :for={agent <- @agents}
                      id={"start-dm-#{agent.name}"}
                      phx-click="start_dm"
                      phx-value-name={agent.name}
                      class="ui-topic-link"
                    >
                      <span>
                        <span class="font-medium text-[var(--ui-text-strong)]">{agent.name}</span>
                        <span class="ui-topic-link__meta">Start DM</span>
                      </span>
                    </button>
                  </div>

                  <div id="dm-list" class="ui-topic-list">
                    <button
                      :for={dm <- @dms}
                      id={"dm-#{dm.name}"}
                      phx-click="select_topic"
                      phx-value-name={dm.name}
                      class={["ui-topic-link", @active_topic == dm.name && "is-active"]}
                    >
                      <span>
                        <span class="font-medium text-[var(--ui-text-strong)]">
                          {dm_display_name(dm.name)}
                        </span>
                        <span class="ui-topic-link__meta">Direct message</span>
                      </span>
                    </button>
                  </div>
                </section>
              </div>
            </aside>

            <section class="ui-chat-panel ui-surface">
              <div class="ui-chat-panel__header">
                <div>
                  <p class="ui-section-label">Active conversation</p>
                  <h2 class="ui-chat-panel__title">{active_topic_label(@active_topic)}</h2>
                </div>

                <div class="ui-chat-meta">
                  <.icon name="hero-user-group" class="size-4" />
                  <span>{length(@members)} members</span>
                </div>
              </div>

              <div id="messages" class="ui-chat-messages" phx-hook="ScrollBottom">
                <div :if={@messages == []} class="ui-empty" id="empty-chat-state">
                  <div>
                    <p class="text-base font-semibold text-[var(--ui-text-strong)]">
                      No messages yet
                    </p>
                    <p class="mt-2 max-w-md text-sm text-[var(--ui-text-soft)]">
                      Start the thread with plain text or markdown. Links, lists, quotes, and code blocks render safely.
                    </p>
                  </div>
                </div>

                <%= for {msg, index} <- Enum.with_index(@messages) do %>
                  <%= if system_message?(msg) do %>
                    <article class="ui-system-message">
                      <div class="ui-system-message__pill">{msg.body}</div>
                    </article>
                  <% else %>
                    <article class={[
                      "ui-message",
                      message_role_class(msg)
                    ]}>
                      <div class="ui-message__meta">
                        <span class="ui-message__sender">{sender_label(msg.sender)}</span>
                        <time>{format_time(msg.ts)}</time>
                      </div>
                      <div class="ui-message__bubble">
                        <div
                          id={"msg-body-#{index}"}
                          class="ui-markdown"
                          phx-hook="MentionContent"
                          data-agent-profiles={mention_profiles_json(@agents)}
                          data-mention-body={msg.body}
                        >
                          {Markdown.render(msg.body)}
                        </div>
                      </div>
                    </article>
                  <% end %>
                <% end %>
              </div>

              <div :if={@typing_agents != []} class="ui-typing-indicator" id="typing-indicator">
                <.icon name="hero-ellipsis-horizontal" class="size-4" />
                <span>{typing_summary(@typing_agents)}</span>
              </div>

              <form id={"msg-form-#{@form_reset}"} phx-submit="send_message" class="ui-chat-composer">
                <div
                  id="chat-composer-shell"
                  class="ui-chat-composer__editor"
                  phx-hook="ChatComposer"
                  data-agent-profiles={mention_profiles_json(@agents)}
                >
                  <div
                    class="ui-chat-composer__overlay ui-chat-composer__field"
                    data-role="mention-overlay"
                    aria-hidden="true"
                  >
                  </div>

                  <textarea
                    id="chat-composer"
                    name="text"
                    rows="1"
                    class="ui-chat-composer__field ui-chat-composer__input"
                    placeholder="Message the topic. Press Enter to send, Shift+Enter for a new line."
                    autocomplete="off"
                    spellcheck="true"
                  ></textarea>

                  <div
                    class="ui-mention-menu hidden"
                    data-role="mention-menu"
                    aria-label="Agent mention suggestions"
                  >
                  </div>
                </div>

                <div class="ui-chat-composer__footer">
                  <p class="ui-helper-text">
                    Markdown supported: code fences, links, emphasis, lists, and blockquotes.
                  </p>
                  <.button id="chat-send-button">Send</.button>
                </div>
              </form>
            </section>

            <aside class="ui-chat-aside ui-surface">
              <div class="ui-stack">
                <section class="ui-stack">
                  <div>
                    <p class="ui-section-label">Members</p>
                    <p class="ui-helper-text">Who is currently subscribed here.</p>
                  </div>

                  <div :if={@members == []} class="ui-empty">
                    No active members in this conversation.
                  </div>

                  <div
                    :for={member <- @members}
                    class="ui-list-row rounded-2xl bg-[var(--ui-surface-muted)] px-3 py-2"
                  >
                    <div>
                      <p class="font-medium text-[var(--ui-text-strong)]">{member}</p>
                      <p class="ui-helper-text">{status_text(@agent_statuses[member])}</p>
                    </div>
                    <span class="ui-pill" style={"color: #{status_color(@agent_statuses[member])}"}>
                      <span class="ui-dot"></span>
                      {status_text(@agent_statuses[member])}
                    </span>
                  </div>
                </section>

                <section class="ui-stack">
                  <div>
                    <p class="ui-section-label">Containers</p>
                    <p class="ui-helper-text">Active runtime tasks surfaced next to the chat.</p>
                  </div>

                  <div :if={@containers == []} class="ui-empty">No active containers right now.</div>

                  <div :for={container <- @containers} class="ui-card ui-stack">
                    <div>
                      <p class="ui-meta-label">{container.agent || "container"}</p>
                      <p class="mt-1 font-mono text-sm text-[var(--ui-text-strong)]">
                        {container.id}
                      </p>
                      <p class="mt-2 text-sm text-[var(--ui-text-soft)]">{container.task}</p>
                    </div>
                    <.button
                      variant="ghost"
                      size="sm"
                      phx-click="kill_container"
                      phx-value-id={container.id}
                    >
                      Kill container
                    </.button>
                  </div>
                </section>
              </div>
            </aside>
          </div>
        </div>
      </.app_shell>
    </Layouts.app>
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
      |> assign(:typing_agents, [])

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
      |> assign(:typing_agents, [])
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
      new_msg = %{sender: msg.sender, sender_kind: msg.sender_kind, body: msg.body, ts: msg.ts}
      messages = socket.assigns.messages ++ [new_msg]

      socket =
        socket
        |> assign(:messages, messages)
        |> update(:typing_agents, &Enum.reject(&1, fn name -> name == msg.sender end))

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:member_joined, %{topic: topic, agent: agent, ts: ts}}, socket) do
    if topic == socket.assigns.active_topic do
      members =
        socket.assigns.members
        |> Kernel.++([agent])
        |> Enum.uniq()
        |> Enum.sort()

      join_msg = %{sender: "system", sender_kind: "system", body: "#{agent} joined", ts: ts}

      socket =
        socket
        |> assign(:members, members)
        |> assign(:messages, socket.assigns.messages ++ [join_msg])

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:typing, %{topic: topic, agent: agent, typing: typing}}, socket) do
    if topic == socket.assigns.active_topic do
      typing_agents = update_typing_agents(socket.assigns.typing_agents, agent, typing)
      {:noreply, assign(socket, :typing_agents, typing_agents)}
    else
      {:noreply, socket}
    end
  end

  # Agent status changes
  def handle_info({:status, name, status}, socket) do
    agent_statuses = Map.put(socket.assigns.agent_statuses, name, status)

    socket =
      socket
      |> assign(:agent_statuses, agent_statuses)
      |> maybe_remove_typing_agent(name, status)

    {:noreply, socket}
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

    {:noreply,
     assign(socket, :containers, upsert_container(socket.assigns.containers, container))}
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

  defp mention_profiles_json(agents) do
    agents
    |> Enum.map(fn agent ->
      {agent.name,
       %{
         name: agent.name,
         description: agent.description || "",
         personality: agent.personality || ""
       }}
    end)
    |> Map.new()
    |> Jason.encode!()
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

  defp status_color(:idle), do: "var(--ui-success)"
  defp status_color(:thinking), do: "var(--ui-warning)"
  defp status_color(_), do: "var(--ui-text-soft)"

  defp status_text(:idle), do: "idle"
  defp status_text(:thinking), do: "thinking"
  defp status_text(_), do: "offline"

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

  defp page_heading(nil), do: "Chat"
  defp page_heading(topic_name), do: active_topic_label(topic_name)

  defp active_topic_label(nil), do: "Select a topic"
  defp active_topic_label("dm:" <> _ = topic_name), do: dm_display_name(topic_name)
  defp active_topic_label(topic_name), do: "#" <> topic_name

  defp message_role_class(%{sender: "human"}), do: "ui-message--human"
  defp message_role_class(%{sender_kind: "system"}), do: "ui-message--system"
  defp message_role_class(_), do: "ui-message--agent"

  defp system_message?(%{sender_kind: "system"}), do: true
  defp system_message?(%{sender: "system"}), do: true
  defp system_message?(_), do: false

  defp sender_label("human"), do: "You"
  defp sender_label(sender), do: sender

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

  defp typing_summary([agent]), do: "#{agent} is typing"
  defp typing_summary([first, second]), do: "#{first}, #{second} are typing"
  defp typing_summary([first, second, third]), do: "#{first}, #{second}, and #{third} are typing"
  defp typing_summary(_agents), do: "Several agents are typing"

  defp update_typing_agents(typing_agents, agent, true) do
    typing_agents
    |> Kernel.++([agent])
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp update_typing_agents(typing_agents, agent, false) do
    Enum.reject(typing_agents, fn current -> current == agent end)
  end

  defp maybe_remove_typing_agent(socket, agent, :idle) do
    update(socket, :typing_agents, &Enum.reject(&1, fn current -> current == agent end))
  end

  defp maybe_remove_typing_agent(socket, _agent, _status), do: socket

  defp upsert_container(containers, container) do
    containers
    |> Enum.reject(fn current -> current.id == container.id end)
    |> Kernel.++([container])
  end
end
