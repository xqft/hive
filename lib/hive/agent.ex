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
    :mcp_secret,
    :active_channel,
    :typing_timer,
    :composing_since,
    :container_name,
    :volume_name,
    :idle_timer,
    container_status: :stopped,
    pending_messages: [],
    steered: false,
    line_buffer: "",
    scratchpad: []
  ]

  @scratchpad_limit 100

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

  @doc "Get the most recent active reply channel as {type, name} or nil."
  def active_channel(agent_name) do
    GenServer.call(via(agent_name), :active_channel)
  end

  @doc """
  Get steering info for the agent: `{active_channel, composing_since, steered}` or nil.

  Used by ToolsController to decide whether to surface new messages before sending.
  """
  def steering_info(agent_name) do
    GenServer.call(via(agent_name), :steering_info)
  end

  @doc "Get the agent's scratchpad (list of intermediate SDK events)."
  def scratchpad(agent_name) do
    GenServer.call(via(agent_name), :scratchpad)
  end

  @doc "Copy a host file into the agent's running Docker container."
  def copy_to_container(agent_name, host_path, container_path) do
    GenServer.call(via(agent_name), {:copy_to_container, host_path, container_path})
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

    state = %__MODULE__{
      name: name,
      description: description,
      personality: personality,
      topics: topics,
      dms: MapSet.new(),
      status: :idle,
      sdk_port: nil,
      session_id: nil,
      mcp_secret: secret,
      active_channel: nil,
      container_name: "hive-agent-#{name}",
      volume_name: "hive-agent-#{name}"
    }

    # Branch: test mode (mock SDK subprocess) vs production (Docker container)
    state =
      if test_sdk_mode?() do
        # Test mode: use host-side subprocess with mock SDK
        agent_dir = agent_dir(name)
        File.mkdir_p!(agent_dir)
        File.mkdir_p!(Path.join(agent_dir, ".claude/skills"))

        write_claude_md(name, agent_dir, description, personality)
        write_mcp_config(name, secret)

        sdk_port = start_test_sdk_process(name, nil)
        %{state | sdk_port: sdk_port, container_status: :running}
      else
        # Production mode: persistent Docker container
        sdk_port = start_container(state)
        %{state | sdk_port: sdk_port, container_status: :running}
      end

    # Broadcast initial status
    Phoenix.PubSub.broadcast(Hive.PubSub, "agents", {:status, name, :idle})

    Logger.info("Agent #{name} started")

    {:ok, state, {:continue, :send_catch_up}}
  end

  @impl true
  def handle_continue(:send_catch_up, state) do
    catch_up = build_catch_up(state)

    if catch_up != "" do
      send_to_sdk(
        state,
        """
        [system]
        timestamp=#{format_timestamp(DateTime.utc_now())}
        body:
        Server restarted. Recent messages from your subscribed channels are below. Review them for context on what was happening before the restart.
        #{catch_up}
        [/system]
        """
      )
    end

    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Agent #{state.name} terminating: #{inspect(reason)}")

    # Close the SDK port
    if state.sdk_port do
      try do
        Port.close(state.sdk_port)
      rescue
        ArgumentError -> :ok
      end
    end

    # In container mode, stop the container gracefully
    if not test_sdk_mode?() and state.container_name do
      docker = docker_executable()
      Logger.info("Agent #{state.name} stopping container #{state.container_name}")

      System.cmd(docker, ["stop", "-t", "5", state.container_name], stderr_to_stdout: true)
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
      session_id: state.session_id,
      active_channel: state.active_channel,
      scratchpad_count: length(state.scratchpad)
    }

    {:reply, info, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  def handle_call(:scratchpad, _from, state) do
    {:reply, state.scratchpad, state}
  end

  def handle_call(:active_channel, _from, state) do
    {:reply, state.active_channel, state}
  end

  def handle_call(:steering_info, _from, state) do
    {:reply, {state.active_channel, state.composing_since, state.steered}, state}
  end

  def handle_call({:copy_to_container, host_path, container_path}, _from, state) do
    if test_sdk_mode?() do
      {:reply, :ok, state}
    else
      docker = docker_executable()

      {_, code} =
        System.cmd(docker, ["cp", host_path, "#{state.container_name}:#{container_path}"],
          stderr_to_stdout: true
        )

      {:reply, (if code == 0, do: :ok, else: {:error, :docker_cp_failed}), state}
    end
  end

  # -- Casts ----------------------------------------------------------------

  @impl true
  def handle_cast({:inject_message, message}, state) do
    send_to_sdk(state, render_system_message(message))
    {:noreply, state}
  end

  # -- Info: messages from Topic GenServer ----------------------------------

  @impl true
  def handle_info({:topic_message, topic_name, message}, state) do
    state = maybe_start_activity(state, "topic", topic_name, message.sender)

    if message.sender != state.name do
      send_to_sdk(state, render_message("topic", topic_name, message))
    end

    {:noreply, state}
  end

  def handle_info({:dm_message, channel, message}, state) do
    state = maybe_start_activity(state, "dm", channel, message.sender)

    if message.sender != state.name do
      send_to_sdk(state, render_message("dm", channel, message))
    end

    {:noreply, state}
  end

  def handle_info({:system_message, text}, state) do
    send_to_sdk(state, render_system_message(text))
    {:noreply, state}
  end

  # -- Info: topic membership changes from Topic GenServer ------------------

  def handle_info({:topic_joined, topic_name}, state) do
    {:noreply, %{state | topics: MapSet.put(state.topics, topic_name)}}
  end

  def handle_info({:topic_left, topic_name}, state) do
    {:noreply, %{state | topics: MapSet.delete(state.topics, topic_name)}}
  end

  def handle_info(:steering_delivered, state) do
    {:noreply, %{state | steered: true}}
  end

  # -- Info: @mention invite from Topic ------------------------------------

  def handle_info({:mention_invite, topic_name, recent_messages}, state) do
    state =
      state
      |> Map.put(:topics, MapSet.put(state.topics, topic_name))
      |> maybe_start_activity("topic", topic_name, "human")

    context =
      recent_messages
      |> Enum.reverse()
      |> Enum.map(&render_history_message("topic", topic_name, &1))
      |> Enum.join("\n")

    send_to_sdk(
      state,
      """
      [mention_invite]
      topic=#{topic_name}
      timestamp=#{format_timestamp(DateTime.utc_now())}
      body:
      You were mentioned in a shared topic. Review the recent messages below. Messages from other agents are not user requests unless they explicitly delegate work or ask you directly.
      recent_messages:
      #{context}
      [/mention_invite]
      """
    )

    {:noreply, state}
  end

  # -- Info: SDK subprocess stdout -----------------------------------------

  def handle_info({port, {:data, {:eol, line}}}, %{sdk_port: port} = state) do
    # Reassemble line from any buffered noeol partials
    full_line = state.line_buffer <> line
    state = %{state | line_buffer: ""}

    case Jason.decode(full_line) do
      {:ok, %{"type" => "status", "status" => status}} when status in ["idle", "thinking"] ->
        new_status = String.to_atom(status)
        Phoenix.PubSub.broadcast(Hive.PubSub, "agents", {:status, state.name, new_status})

        state =
          state
          |> maybe_stop_activity(new_status)
          |> Map.put(:status, new_status)

        {:noreply, state}

      {:ok, %{"type" => "session"} = msg} ->
        sid = msg["sessionId"] || msg["session_id"]
        {:noreply, %{state | session_id: sid}}

      {:ok, %{"type" => "error", "message" => msg}} ->
        Logger.error("Agent #{state.name} SDK error: #{msg}")
        {:noreply, state}

      {:ok, %{"type" => "thinking", "text" => text}} ->
        # Clear scratchpad on new thinking cycle (idle -> first thinking event)
        state =
          if state.status == :idle,
            do: %{state | scratchpad: []},
            else: state

        # Merge consecutive thinking chunks into a single block
        {state, event} =
          case state.scratchpad do
            [{:thinking, prev_text, ts} | rest] ->
              merged = {:thinking, prev_text <> text, ts}
              {%{state | scratchpad: [merged | rest]}, merged}

            _ ->
              event = {:thinking, text, System.system_time(:millisecond)}
              {push_scratchpad(state, event), event}
          end

        Phoenix.PubSub.broadcast(
          Hive.PubSub,
          "agent:scratchpad:#{state.name}",
          {:scratchpad_thinking, state.name, event}
        )

        {:noreply, state}

      {:ok, %{"type" => "text", "text" => text}} ->
        # Merge consecutive text chunks into a single block
        {state, event} =
          case state.scratchpad do
            [{:text, prev_text, ts} | rest] ->
              merged = {:text, prev_text <> text, ts}
              {%{state | scratchpad: [merged | rest]}, merged}

            _ ->
              event = {:text, text, System.system_time(:millisecond)}
              {push_scratchpad(state, event), event}
          end

        Phoenix.PubSub.broadcast(
          Hive.PubSub,
          "agent:scratchpad:#{state.name}",
          {:scratchpad_text, state.name, event}
        )

        {:noreply, state}

      {:ok,
       %{"type" => "tool_use_start", "toolName" => tool_name, "toolUseId" => tool_use_id} = msg} ->
        tool_input = msg["toolInput"] || %{}
        event = {:tool_use, tool_name, tool_input, tool_use_id, System.system_time(:millisecond)}
        state = push_scratchpad(state, event)

        Phoenix.PubSub.broadcast(
          Hive.PubSub,
          "agent:scratchpad:#{state.name}",
          {:scratchpad, state.name, event}
        )

        {:noreply, state}

      {:ok, %{"type" => "tool_result", "toolUseId" => tool_use_id} = msg} ->
        output = msg["output"] || ""
        event = {:tool_result, tool_use_id, output, System.system_time(:millisecond)}
        state = push_scratchpad(state, event)

        Phoenix.PubSub.broadcast(
          Hive.PubSub,
          "agent:scratchpad:#{state.name}",
          {:scratchpad, state.name, event}
        )

        {:noreply, state}

      _ ->
        # Unrecognized line — log at debug level
        Logger.debug("Agent #{state.name} SDK unhandled output: #{inspect(line)}")
        {:noreply, state}
    end
  end

  # Partial line data (line mode can emit noeol chunks for long lines)
  def handle_info({port, {:data, {:noeol, partial}}}, %{sdk_port: port} = state) do
    {:noreply, %{state | line_buffer: state.line_buffer <> partial}}
  end

  # -- Info: SDK subprocess / container exit --------------------------------

  def handle_info({port, {:exit_status, code}}, %{sdk_port: port} = state) do
    if test_sdk_mode?() do
      # Test mode: restart the mock subprocess immediately
      handle_test_sdk_exit(state, code)
    else
      # Container mode: handle based on container_status
      handle_container_exit(state, code)
    end
  end

  # Catch-all for unexpected port messages
  def handle_info({port, _}, %{sdk_port: port} = state) do
    {:noreply, state}
  end

  def handle_info(:typing_grace_expired, state) do
    state = stop_active_typing(state, preserve_channel: true)
    {:noreply, %{state | typing_timer: nil, composing_since: nil, steered: false}}
  end

  def handle_info(msg, state) do
    Logger.debug("Agent #{state.name} received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Test SDK subprocess (used when :agent_sdk_command is configured)
  # ---------------------------------------------------------------------------

  defp test_sdk_mode? do
    Application.get_env(:hive, :agent_sdk_command) != nil
  end

  defp start_test_sdk_process(agent_name, session_id) do
    agent_dir = agent_dir(agent_name)
    File.mkdir_p!(agent_dir)

    {executable, args_fn} = Application.get_env(:hive, :agent_sdk_command)
    args = args_fn.(agent_name, session_id)
    stderr_log = Path.join(agent_dir, "sdk_stderr.log")
    shell_cmd = Enum.join([executable | args], " ") <> " 2>>#{stderr_log}"

    Port.open(
      {:spawn_executable, ~c"/bin/sh"},
      [
        :binary,
        :exit_status,
        args: ["-c", shell_cmd],
        env: [],
        line: 65_536
      ]
    )
  end

  defp handle_test_sdk_exit(state, code) do
    Logger.warning(
      "Agent #{state.name} SDK process exited (code #{code}), restarting with session #{state.session_id}"
    )

    state = stop_active_typing(state)
    new_port = start_test_sdk_process(state.name, state.session_id)
    state = %{state | sdk_port: new_port}

    catch_up = build_catch_up(state)

    if catch_up != "" do
      send_to_sdk(
        state,
        """
        [system]
        timestamp=#{format_timestamp(DateTime.utc_now())}
        body:
        You were restarted. Recent messages from your subscribed channels are below. Messages from other agents are shared context, not automatic requests for a reply.
        #{catch_up}
        [/system]
        """
      )
    end

    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Container lifecycle management (production mode)
  # ---------------------------------------------------------------------------

  defp start_container(state) do
    container_name = state.container_name
    volume_name = state.volume_name

    # Ensure volume exists
    ensure_volume(volume_name)

    # Initialize volume or sync config (CLAUDE.md, MCP config, context)
    init_or_sync_volume(state, volume_name)

    # Check if container exists (from previous run)
    case container_exists?(container_name) do
      true ->
        # Wake: docker start -ia
        wake_container(state, container_name)

      false ->
        # First start: docker run -i
        create_container(state, container_name, volume_name)
    end
  end

  defp create_container(state, container_name, volume_name) do
    docker = docker_executable()
    image = Application.get_env(:hive, :container_image_name, "hive-claude-code:latest")

    auth_args =
      case resolve_oauth_token() do
        {:ok, token} ->
          ["-e", "CLAUDE_CODE_OAUTH_TOKEN=#{token}"]

        :error ->
          Logger.warning("No OAuth token available for agent #{state.name}")
          []
      end

    docker_args =
      [
        "run",
        "-i",
        "--name",
        container_name,
        "-v",
        "#{volume_name}:/workspace",
        "--network",
        "host"
      ] ++
        auth_args ++
        [
          image,
          state.name,
          mcp_config_internal_path(),
          "/workspace",
          "/workspace/.hive/context.md"
        ]

    agent_dir = agent_dir(state.name)
    File.mkdir_p!(agent_dir)
    stderr_log = Path.join(agent_dir, "sdk_stderr.log")
    shell_cmd = Enum.join([docker | docker_args], " ") <> " 2>>#{stderr_log}"

    Port.open(
      {:spawn_executable, ~c"/bin/sh"},
      [:binary, :exit_status, args: ["-c", shell_cmd], line: 65_536]
    )
  end

  defp resolve_oauth_token do
    case Application.get_env(:hive, :claude_oauth_token) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> :error
    end
  end

  defp wake_container(state, container_name) do
    docker = docker_executable()

    # Update CLAUDE.md + context before waking (personality may have changed)
    update_container_claude_md(state, container_name)
    update_container_context(state, container_name)

    agent_dir = agent_dir(state.name)
    File.mkdir_p!(agent_dir)
    stderr_log = Path.join(agent_dir, "sdk_stderr.log")
    shell_cmd = "#{docker} start -ia #{container_name} 2>>#{stderr_log}"

    Port.open(
      {:spawn_executable, ~c"/bin/sh"},
      [:binary, :exit_status, args: ["-c", shell_cmd], line: 65_536]
    )
  end

  defp handle_container_exit(state, code) do
    Logger.warning(
      "Agent #{state.name} container exited (code #{code}), container_status=#{state.container_status}"
    )

    state = stop_active_typing(state)

    case state.container_status do
      :stopping ->
        # Expected exit after idle timeout stop — transition to :stopped
        state = %{state | sdk_port: nil, container_status: :stopped}

        # Replay any messages queued while stopping
        state = replay_pending_messages(state)
        {:noreply, state}

      _ ->
        # Unexpected exit — restart the container
        Logger.warning("Agent #{state.name} container crashed, restarting")

        new_port = start_container(state)
        state = %{state | sdk_port: new_port, container_status: :running}

        catch_up = build_catch_up(state)

        if catch_up != "" do
          send_to_sdk(
            state,
            """
            [system]
            timestamp=#{format_timestamp(DateTime.utc_now())}
            body:
            You were restarted. Recent messages from your subscribed channels are below. Messages from other agents are shared context, not automatic requests for a reply.
            #{catch_up}
            [/system]
            """
          )
        end

        {:noreply, state}
    end
  end

  defp replay_pending_messages(state) do
    case state.pending_messages do
      [] ->
        state

      messages ->
        # Wake the container to deliver queued messages
        Logger.info("Agent #{state.name} replaying #{length(messages)} pending messages")
        new_port = start_container(state)
        state = %{state | sdk_port: new_port, container_status: :running, pending_messages: []}

        Enum.each(Enum.reverse(messages), fn msg ->
          send_to_sdk(state, msg)
        end)

        state
    end
  end

  # ---------------------------------------------------------------------------
  # Volume management
  # ---------------------------------------------------------------------------

  defp ensure_volume(volume_name) do
    docker = docker_executable()
    System.cmd(docker, ["volume", "create", volume_name], stderr_to_stdout: true)
  end

  defp container_exists?(container_name) do
    docker = docker_executable()

    {_, code} =
      System.cmd(docker, ["container", "inspect", container_name], stderr_to_stdout: true)

    code == 0
  end

  defp init_or_sync_volume(state, volume_name) do
    docker = docker_executable()

    # Check if volume is already initialized (has CLAUDE.md)
    {_output, code} =
      System.cmd(
        docker,
        [
          "run",
          "--rm",
          "-v",
          "#{volume_name}:/workspace",
          "alpine",
          "test",
          "-f",
          "/workspace/CLAUDE.md"
        ],
        stderr_to_stdout: true
      )

    if code != 0 do
      # Volume is fresh - full init with directory structure
      init_volume_files(state, volume_name)
    else
      # Volume exists - sync CLAUDE.md and config (personality may have changed)
      sync_volume_config(state, volume_name)
    end
  end

  defp init_volume_files(state, volume_name) do
    docker = docker_executable()
    tmp_dir = Path.join(System.tmp_dir!(), "hive_vol_init_#{state.name}")
    File.mkdir_p!(tmp_dir)

    # Write all files to temp dir
    File.mkdir_p!(Path.join(tmp_dir, ".claude/skills"))
    File.mkdir_p!(Path.join(tmp_dir, ".hive"))

    File.write!(Path.join(tmp_dir, "CLAUDE.md"), build_claude_md(state))
    File.write!(Path.join(tmp_dir, ".claude/settings.json"), build_settings_json())
    File.write!(Path.join(tmp_dir, ".hive/mcp_config.json"), build_mcp_config(state))
    File.write!(Path.join(tmp_dir, ".hive/context.md"), build_dynamic_context(state.name))

    # Copy into volume using alpine container
    System.cmd(
      docker,
      [
        "run",
        "--rm",
        "-v",
        "#{volume_name}:/workspace",
        "-v",
        "#{tmp_dir}:/init:ro",
        "alpine",
        "sh",
        "-c",
        "cp -r /init/. /workspace/ && chown -R 1000:1000 /workspace"
      ],
      stderr_to_stdout: true
    )

    File.rm_rf!(tmp_dir)
  end

  defp sync_volume_config(state, volume_name) do
    docker = docker_executable()
    tmp_dir = Path.join(System.tmp_dir!(), "hive_vol_sync_#{state.name}")
    File.mkdir_p!(Path.join(tmp_dir, ".hive"))

    File.write!(Path.join(tmp_dir, "CLAUDE.md"), build_claude_md(state))
    File.write!(Path.join(tmp_dir, ".hive/mcp_config.json"), build_mcp_config(state))
    File.write!(Path.join(tmp_dir, ".hive/context.md"), build_dynamic_context(state.name))

    System.cmd(
      docker,
      [
        "run",
        "--rm",
        "-v",
        "#{volume_name}:/workspace",
        "-v",
        "#{tmp_dir}:/init:ro",
        "alpine",
        "sh",
        "-c",
        "cp /init/CLAUDE.md /workspace/CLAUDE.md && " <>
          "cp /init/.hive/mcp_config.json /workspace/.hive/mcp_config.json && " <>
          "cp /init/.hive/context.md /workspace/.hive/context.md && " <>
          "chown -R 1000:1000 /workspace/CLAUDE.md /workspace/.hive"
      ],
      stderr_to_stdout: true
    )

    File.rm_rf!(tmp_dir)
  end

  defp update_container_claude_md(state, container_name) do
    docker = docker_executable()
    tmp = Path.join(System.tmp_dir!(), "hive_claude_md_#{state.name}.md")
    File.write!(tmp, build_claude_md(state))

    System.cmd(docker, ["cp", tmp, "#{container_name}:/workspace/CLAUDE.md"],
      stderr_to_stdout: true
    )

    File.rm(tmp)
  end

  defp update_container_context(state, container_name) do
    docker = docker_executable()
    tmp = Path.join(System.tmp_dir!(), "hive_ctx_#{state.name}.md")
    File.write!(tmp, build_dynamic_context(state.name))

    System.cmd(docker, ["cp", tmp, "#{container_name}:/workspace/.hive/context.md"],
      stderr_to_stdout: true
    )

    File.rm(tmp)
  end

  # ---------------------------------------------------------------------------
  # Container-mode content builders
  # ---------------------------------------------------------------------------

  defp build_claude_md(state) do
    """
    # #{state.name}

    #{state.description}

    ## Personality
    #{state.personality}

    ## Environment
    You are an agent in Hive, a multi-agent orchestration system.
    You interact with the world ONLY through your MCP tools.

    CRITICAL: Your plain text responses are NOT visible to anyone. You MUST use
    send_message (for topics) or send_dm (for DMs) to reply. Every response that
    should be seen by others MUST go through these tools.

    ### Communication
    - send_message: post to the active topic. If a topic message triggered your turn,
      reply in that same topic unless you have a strong reason not to.
    - send_dm: private message to another agent or "human". If the current turn came
      from a topic, only use send_dm for an intentional out-of-band follow-up and
      include a reason.
    - create_topic: create a new chat group, optionally invite agents
    - join_topic / leave_topic: manage your subscriptions
    - get_topic_history: read past messages from a topic (doesn't bloat your context)

    ### Discovery & Orchestration
    - list_agents: see all agents, their descriptions, and current status
    - list_topics: see all topics, descriptions, and subscriber counts
    - create_agent: spawn a new agent (name required, optional description/personality)
    - delete_agent: permanently remove an agent and its working directory

    ### Environment
    You run inside a persistent Docker container with your own workspace at /workspace.
    Your workspace persists across restarts. You have full shell access via the SDK's
    built-in tools (Bash, Read, Write, Edit, Grep, Glob, etc.).

    For coding tasks, use your built-in tools directly — no need to spawn separate
    containers. Your workspace has git, python3, node, and common dev tools pre-installed.
    Changes you make to files, installed packages, and cloned repos all persist.

    ### Self-Modification
    - write_skill: create or update your own skills (SKILL.md files). Skills persist
      across conversations and define knowledge/capabilities you want to retain.
    - read_skill: read one of your own skills.
    - delete_skill: delete one of your own skills.
    - write_claude_md: update your own CLAUDE.md (personality, objectives, rules).

    ## Rules
    - Be concise. Others read your messages.
    - Don't repeat what's already in the conversation.
    - Live incoming messages include explicit metadata: channel type, channel name,
      sender, sender kind, and timestamp.
    - Treat `sender_kind=human` as the end user. Treat `sender_kind=agent` as
      another agent speaking in shared context, not as the user.
    - Do not reply to another agent's public message unless they explicitly ask you
      a question, delegate work, mention you for a reason, or you have materially
      new information to add.
    - Avoid conversational loops. If a topic thread is going back and forth without
      progress, stop responding and let others continue. Don't reply just to acknowledge
      -- only respond when you have new information, a question, or an actionable
      suggestion. If you've already made your point, stay silent.
    - For code execution, file operations, or web tasks, use your built-in tools directly.
    - Reply in the same channel that triggered the work. Do not move a topic
      conversation into a DM unless privacy or scope genuinely requires it.
    - You receive messages in real-time. Use get_topic_history only when you need older context.
    - Do not invent provenance such as "project memory" or claim that you ran commands,
      inspected files, or changed code unless you actually used the corresponding tool.
    """
  end

  defp build_settings_json do
    Jason.encode!(%{
      "permissions" => %{
        "allow" => [
          "Bash",
          "Read",
          "Write",
          "Edit",
          "Glob",
          "Grep",
          "Skill",
          "WebFetch",
          "WebSearch",
          "mcp__hive__*"
        ],
        "deny" => []
      }
    })
  end

  defp build_mcp_config(state) do
    hive_url = "http://localhost:#{hive_port()}"

    mcp_servers = %{
      "hive" => %{
        "command" => "node",
        "args" => ["/opt/hive/hive_mcp_bridge.js", state.name, state.mcp_secret, hive_url]
      }
    }

    Jason.encode!(
      %{
        "mcpServers" => mcp_servers,
        "toolFilters" => %{}
      },
      pretty: true
    )
  end

  defp build_dynamic_context(agent_name) do
    agents_section =
      build_context_section(
        Hive.Persistence.get_agents(),
        fn a -> "- #{a.name} -- #{a.description}" end
      )

    topics_section =
      build_context_section(
        Hive.Persistence.get_subscriptions(agent_name),
        fn t -> "- #{t}" end
      )

    """
    ## Other Agents
    #{agents_section}

    ## Your Topics
    #{topics_section}
    """
  end

  defp build_context_section(result, format_fn) do
    case result do
      {:ok, items} -> Enum.map_join(items, "\n", format_fn)
      _ -> ""
    end
  end

  defp mcp_config_internal_path, do: "/workspace/.hive/mcp_config.json"

  defp hive_port do
    Application.get_env(:hive, HiveWeb.Endpoint)[:http][:port] || 4000
  end

  # ---------------------------------------------------------------------------
  # Test-mode file writers (write to host filesystem for mock SDK)
  # ---------------------------------------------------------------------------

  defp write_mcp_config(agent_name, secret) do
    config = %{
      "mcpServers" => %{
        "hive" => %{
          "command" => "node",
          "args" => [mcp_bridge_script(), agent_name, secret, hive_url()]
        }
      },
      "toolFilters" => %{}
    }

    path = mcp_config_path(agent_name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(config, pretty: true))
    path
  end

  defp write_dynamic_context(agent_name, agent_dir) do
    content = build_dynamic_context(agent_name)
    path = Path.join(agent_dir, ".hive_context.md")
    File.write!(path, content)
    path
  end

  defp write_claude_md(agent_name, agent_dir, description, personality) do
    # Build a temporary state-like struct for build_claude_md
    tmp_state = %__MODULE__{
      name: agent_name,
      description: description,
      personality: personality
    }

    path = Path.join(agent_dir, "CLAUDE.md")
    File.write!(path, build_claude_md(tmp_state))
    path
  end

  # ---------------------------------------------------------------------------
  # Sending messages to SDK subprocess
  # ---------------------------------------------------------------------------

  defp send_to_sdk(state, message_text) do
    if test_sdk_mode?() do
      write_dynamic_context(state.name, agent_dir(state.name))
    end

    Logger.debug("Agent #{state.name} -> SDK: #{String.slice(message_text, 0, 200)}")

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
      case Hive.Persistence.get_messages(topic_name, 5) do
        {:ok, messages} when messages != [] ->
          header = "[channel_history]\nchannel_type=topic\nchannel_name=#{topic_name}"

          lines =
            messages
            |> Enum.map(&render_history_message("topic", topic_name, &1))
            |> Enum.join("\n")

          header <> "\n" <> lines <> "\n[/channel_history]"

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # ---------------------------------------------------------------------------
  # Path helpers
  # ---------------------------------------------------------------------------

  defp render_message(channel_type, channel_name, message) do
    """
    [message]
    channel_type=#{channel_type}
    channel_name=#{channel_name}
    sender=#{message.sender}
    sender_kind=#{Map.get(message, :sender_kind, Hive.Util.sender_kind(message.sender))}
    timestamp=#{format_timestamp(message.ts)}
    body:
    #{message.body}
    [/message]
    """
  end

  defp render_history_message(channel_type, channel_name, message) do
    """
    - channel_type=#{channel_type} channel_name=#{channel_name} sender=#{message.sender} sender_kind=#{Map.get(message, :sender_kind, Hive.Util.sender_kind(message.sender))} timestamp=#{format_timestamp(message.ts)}
      #{message.body}
    """
    |> String.trim_trailing()
  end

  defp render_system_message(message) do
    """
    [system]
    timestamp=#{format_timestamp(DateTime.utc_now())}
    body:
    #{message}
    [/system]
    """
  end

  defdelegate format_timestamp(ts), to: Hive.Util

  defp maybe_start_activity(state, channel_type, channel_name, sender) do
    if sender == state.name do
      state
    else
      channel = {channel_type, channel_name}
      same_channel = state.active_channel == channel

      # Preserve composing_since if we're already composing for this channel
      composing_since =
        if same_channel and state.composing_since,
          do: state.composing_since,
          else: DateTime.utc_now()

      # Reset steered flag when switching channels
      steered = if same_channel, do: state.steered, else: false

      # Cancel any pending grace timer since we're starting new activity
      state = cancel_typing_timer(state)
      next_state = stop_active_typing(state)

      safe_broadcast(
        "topic:#{channel_name}",
        {:typing, %{topic: channel_name, agent: state.name, typing: true}}
      )

      %{next_state | active_channel: channel, composing_since: composing_since, steered: steered}
    end
  end

  defp maybe_stop_activity(state, :idle) do
    # Use grace period — agent may resume thinking shortly
    state = cancel_typing_timer(state)
    timer = Process.send_after(self(), :typing_grace_expired, 3_000)
    %{state | typing_timer: timer}
  end

  defp maybe_stop_activity(state, :thinking) do
    # Agent resumed — cancel any pending grace timer
    cancel_typing_timer(state)
  end

  defp maybe_stop_activity(state, _status), do: state

  defp stop_active_typing(state), do: stop_active_typing(state, preserve_channel: false)
  defp stop_active_typing(%{active_channel: nil} = state, _opts), do: state

  defp stop_active_typing(%{active_channel: {_channel_type, channel_name}} = state, opts) do
    safe_broadcast(
      "topic:#{channel_name}",
      {:typing, %{topic: channel_name, agent: state.name, typing: false}}
    )

    if Keyword.get(opts, :preserve_channel, false) do
      state
    else
      %{state | active_channel: nil, composing_since: nil, steered: false}
    end
  end

  defp cancel_typing_timer(%{typing_timer: nil} = state), do: state

  defp cancel_typing_timer(%{typing_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | typing_timer: nil}
  end

  defp push_scratchpad(state, event) do
    scratchpad = [event | state.scratchpad]

    scratchpad =
      if length(scratchpad) > @scratchpad_limit,
        do: Enum.take(scratchpad, @scratchpad_limit),
        else: scratchpad

    %{state | scratchpad: scratchpad}
  end

  defdelegate safe_broadcast(topic, payload), to: Hive.Util

  defp docker_executable do
    Application.get_env(:hive, :container_docker_executable) ||
      System.find_executable("docker") ||
      "docker"
  end

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
end
