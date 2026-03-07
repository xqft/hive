defmodule Hive.Agent do
  @moduledoc """
  GenServer managing a single AI agent and its Claude Code subprocess.

  Each agent is a long-lived process that:
  - Spawns a Node.js subprocess running the Claude Agent SDK
  - Pipes incoming messages (topics, DMs, system) to the SDK via stdin
  - Reads structured JSON responses from stdout (status, session, errors)
  - Handles SDK subprocess crashes with session resumption
  - Broadcasts status changes via PubSub

  Registered via `{:via, Registry, {Hive.AgentRegistry, name}}`.
  """

  use GenServer

  require Logger

  defstruct [
    :name,
    :description,
    :personality,
    :topics,
    :dms,
    :status,
    :sdk_port,
    :session_id,
    :mcp_secret
  ]

  # ---------------------------------------------------------------------------
  # HMAC secret derivation
  # ---------------------------------------------------------------------------

  @doc """
  Derive a deterministic HMAC secret for the agent's MCP bridge.

  Same secret every restart -- no need to persist separately.
  """
  def mcp_secret(agent_name) do
    app_secret = Application.get_env(:hive, :secret_key_base)

    :crypto.mac(:hmac, :sha256, app_secret, "mcp:#{agent_name}")
    |> Base.url_encode64(padding: false)
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Start an agent GenServer. Opts: name (required), description, personality."
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  @doc "Send a topic message to be piped to the agent's Claude Code subprocess."
  def deliver_message(agent_name, topic_name, sender, text) do
    GenServer.cast(via(agent_name), {:deliver_message, topic_name, sender, text})
  end

  @doc "Inject a system message (container completion, @mention invite, etc.)."
  def inject_message(agent_name, message) do
    GenServer.cast(via(agent_name), {:inject_message, message})
  end

  @doc "Get agent info map."
  def info(agent_name) do
    GenServer.call(via(agent_name), :info)
  end

  @doc "Get agent status (:idle or :thinking)."
  def status(agent_name) do
    GenServer.call(via(agent_name), :status)
  end

  @doc "Stop the agent gracefully."
  def stop(agent_name) do
    GenServer.stop(via(agent_name), :normal)
  end

  # ---------------------------------------------------------------------------
  # Registry helper
  # ---------------------------------------------------------------------------

  defp via(name), do: {:via, Registry, {Hive.AgentRegistry, name}}

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    description = Keyword.get(opts, :description, "")
    personality = Keyword.get(opts, :personality, "")

    secret = mcp_secret(name)

    # Load subscribed topics from persistence
    topics =
      case Hive.Persistence.get_subscriptions(name) do
        {:ok, topic_list} -> MapSet.new(topic_list)
        _ -> MapSet.new()
      end

    # Set up agent working directory
    agent_dir = agent_dir(name)
    File.mkdir_p!(agent_dir)
    File.mkdir_p!(Path.join(agent_dir, ".claude/skills"))

    # Write CLAUDE.md from personality
    write_claude_md(name, agent_dir, description, personality)

    # Write MCP config
    write_mcp_config(name, secret)

    # Start the SDK subprocess
    sdk_port = start_sdk_process(name, nil)

    # Subscribe to PubSub for topic messages and DMs that might be broadcast
    # (Topics deliver messages directly via send/2, but we subscribe for completeness)

    # Broadcast initial status
    Phoenix.PubSub.broadcast(Hive.PubSub, "agents", {:status, name, :idle})

    Logger.info("Agent #{name} started")

    state = %__MODULE__{
      name: name,
      description: description,
      personality: personality,
      topics: topics,
      dms: MapSet.new(),
      status: :idle,
      sdk_port: sdk_port,
      session_id: nil,
      mcp_secret: secret
    }

    {:ok, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Agent #{state.name} terminating: #{inspect(reason)}")

    # Close the SDK subprocess port
    if state.sdk_port do
      try do
        Port.close(state.sdk_port)
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  # -- Calls ----------------------------------------------------------------

  @impl true
  def handle_call(:info, _from, state) do
    info = %{
      name: state.name,
      description: state.description,
      status: state.status,
      topics: MapSet.to_list(state.topics),
      dms: MapSet.to_list(state.dms),
      session_id: state.session_id
    }

    {:reply, info, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  # -- Casts ----------------------------------------------------------------

  @impl true
  def handle_cast({:deliver_message, topic_name, sender, text}, state) do
    if sender != state.name do
      send_to_sdk(state, "[topic:#{topic_name}] #{sender}: #{text}")
    end

    {:noreply, state}
  end

  def handle_cast({:inject_message, message}, state) do
    send_to_sdk(state, "[system] #{message}")
    {:noreply, state}
  end

  # -- Info: messages from Topic GenServer ----------------------------------

  @impl true
  def handle_info({:topic_message, topic_name, sender, text}, state) do
    if sender != state.name do
      send_to_sdk(state, "[topic:#{topic_name}] #{sender}: #{text}")
    end

    {:noreply, state}
  end

  def handle_info({:dm_message, channel, sender, text}, state) do
    _ = channel

    if sender != state.name do
      send_to_sdk(state, "[dm:#{sender}] #{sender}: #{text}")
    end

    {:noreply, state}
  end

  def handle_info({:system_message, text}, state) do
    send_to_sdk(state, "[system] #{text}")
    {:noreply, state}
  end

  # -- Info: @mention invite from Topic ------------------------------------

  def handle_info({:mention_invite, topic_name, recent_messages}, state) do
    state = %{state | topics: MapSet.put(state.topics, topic_name)}

    context =
      recent_messages
      |> Enum.map(fn msg -> "  #{msg.sender}: #{msg.body}" end)
      |> Enum.join("\n")

    send_to_sdk(
      state,
      "[system] You were mentioned in topic:#{topic_name}. Recent messages:\n#{context}"
    )

    {:noreply, state}
  end

  # -- Info: SDK subprocess stdout -----------------------------------------

  def handle_info({port, {:data, {:eol, line}}}, %{sdk_port: port} = state) do
    case Jason.decode(line) do
      {:ok, %{"type" => "status", "status" => status}} when status in ["idle", "thinking"] ->
        new_status = String.to_existing_atom(status)
        Phoenix.PubSub.broadcast(Hive.PubSub, "agents", {:status, state.name, new_status})
        {:noreply, %{state | status: new_status}}

      {:ok, %{"type" => "session", "sessionId" => sid}} ->
        {:noreply, %{state | session_id: sid}}

      {:ok, %{"type" => "error", "message" => msg}} ->
        Logger.error("Agent #{state.name} SDK error: #{msg}")
        {:noreply, state}

      _ ->
        # Unrecognized line — log at debug level
        Logger.debug("Agent #{state.name} SDK unhandled output: #{inspect(line)}")
        {:noreply, state}
    end
  end

  # Partial line data (line mode can emit noeol chunks)
  def handle_info({port, {:data, {:noeol, _partial}}}, %{sdk_port: port} = state) do
    # Partial lines are buffered by the port driver; wait for :eol
    {:noreply, state}
  end

  # -- Info: SDK subprocess crash ------------------------------------------

  def handle_info({port, {:exit_status, code}}, %{sdk_port: port} = state) do
    Logger.warning(
      "Agent #{state.name} SDK process exited (code #{code}), restarting with session #{state.session_id}"
    )

    new_port = start_sdk_process(state.name, state.session_id)
    state = %{state | sdk_port: new_port}

    # Crash recovery: inject catch-up context from subscribed topics
    catch_up = build_catch_up(state)

    if catch_up != "" do
      send_to_sdk(
        state,
        "[system] You were restarted. Recent messages from your topics:\n#{catch_up}"
      )
    end

    {:noreply, state}
  end

  # Catch-all for unexpected port messages
  def handle_info({port, _}, %{sdk_port: port} = state) do
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Agent #{state.name} received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # SDK subprocess management
  # ---------------------------------------------------------------------------

  defp start_sdk_process(agent_name, session_id) do
    agent_dir = agent_dir(agent_name)
    File.mkdir_p!(agent_dir)

    mcp_config_path = mcp_config_path(agent_name)
    system_prompt_path = write_dynamic_context(agent_name, agent_dir)

    node = System.find_executable("node") || "node"
    sdk_script = resolve_sdk_path("sdk/hive_agent.js")

    args = [sdk_script, agent_name, mcp_config_path, agent_dir, system_prompt_path]
    args = if session_id, do: args ++ [session_id], else: args

    Port.open(
      {:spawn_executable, node},
      [
        :binary,
        :exit_status,
        args: args,
        env: [
          {~c"ANTHROPIC_API_KEY", String.to_charlist(api_key())}
        ],
        line: 4096
      ]
    )
  end

  # ---------------------------------------------------------------------------
  # MCP config
  # ---------------------------------------------------------------------------

  defp write_mcp_config(agent_name, secret) do
    mcp_servers = %{
      "hive" => %{
        "command" => "node",
        "args" => [mcp_bridge_script(), agent_name, secret, hive_url()]
      }
    }

    tool_filters = %{}

    # Add any assigned MCP servers from persistence
    {mcp_servers, tool_filters} =
      case Hive.Persistence.get_agent_mcp_servers(agent_name) do
        {:ok, servers} ->
          Enum.reduce(servers, {mcp_servers, tool_filters}, fn srv, {ms, tf} ->
            args = parse_json_field(srv.args, [])
            env = parse_json_field(srv.env, %{})

            server_config = %{"command" => srv.command, "args" => args}

            server_config =
              if env != %{}, do: Map.put(server_config, "env", env), else: server_config

            ms = Map.put(ms, srv.name, server_config)

            # Build tool filters from allowed_tools
            allowed = parse_json_field(srv.allowed_tools, [])

            tf =
              if allowed != [] do
                Map.put(tf, srv.name, allowed)
              else
                tf
              end

            {ms, tf}
          end)

        _ ->
          {mcp_servers, tool_filters}
      end

    config = %{
      "mcpServers" => mcp_servers,
      "toolFilters" => tool_filters
    }

    path = mcp_config_path(agent_name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(config, pretty: true))
    path
  end

  # ---------------------------------------------------------------------------
  # Dynamic context (system prompt — refreshed before each SDK turn)
  # ---------------------------------------------------------------------------

  defp write_dynamic_context(agent_name, agent_dir) do
    agents_section =
      case Hive.Persistence.get_agents() do
        {:ok, agents} ->
          agents
          |> Enum.map(fn a -> "- #{a.name} -- #{a.description}" end)
          |> Enum.join("\n")

        _ ->
          ""
      end

    topics_section =
      case Hive.Persistence.get_subscriptions(agent_name) do
        {:ok, topic_list} ->
          topic_list
          |> Enum.map(fn t -> "- #{t}" end)
          |> Enum.join("\n")

        _ ->
          ""
      end

    content = """
    ## Other Agents
    #{agents_section}

    ## Your Topics
    #{topics_section}
    """

    path = Path.join(agent_dir, ".hive_context.md")
    File.write!(path, content)
    path
  end

  # ---------------------------------------------------------------------------
  # CLAUDE.md generation
  # ---------------------------------------------------------------------------

  defp write_claude_md(agent_name, agent_dir, description, personality) do
    content = """
    # #{agent_name}

    #{description}

    ## Personality
    #{personality}

    ## Environment
    You are an agent in Hive, a multi-agent orchestration system.
    You interact with the world ONLY through your MCP tools.

    ### Communication
    - send_message: post to a topic you're subscribed to
    - send_dm: private message to another agent or "human"
    - create_topic: create a new chat group, optionally invite agents
    - join_topic / leave_topic: manage your subscriptions
    - get_topic_history: read past messages from a topic (doesn't bloat your context)

    ### Discovery
    - list_agents: see all agents, their descriptions, and current status
    - list_topics: see all topics, descriptions, and subscriber counts

    ### Execution
    - execute_in_container: launch an isolated Claude Code instance in Docker for
      code/file/bash/web tasks. Fire-and-forget -- you'll be notified when it's done.
      You can run up to 16 containers simultaneously.
    - check_execution: check recent output of a running container

    ### Self-Modification
    - write_skill: create or update your own skills (SKILL.md files). Skills persist
      across conversations and define knowledge/capabilities you want to retain.
    - read_skill: read one of your own skills.
    - delete_skill: delete one of your own skills.
    - write_claude_md: update your own CLAUDE.md (personality, objectives, rules).

    ## Rules
    - Be concise. Others read your messages.
    - Don't repeat what's already in the conversation.
    - Avoid conversational loops. If a topic thread is going back and forth without
      progress, stop responding and let others continue. Don't reply just to acknowledge
      -- only respond when you have new information, a question, or an actionable
      suggestion. If you've already made your point, stay silent.
    - For code execution, file operations, or web tasks, use execute_in_container.
    - You receive messages in real-time. Use get_topic_history only when you need older context.
    - When a container completes, you'll receive a [system] notification with the result.
    """

    path = Path.join(agent_dir, "CLAUDE.md")
    File.write!(path, content)
    path
  end

  # ---------------------------------------------------------------------------
  # Sending messages to SDK subprocess
  # ---------------------------------------------------------------------------

  defp send_to_sdk(state, message_text) do
    write_dynamic_context(state.name, agent_dir(state.name))

    try do
      Port.command(state.sdk_port, message_text <> "\n")
    rescue
      ArgumentError ->
        Logger.warning("Agent #{state.name} failed to send to SDK (port closed)")
    end
  end

  # ---------------------------------------------------------------------------
  # Crash recovery: build catch-up context from subscribed topics
  # ---------------------------------------------------------------------------

  defp build_catch_up(state) do
    state.topics
    |> MapSet.to_list()
    |> Enum.map(fn topic_name ->
      case Registry.lookup(Hive.TopicRegistry, topic_name) do
        [{_pid, _}] ->
          messages = Hive.Topic.recent(topic_name, 5)

          if messages != [] do
            header = "--- #{topic_name} ---"

            lines =
              messages
              |> Enum.map(fn msg -> "  #{msg.sender}: #{msg.body}" end)
              |> Enum.join("\n")

            header <> "\n" <> lines
          else
            nil
          end

        [] ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # ---------------------------------------------------------------------------
  # Path helpers
  # ---------------------------------------------------------------------------

  defp agent_dir(agent_name) do
    Path.join(["priv", "agents", agent_name]) |> Path.expand()
  end

  defp mcp_config_path(agent_name) do
    Path.join(agent_dir(agent_name), "mcp_config.json")
  end

  defp mcp_bridge_script do
    resolve_sdk_path("sdk/hive_mcp_bridge.js")
  end

  defp resolve_sdk_path(relative_path) do
    # Try Application.app_dir first (works in releases), fall back to cwd
    path =
      try do
        Path.join([Application.app_dir(:hive), "..", "..", relative_path]) |> Path.expand()
      rescue
        ArgumentError -> nil
      end

    if path && File.exists?(path) do
      path
    else
      Path.expand(relative_path)
    end
  end

  defp hive_url do
    port = Application.get_env(:hive, HiveWeb.Endpoint)[:http][:port] || 4000
    "http://localhost:#{port}"
  end

  defp api_key do
    Application.get_env(:hive, :anthropic_api_key) || ""
  end

  # ---------------------------------------------------------------------------
  # JSON field parsing helper
  # ---------------------------------------------------------------------------

  defp parse_json_field(nil, default), do: default

  defp parse_json_field(value, default) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, parsed} -> parsed
      _ -> default
    end
  end

  defp parse_json_field(value, _default), do: value
end
