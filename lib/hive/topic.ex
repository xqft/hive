defmodule Hive.Topic do
  @moduledoc """
  GenServer managing a single chat topic or DM channel.

  Each topic is registered via `{:via, Registry, {Hive.TopicRegistry, name}}`.
  Messages are kept in an in-memory ring buffer (last 50) and persisted via
  `Hive.Persistence`. Subscribers receive messages through their Agent GenServer
  and UI updates are broadcast via Phoenix PubSub.
  """

  use GenServer

  require Logger

  @max_buffer 50
  @mention_regex ~r/@([a-zA-Z0-9][a-zA-Z0-9_-]{0,30})\b/

  defstruct [
    :name,
    :description,
    :type,
    :created_by,
    messages: [],
    subscribers: MapSet.new()
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Start a Topic GenServer under the caller (or a supervisor)."
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  @doc "Post a message to the topic. Returns :ok."
  def post(topic_name, sender, text) do
    GenServer.call(via(topic_name), {:post, sender, text})
  end

  @doc "Join a topic. Returns `{:ok, recent_messages}` (last 5)."
  def join(topic_name, agent_name) do
    GenServer.call(via(topic_name), {:join, agent_name})
  end

  @doc "Leave a topic."
  def leave(topic_name, agent_name) do
    GenServer.call(via(topic_name), {:leave, agent_name})
  end

  @doc "Return the last N messages from the ring buffer."
  def recent(topic_name, n) do
    GenServer.call(via(topic_name), {:recent, n})
  end

  @doc "Return the MapSet of current subscriber names."
  def subscribers(topic_name) do
    GenServer.call(via(topic_name), :subscribers)
  end

  @doc "Return a map with topic metadata."
  def info(topic_name) do
    GenServer.call(via(topic_name), :info)
  end

  @doc "Canonical DM channel name for two agents (sorted alphabetically)."
  def dm_channel_name(agent_a, agent_b) do
    [a, b] = Enum.sort([agent_a, agent_b])
    "dm:#{a}:#{b}"
  end

  @doc """
  Ensure a DM channel exists between two agents.
  Creates the topic and subscribes both if it doesn't exist yet.
  """
  def ensure_dm(agent_a, agent_b) do
    name = dm_channel_name(agent_a, agent_b)

    case Registry.lookup(Hive.TopicRegistry, name) do
      [{_pid, _}] ->
        {:ok, name}

      [] ->
        persist(fn -> Hive.Persistence.create_topic(name, nil, "dm", agent_a) end)

        {:ok, _pid} =
          DynamicSupervisor.start_child(
            Hive.TopicSup,
            {__MODULE__, name: name, description: nil, type: :dm, created_by: agent_a}
          )

        # Subscribe both parties (persistence + in-memory)
        join(name, agent_a)
        join(name, agent_b)

        {:ok, name}
    end
  end

  # ---------------------------------------------------------------------------
  # Registry helper
  # ---------------------------------------------------------------------------

  defp via(name), do: {:via, Registry, {Hive.TopicRegistry, name}}

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    description = Keyword.get(opts, :description)
    type = Keyword.get(opts, :type, :topic)
    created_by = Keyword.get(opts, :created_by)

    # Load persisted state. Persistence may not be running (e.g. in tests),
    # so we gracefully fall back to empty defaults.
    subscribers =
      case persist(fn -> Hive.Persistence.get_topic_subscribers(name) end) do
        {:ok, list} when is_list(list) -> MapSet.new(list)
        _ -> MapSet.new()
      end

    messages =
      case persist(fn -> Hive.Persistence.get_messages(name, @max_buffer) end) do
        {:ok, list} when is_list(list) ->
          list
          |> Enum.map(&with_sender_kind/1)
          |> Enum.reverse()

        _ ->
          []
      end

    state = %__MODULE__{
      name: name,
      description: description,
      type: type,
      created_by: created_by,
      subscribers: subscribers,
      messages: messages
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:post, sender, text}, _from, state) do
    ts = DateTime.utc_now()
    msg = %{sender: sender, sender_kind: sender_kind(sender), body: text, ts: ts}

    # Persist
    persist(fn -> Hive.Persistence.write_message(state.name, sender, text) end)

    # Update ring buffer
    messages = Enum.take([msg | state.messages], @max_buffer)

    # Broadcast to PubSub for UI
    safe_broadcast(
      "topic:#{state.name}",
      {:message,
       %{topic: state.name, sender: sender, sender_kind: msg.sender_kind, body: text, ts: ts}}
    )

    # Deliver to subscriber Agent GenServers (skip self)
    event_name = if state.type == :dm, do: :dm_message, else: :topic_message

    for subscriber <- state.subscribers, subscriber != sender do
      case Registry.lookup(Hive.AgentRegistry, subscriber) do
        [{pid, _}] -> send(pid, {event_name, state.name, msg})
        [] -> :ok
      end
    end

    state = %{state | messages: messages}

    # Handle @mentions -- auto-invite non-subscribers
    state = handle_mentions(state, text)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:join, agent_name}, _from, state) do
    {state, joined?} = add_subscriber(state, agent_name)

    if joined? do
      safe_broadcast(
        "topic:#{state.name}",
        {:member_joined, %{topic: state.name, agent: agent_name, ts: DateTime.utc_now()}}
      )
    end

    recent = Enum.take(state.messages, 5)
    {:reply, {:ok, recent}, state}
  end

  @impl true
  def handle_call({:leave, agent_name}, _from, state) do
    state = %{state | subscribers: MapSet.delete(state.subscribers, agent_name)}

    persist(fn -> Hive.Persistence.unsubscribe(state.name, agent_name) end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:recent, n}, _from, state) do
    {:reply, Enum.take(state.messages, n), state}
  end

  @impl true
  def handle_call(:subscribers, _from, state) do
    {:reply, state.subscribers, state}
  end

  @impl true
  def handle_call(:info, _from, state) do
    info = %{
      name: state.name,
      description: state.description,
      type: state.type,
      created_by: state.created_by,
      subscriber_count: MapSet.size(state.subscribers),
      message_count: length(state.messages)
    }

    {:reply, info, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Safely call a Persistence function, catching any crash when Persistence
  # is not started or unavailable.
  defp persist(fun) do
    fun.()
  rescue
    e ->
      Logger.warning("Persistence unavailable: #{inspect(e)}")
      :error
  catch
    :exit, reason ->
      Logger.warning("Persistence unavailable: #{inspect(reason)}")
      :error
  end

  defp handle_mentions(state, text) do
    mentioned =
      @mention_regex
      |> Regex.scan(text)
      |> Enum.map(fn [_full, name] -> name end)
      |> Enum.uniq()

    Enum.reduce(mentioned, state, fn agent_name, acc ->
      if MapSet.member?(acc.subscribers, agent_name) do
        acc
      else
        {acc, _joined?} = add_subscriber(acc, agent_name)

        safe_broadcast(
          "topic:#{acc.name}",
          {:member_joined, %{topic: acc.name, agent: agent_name, ts: DateTime.utc_now()}}
        )

        # Send last 5 messages as context to the mentioned agent
        context = Enum.take(acc.messages, 5)

        case Registry.lookup(Hive.AgentRegistry, agent_name) do
          [{pid, _}] ->
            send(pid, {:mention_invite, acc.name, context})

          [] ->
            :ok
        end

        acc
      end
    end)
  end

  defp add_subscriber(state, agent_name) do
    if MapSet.member?(state.subscribers, agent_name) do
      {state, false}
    else
      next_state = %{state | subscribers: MapSet.put(state.subscribers, agent_name)}
      persist(fn -> Hive.Persistence.subscribe(next_state.name, agent_name) end)
      {next_state, true}
    end
  end

  defdelegate safe_broadcast(topic, payload), to: Hive.Util
  defdelegate sender_kind(sender), to: Hive.Util
  defdelegate with_sender_kind(msg), to: Hive.Util
end
