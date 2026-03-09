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

    if connected?(socket) do
      subscribe_to_topics(all_topics)
      schedule_active_topic_refresh()
    end

    # Load containers from registry
    containers = load_containers()

    socket =
      socket
      |> assign(:topics, topics)
      |> assign(:dms, dms)
      |> assign(:active_topic, active_topic)
      |> assign(:messages, messages)
      |> assign(:topic_messages, initial_topic_messages(active_topic, messages))
      |> assign(:unread_counts, %{})
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
      |> assign(:aside_open, false)
      |> assign(:aside_tab, "members")
      |> allow_upload(:media,
        accept: ~w(.jpg .jpeg .png .gif .webp),
        max_entries: 4,
        max_file_size: 5_000_000
      )

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.app_shell
        current={:chat}
        title={page_heading(@active_topic)}
      >
        <:sidebar_extra>
          <div class="ui-chat-groups">
            <section class="ui-stack">
              <div class="ui-section-row">
                <p class="ui-section-label">Topics</p>
                <.button variant="ghost" size="sm" phx-click="toggle_create_topic" aria-label="New topic"><.icon name="hero-plus" class="size-4" /></.button>
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
                  </span>
                  <span
                    :if={unread_count(@unread_counts, topic.name) > 0}
                    id={"topic-unread-#{topic.name}"}
                    class="ui-pill"
                  >
                    {unread_count(@unread_counts, topic.name)}
                  </span>
                </button>
              </div>
            </section>

            <section class="ui-stack">
              <div class="ui-section-row">
                <p class="ui-section-label">Direct messages</p>
                <.button variant="ghost" size="sm" phx-click="toggle_new_dm" aria-label="New DM"><.icon name="hero-plus" class="size-4" /></.button>
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
                    <span class="ui-topic-link__meta">DM</span>
                  </span>
                  <span
                    :if={unread_count(@unread_counts, dm.name) > 0}
                    id={"dm-unread-#{dm.name}"}
                    class="ui-pill"
                  >
                    {unread_count(@unread_counts, dm.name)}
                  </span>
                </button>
              </div>
            </section>
          </div>
        </:sidebar_extra>

        <div class="ui-chat-screen">
          <div class={["ui-chat-layout", @aside_open && "ui-chat-layout--with-aside"]}>
            <section class="ui-chat-panel ui-surface">
              <div class="ui-chat-panel__header">
                <h2 class="ui-chat-panel__title">{active_topic_label(@active_topic)}</h2>

                <div class="flex items-center gap-2">
                  <button type="button" phx-click="toggle_aside" phx-value-tab="containers" :if={@containers != []} class={["ui-chat-meta ui-chat-meta--btn", @aside_open && @aside_tab == "containers" && "is-active"]}>
                    <.icon name="hero-cube" class="size-4" />
                    <span>{length(@containers)}</span>
                  </button>
                  <button type="button" phx-click="toggle_aside" phx-value-tab="members" class={["ui-chat-meta ui-chat-meta--btn", @aside_open && @aside_tab == "members" && "is-active"]}>
                    <.icon name="hero-user-group" class="size-4" />
                    <span>{length(@members)} members</span>
                  </button>
                </div>
              </div>

              <div id="messages" class="ui-chat-messages" phx-hook="ScrollBottom">
                <div :if={@active_topic && @messages == []} class="ui-empty" id="empty-chat-state">
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
                <span class="ui-typing-dots">
                  <span class="ui-typing-dots__dot"></span>
                  <span class="ui-typing-dots__dot"></span>
                  <span class="ui-typing-dots__dot"></span>
                </span>
                <span>{thinking_summary(@typing_agents)}</span>
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
                    placeholder={composer_placeholder(@active_topic)}
                    autocomplete="off"
                    spellcheck="true"
                    disabled={is_nil(@active_topic)}
                  ></textarea>

                  <div
                    class="ui-mention-menu hidden"
                    data-role="mention-menu"
                    aria-label="Agent mention suggestions"
                  >
                  </div>

                  <div :if={@uploads.media.entries != []} class="ui-upload-previews" style="padding: 0.5rem 0.95rem 0;">
                    <div :for={entry <- @uploads.media.entries} class="ui-upload-preview">
                      <.live_img_preview entry={entry} class="ui-upload-preview__thumb" />
                      <button
                        type="button"
                        phx-click="cancel_upload"
                        phx-value-ref={entry.ref}
                        class="ui-upload-preview__remove"
                        aria-label="Remove"
                      >
                        &times;
                      </button>
                    </div>
                  </div>

                  <div class="ui-chat-composer__toolbar">
                    <label class="ui-chat-composer__upload-btn" title="Attach image">
                      <.live_file_input upload={@uploads.media} class="hidden" />
                      <.icon name="hero-paper-clip" class="size-5" />
                    </label>
                    <.button id="chat-send-button" disabled={is_nil(@active_topic)}>Send</.button>
                  </div>
                </div>
              </form>
            </section>

            <aside :if={@aside_open} class="ui-chat-aside ui-surface">
              <div class="ui-chat-aside__header">
                <div class="ui-chat-aside__tabs">
                  <button type="button" phx-click="switch_aside_tab" phx-value-tab="members" class={["ui-chat-aside__tab", @aside_tab == "members" && "is-active"]}>
                    Members
                  </button>
                  <button type="button" phx-click="switch_aside_tab" phx-value-tab="containers" class={["ui-chat-aside__tab", @aside_tab == "containers" && "is-active"]}>
                    Containers
                  </button>
                </div>
                <button type="button" phx-click="close_aside" class="ui-chat-aside__close" aria-label="Close">
                  <.icon name="hero-x-mark" class="size-4" />
                </button>
              </div>

              <div :if={@aside_tab == "members"} class="ui-stack">
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
              </div>

              <div :if={@aside_tab == "containers"} class="ui-stack">
                <div :if={@containers == []} class="ui-empty">No active containers right now.</div>

                <.link
                  :for={container <- @containers}
                  navigate={~p"/containers/#{container.id}"}
                  class="ui-container-card-link"
                >
                  <div class="ui-card ui-stack">
                    <div>
                      <p class="text-sm text-[var(--ui-text-strong)]">
                        {container.task || "Running..."}
                      </p>
                      <div class="mt-1.5 flex items-center gap-2">
                        <span class="ui-pill">{container.agent || "container"}</span>
                        <span class="ui-container-card-meta">{short_container_id(container.id)}</span>
                      </div>
                    </div>
                  </div>
                </.link>
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
    {:noreply, switch_active_topic(socket, name)}
  end

  def handle_event("send_message", %{"text" => text}, socket) when text != "" do
    # Consume any uploaded images and get their URLs
    urls =
      consume_uploaded_entries(socket, :media, fn %{path: path}, entry ->
        data = File.read!(path)
        {:ok, url} = Hive.Media.save(data, entry.client_type)
        {:ok, url}
      end)

    img_md = Enum.map_join(urls, "\n", &"![image](#{&1})")
    full_text = if img_md == "", do: text, else: text <> "\n" <> img_md

    active_topic = socket.assigns.active_topic

    socket =
      case active_topic do
        nil ->
          socket

        "dm:" <> _ ->
          other = dm_other_party(active_topic, "human")
          {:ok, dm_name} = Hive.Topic.ensure_dm("human", other)
          :ok = Hive.Topic.post(dm_name, "human", full_text)
          switch_active_topic(socket, dm_name)

        _topic ->
          :ok = Hive.Topic.post(active_topic, "human", full_text)
          switch_active_topic(socket, active_topic)
      end

    {:noreply, assign(socket, :form_reset, socket.assigns.form_reset + 1)}
  end

  def handle_event("send_message", _params, socket) do
    # Handle case where text is empty but there are uploads
    if socket.assigns.uploads.media.entries != [] do
      urls =
        consume_uploaded_entries(socket, :media, fn %{path: path}, entry ->
          data = File.read!(path)
          {:ok, url} = Hive.Media.save(data, entry.client_type)
          {:ok, url}
        end)

      img_md = Enum.map_join(urls, "\n", &"![image](#{&1})")

      if img_md != "" do
        active_topic = socket.assigns.active_topic

        socket =
          case active_topic do
            nil ->
              socket

            "dm:" <> _ ->
              other = dm_other_party(active_topic, "human")
              {:ok, dm_name} = Hive.Topic.ensure_dm("human", other)
              :ok = Hive.Topic.post(dm_name, "human", img_md)
              switch_active_topic(socket, dm_name)

            _topic ->
              :ok = Hive.Topic.post(active_topic, "human", img_md)
              switch_active_topic(socket, active_topic)
          end

        {:noreply, assign(socket, :form_reset, socket.assigns.form_reset + 1)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :media, ref)}
  end

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

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hive.PubSub, "topic:#{dm_name}")
    end

    {messages, members} = load_topic_data(dm_name)

    socket =
      socket
      |> assign(:dms, dms)
      |> assign(:active_topic, dm_name)
      |> assign(:messages, messages)
      |> assign(:topic_messages, Map.put(socket.assigns.topic_messages, dm_name, messages))
      |> assign(:unread_counts, Map.delete(socket.assigns.unread_counts, dm_name))
      |> assign(:members, members)
      |> assign(:typing_agents, [])
      |> assign(:show_new_dm, false)

    {:noreply, socket}
  end

  def handle_event("toggle_aside", %{"tab" => tab}, socket) do
    if socket.assigns.aside_open && socket.assigns.aside_tab == tab do
      {:noreply, assign(socket, aside_open: false)}
    else
      {:noreply, assign(socket, aside_open: true, aside_tab: tab)}
    end
  end

  def handle_event("switch_aside_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, aside_tab: tab)}
  end

  def handle_event("close_aside", _params, socket) do
    {:noreply, assign(socket, aside_open: false)}
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
    new_msg = %{sender: msg.sender, sender_kind: msg.sender_kind, body: msg.body, ts: msg.ts}
    topic_messages = append_topic_message(socket.assigns.topic_messages, msg.topic, new_msg)

    socket =
      socket
      |> assign(:topic_messages, topic_messages)
      |> maybe_assign_active_messages(msg.topic, topic_messages)
      |> maybe_increment_unread(msg.topic)
      |> update(:typing_agents, &Enum.reject(&1, fn name -> name == msg.sender end))

    {:noreply, socket}
  end

  def handle_info({:member_joined, %{topic: topic, agent: agent, ts: ts}}, socket) do
    join_msg = %{sender: "system", sender_kind: "system", body: "#{agent} joined", ts: ts}
    topic_messages = append_topic_message(socket.assigns.topic_messages, topic, join_msg)

    if topic == socket.assigns.active_topic do
      members =
        socket.assigns.members
        |> Kernel.++([agent])
        |> Enum.uniq()
        |> Enum.sort()

      socket =
        socket
        |> assign(:members, members)
        |> assign(:topic_messages, topic_messages)
        |> assign(:messages, Map.fetch!(topic_messages, topic))

      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:topic_messages, topic_messages)
       |> maybe_increment_unread(topic)}
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

  def handle_info(:refresh_active_topic, socket) do
    if connected?(socket) do
      schedule_active_topic_refresh()
    end

    {:noreply, refresh_active_topic(socket)}
  end

  # Registry changes: new topic created
  def handle_info({:topic_created, name, _created_by}, socket) do
    # Reload topics from persistence
    all_topics = load_topics()
    topics = Enum.filter(all_topics, fn t -> t.type != "dm" end)
    dms = Enum.filter(all_topics, fn t -> t.type == "dm" end)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hive.PubSub, "topic:#{name}")
    end

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
     socket
     |> assign(:containers, upsert_container(socket.assigns.containers, container))
     |> assign(:aside_open, true)
     |> assign(:aside_tab, "containers")}
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
    messages = load_messages(topic_name)

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

  defp load_messages(topic_name) do
    topic_messages =
      try do
        topic_name
        |> Hive.Topic.recent(50)
        |> Enum.reverse()
      catch
        :exit, _ -> []
      end

    persisted_messages =
      case Hive.Persistence.get_messages(topic_name, 50) do
        {:ok, messages} -> Enum.map(messages, &with_sender_kind/1)
        _ -> []
      end

    merge_messages(persisted_messages, topic_messages)
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
    Calendar.strftime(dt, "%b %d %H:%M")
  end

  defp format_time(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} ->
        Calendar.strftime(dt, "%b %d %H:%M")

      _ ->
        case NaiveDateTime.from_iso8601(String.replace(ts, " ", "T")) do
          {:ok, ndt} -> Calendar.strftime(ndt, "%b %d %H:%M")
          _ -> ts
        end
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

  defp dm_display_name("dm:" <> _ = name) do
    other = dm_other_party(name, "human")
    "@#{other}"
  end

  defp dm_display_name(name), do: name

  defdelegate dm_other_party(dm_name, self_name), to: Hive.Util

  defp thinking_summary([agent]), do: "#{agent} is thinking"
  defp thinking_summary([first, second]), do: "#{first}, #{second} are thinking"
  defp thinking_summary([first, second, third]), do: "#{first}, #{second}, and #{third} are thinking"
  defp thinking_summary(_agents), do: "Several agents are thinking"

  defp composer_placeholder(nil), do: "Select a conversation..."
  defp composer_placeholder("dm:" <> _ = name), do: "Message @#{dm_other_party(name, "human")}..."
  defp composer_placeholder(topic), do: "Message ##{topic}..."

  defp short_container_id(id) when is_binary(id), do: String.slice(id, 0, 12)
  defp short_container_id(_), do: ""

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

  defp subscribe_to_topics(topics) do
    Enum.each(topics, fn topic ->
      Phoenix.PubSub.subscribe(Hive.PubSub, "topic:#{topic.name}")
    end)
  end

  defp subscribe_to_topic(socket, topic_name) do
    if connected?(socket) and topic_name do
      Phoenix.PubSub.subscribe(Hive.PubSub, "topic:#{topic_name}")
    end

    socket
  end

  defp switch_active_topic(socket, topic_name) do
    socket = subscribe_to_topic(socket, topic_name)

    {loaded_messages, members} = load_topic_data(topic_name)

    messages =
      visible_messages_for_topic(socket.assigns.topic_messages, topic_name, loaded_messages)

    socket
    |> assign(:active_topic, topic_name)
    |> assign(:messages, messages)
    |> assign(:topic_messages, Map.put(socket.assigns.topic_messages, topic_name, messages))
    |> assign(:unread_counts, Map.delete(socket.assigns.unread_counts, topic_name))
    |> assign(:members, members)
    |> assign(:typing_agents, [])
  end

  defp refresh_active_topic(%{assigns: %{active_topic: nil}} = socket), do: socket

  defp refresh_active_topic(socket) do
    active_topic = socket.assigns.active_topic
    {loaded_messages, members} = load_topic_data(active_topic)

    messages =
      visible_messages_for_topic(socket.assigns.topic_messages, active_topic, loaded_messages)

    socket
    |> assign(:messages, messages)
    |> assign(:topic_messages, Map.put(socket.assigns.topic_messages, active_topic, messages))
    |> assign(:members, members)
  end

  defp schedule_active_topic_refresh do
    Process.send_after(self(), :refresh_active_topic, 500)
  end

  defp initial_topic_messages(nil, _messages), do: %{}
  defp initial_topic_messages(topic, messages), do: %{topic => messages}

  defp visible_messages_for_topic(topic_messages, topic, loaded_messages) do
    topic_messages
    |> Map.get(topic, [])
    |> merge_messages(loaded_messages)
  end

  defp append_topic_message(topic_messages, topic, message) do
    existing = Map.get(topic_messages, topic, [])
    Map.put(topic_messages, topic, merge_messages(existing, [message]))
  end

  defp merge_messages(left, right) do
    (left ++ right)
    |> Enum.uniq_by(&message_identity/1)
    |> Enum.sort_by(&message_sort_key/1)
  end

  defp message_identity(message) do
    {
      Map.get(message, :sender),
      Map.get(message, :sender_kind),
      Map.get(message, :body),
      normalize_timestamp(Map.get(message, :ts))
    }
  end

  defp message_sort_key(message) do
    case normalize_timestamp(Map.get(message, :ts)) do
      %DateTime{} = dt -> {0, DateTime.to_unix(dt, :microsecond)}
      timestamp when is_binary(timestamp) -> {1, timestamp}
      timestamp -> {2, inspect(timestamp)}
    end
  end

  defp normalize_timestamp(%DateTime{} = timestamp), do: DateTime.truncate(timestamp, :second)

  defp normalize_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
      _ -> normalize_naive_timestamp(timestamp)
    end
  end

  defp normalize_timestamp(timestamp), do: timestamp

  defp normalize_naive_timestamp(timestamp) do
    timestamp
    |> String.replace(" ", "T")
    |> NaiveDateTime.from_iso8601()
    |> case do
      {:ok, naive_dt} -> DateTime.from_naive!(naive_dt, "Etc/UTC")
      _ -> timestamp
    end
  end

  defdelegate with_sender_kind(message), to: Hive.Util

  defp maybe_assign_active_messages(socket, topic, topic_messages) do
    if topic == socket.assigns.active_topic do
      assign(socket, :messages, Map.fetch!(topic_messages, topic))
    else
      socket
    end
  end

  defp maybe_increment_unread(socket, topic) do
    if topic == socket.assigns.active_topic do
      socket
    else
      update(socket, :unread_counts, fn unread_counts ->
        Map.update(unread_counts, topic, 1, &(&1 + 1))
      end)
    end
  end

  defp unread_count(unread_counts, topic), do: Map.get(unread_counts, topic, 0)
end
