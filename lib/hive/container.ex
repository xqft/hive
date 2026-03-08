defmodule Hive.Container do
  @moduledoc """
  GenServer managing a single Docker container running Claude Code inside a
  tmux session for isolated code execution tasks.

  Each container is an independent GenServer under `Hive.ContainerSup`
  (DynamicSupervisor). Containers are registered via
  `{:via, Registry, {Hive.ContainerRegistry, id, agent_name}}` where the third
  element is metadata storing the owning agent name.

  Containers run in detached mode with tmux. Users can attach to the tmux
  session via TerminalRelay for live observation and interaction. The container
  is monitored via `docker wait`.
  """

  use GenServer

  require Logger

  @max_per_agent 16
  @default_timeout_ms 600_000
  @min_timeout_minutes 1
  @max_timeout_minutes 60
  @default_image "hive-claude-code:latest"

  defstruct [
    :id,
    :agent_name,
    :task,
    :task_input,
    :timer_ref,
    :timeout_ms,
    :status
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start a container for `agent_name` executing the given task.

  `task_input` is a map with keys:
    - `"task"` (required) — task description
    - `"repo"` — git repo to clone
    - `"files"` — files to focus on
    - `"context"` — additional context
    - `"timeout_minutes"` — override default timeout

  Returns `{:ok, container_id}` or `{:error, message}`.
  """
  def start(agent_name, task_input, timeout_ms \\ @default_timeout_ms) do
    if count_by_agent(agent_name) >= @max_per_agent do
      {:error,
       "Agent #{agent_name} has reached the maximum of #{@max_per_agent} concurrent containers"}
    else
      container_id = "hive-#{agent_name}-#{:erlang.unique_integer([:positive])}"

      with :ok <- validate_execution(task_input),
           {:ok, resolved_timeout_ms} <- resolve_timeout_ms(task_input, timeout_ms) do
        case DynamicSupervisor.start_child(
               Hive.ContainerSup,
               {__MODULE__,
                id: container_id,
                agent_name: agent_name,
                task_input: task_input,
                timeout_ms: resolved_timeout_ms}
             ) do
          {:ok, _pid} ->
            {:ok, container_id}

          {:error, reason} ->
            Logger.error("Failed to start container #{container_id}: #{inspect(reason)}")
            {:error, "Failed to launch container: #{format_reason(reason)}"}
        end
      end
    end
  end

  @doc """
  Validate a container execution request before attempting to launch it.
  """
  def validate_execution(task_input) do
    with {:ok, _timeout_ms} <- resolve_timeout_ms(task_input, @default_timeout_ms),
         :ok <- validate_docker_available(),
         :ok <- validate_image_available(),
         :ok <- validate_api_key() do
      :ok
    end
  end

  @doc """
  Check the status of a container. Captures the current tmux pane output.
  Returns `{:ok, status_string}` or `{:error, :not_found}`.
  """
  def check(container_id) do
    case Registry.lookup(Hive.ContainerRegistry, container_id) do
      [{pid, _}] -> GenServer.call(pid, :check)
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Kill a running container. No-op if already stopped or not found.
  """
  def kill(container_id) do
    case Registry.lookup(Hive.ContainerRegistry, container_id) do
      [{pid, _}] -> GenServer.cast(pid, :kill)
      [] -> :ok
    end
  end

  @doc """
  Send input to a container's tmux session.

  Options:
    - `input` — text to type followed by Enter (for shell commands)
    - `keys` — raw tmux key names, space-separated (e.g. "Enter", "C-c", "Up Enter")
    - `window` — target window index (default "0")

  Provide `input` for commands, `keys` for TUI interaction. If both given,
  `input` is sent as literal text then `keys` are sent as key names.

  Use `pane` to target a specific pane within a window (e.g. "1" for pane 1).

  After sending input, waits `wait_ms` (default 1000, max 10000) then captures
  and returns the pane output. Set to 0 to skip capture and return immediately.
  """
  def send_input(container_id, opts) when is_map(opts) do
    case Registry.lookup(Hive.ContainerRegistry, container_id) do
      [{_pid, _}] ->
        docker = docker_executable()
        target = build_target(opts)
        input = Map.get(opts, "input")
        keys = Map.get(opts, "keys")
        wait_ms = normalize_wait_ms(Map.get(opts, "wait_ms", 1000))

        case exec_send_keys(docker, container_id, target, input, keys) do
          {_, 0} ->
            if wait_ms > 0 do
              Process.sleep(wait_ms)

              case System.cmd(docker, [
                     "exec", container_id, "tmux", "capture-pane", "-p", "-S", "-", "-t", target
                   ], stderr_to_stdout: true) do
                {output, 0} -> {:ok, output}
                _ -> {:ok, "Input sent (output capture failed)"}
              end
            else
              {:ok, "Input sent"}
            end

          {output, _} ->
            {:error, "Failed to send input: #{String.trim(output)}"}
        end

      [] ->
        {:error, "Container #{container_id} not found"}
    end
  end

  # Legacy 2-arg form for backwards compatibility (tests, notify_agent, etc.)
  def send_input(container_id, text) when is_binary(text) do
    send_input(container_id, %{"input" => text})
  end

  @doc """
  Capture the full scrollback output from a container's tmux session.

  Options:
    - `window` — target window index (default "0")
  """
  def capture_output(container_id, opts \\ %{}) do
    case Registry.lookup(Hive.ContainerRegistry, container_id) do
      [{_pid, _}] ->
        docker = docker_executable()
        target = build_target(opts)

        case System.cmd(docker, [
               "exec", container_id, "tmux", "capture-pane", "-p", "-S", "-", "-t", target
             ], stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, _} -> {:error, "Failed to capture output: #{String.trim(output)}"}
        end

      [] ->
        {:error, "Container #{container_id} not found"}
    end
  end

  @doc """
  List tmux windows in a container's session.
  """
  def list_windows(container_id) do
    case Registry.lookup(Hive.ContainerRegistry, container_id) do
      [{_pid, _}] ->
        docker = docker_executable()

        case System.cmd(docker, [
               "exec", container_id, "tmux", "list-windows", "-t", "main",
               "-F", "\#{window_index}:\#{window_name}"
             ], stderr_to_stdout: true) do
          {output, 0} -> {:ok, String.trim(output)}
          {output, _} -> {:error, "Failed to list windows: #{String.trim(output)}"}
        end

      [] ->
        {:error, "Container #{container_id} not found"}
    end
  end

  @doc """
  Split a tmux pane in a container's session.

  Options:
    - `direction` — "horizontal" or "vertical" (default "vertical")
    - `window` — target window index (default "0")
    - `command` — optional command to run in the new pane
  """
  def split_pane(container_id, direction \\ "vertical", window \\ "0", command \\ nil) do
    case Registry.lookup(Hive.ContainerRegistry, container_id) do
      [{_pid, _}] ->
        docker = docker_executable()
        flag = if direction == "horizontal", do: "-h", else: "-v"
        target = "main:#{window}"

        args =
          ["exec", container_id, "tmux", "split-window", flag, "-t", target] ++
            if(command, do: [command], else: [])

        case System.cmd(docker, args, stderr_to_stdout: true) do
          {_, 0} -> {:ok, "Pane split #{direction}ly in window #{window}"}
          {output, _} -> {:error, "Failed to split pane: #{String.trim(output)}"}
        end

      [] ->
        {:error, "Container #{container_id} not found"}
    end
  end

  @doc """
  List tmux panes in a container's window.
  """
  def list_panes(container_id, window \\ "0") do
    case Registry.lookup(Hive.ContainerRegistry, container_id) do
      [{_pid, _}] ->
        docker = docker_executable()
        target = "main:#{window}"

        case System.cmd(docker, [
               "exec", container_id, "tmux", "list-panes", "-t", target,
               "-F", "\#{pane_index}:\#{pane_width}x\#{pane_height}:\#{pane_active}"
             ], stderr_to_stdout: true) do
          {output, 0} -> {:ok, String.trim(output)}
          {output, _} -> {:error, "Failed to list panes: #{String.trim(output)}"}
        end

      [] ->
        {:error, "Container #{container_id} not found"}
    end
  end

  @doc """
  Create a new tmux window in a container's session.
  """
  def new_window(container_id, name, command \\ nil) do
    case Registry.lookup(Hive.ContainerRegistry, container_id) do
      [{_pid, _}] ->
        docker = docker_executable()

        args =
          ["exec", container_id, "tmux", "new-window", "-t", "main", "-n", name] ++
            if(command, do: [command], else: [])

        case System.cmd(docker, args, stderr_to_stdout: true) do
          {_, 0} -> {:ok, "Window '#{name}' created in container #{container_id}"}
          {output, _} -> {:error, "Failed to create window: #{String.trim(output)}"}
        end

      [] ->
        {:error, "Container #{container_id} not found"}
    end
  end

  @doc """
  List all containers owned by `agent_name`.
  Returns a list of `{container_id, pid}`.
  """
  def list_by_agent(agent_name) do
    Registry.select(Hive.ContainerRegistry, [
      {{:"$1", :"$2", :"$3"}, [{:==, :"$3", agent_name}], [{{:"$1", :"$2"}}]}
    ])
  end

  @doc """
  Kill all Docker containers whose names start with `hive-`.
  Called on application startup to clean up orphans from previous runs.
  """
  def cleanup_orphaned_containers do
    case System.cmd(
           docker_executable(),
           ["ps", "--filter", "name=hive-", "--format", "{{.Names}}"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        containers = String.split(output, "\n", trim: true)

        Enum.each(containers, fn name ->
          Logger.info("Cleaning up orphaned container: #{name}")
          System.cmd(docker_executable(), ["stop", "-t", "2", name], stderr_to_stdout: true)
          System.cmd(docker_executable(), ["rm", "-f", name], stderr_to_stdout: true)
        end)

        {:ok, length(containers)}

      {_, _code} ->
        Logger.warning("Docker not available — skipping orphan container cleanup")
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # start_link (called by DynamicSupervisor)
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    agent_name = Keyword.fetch!(opts, :agent_name)
    GenServer.start_link(__MODULE__, opts, name: via(id, agent_name))
  end

  def child_spec(opts) do
    id = Keyword.fetch!(opts, :id)

    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    agent_name = Keyword.fetch!(opts, :agent_name)
    task_input = Keyword.fetch!(opts, :task_input)
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)

    task = task_input["task"] || "Interactive session"

    state = %__MODULE__{
      id: id,
      agent_name: agent_name,
      task: task,
      task_input: task_input,
      timer_ref: nil,
      timeout_ms: timeout_ms,
      status: :starting
    }

    {:ok, state, {:continue, :launch_container}}
  end

  @impl true
  def handle_continue(:launch_container, state) do
    case launch_detached_container(state) do
      :ok ->
        timer_ref = Process.send_after(self(), :timeout, state.timeout_ms)

        Phoenix.PubSub.broadcast(
          Hive.PubSub,
          "containers",
          {:started, state.agent_name, state.id, state.task}
        )

        Logger.info("Container #{state.id} started for agent #{state.agent_name}: #{state.task}")

        {:noreply, %{state | timer_ref: timer_ref, status: :running}}

      {:error, reason} ->
        failed_state = %{state | status: :failed}

        Logger.error("Container #{state.id} failed to launch: #{reason}")

        notify_agent(failed_state, :startup_failed, reason)

        Phoenix.PubSub.broadcast(
          Hive.PubSub,
          "containers",
          {:stopped, state.id, :failed}
        )

        {:stop, :normal, failed_state}
    end
  end

  @impl true
  def handle_call(:check, _from, state) do
    pane_output = capture_pane(state.id)

    status_string =
      "Container: #{state.id}\n" <>
        "Status: #{state.status}\n" <>
        "Task: #{state.task}\n" <>
        "--- Recent Output ---\n" <>
        pane_output

    {:reply, {:ok, status_string}, state}
  end

  @impl true
  def handle_cast(:kill, %{status: status} = state) when status in [:starting, :running] do
    cancel_timer(state.timer_ref)
    docker_stop(state.id)

    Logger.info("Container #{state.id} killed by request")

    notify_agent(state, :killed)

    Phoenix.PubSub.broadcast(
      Hive.PubSub,
      "containers",
      {:stopped, state.id, :killed}
    )

    {:stop, :normal, %{state | status: :failed}}
  end

  def handle_cast(:kill, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:container_exited, exit_code_str, _cmd_exit}, %{status: :running} = state) do
    cancel_timer(state.timer_ref)

    exit_code =
      case Integer.parse(exit_code_str) do
        {code, _} -> code
        :error -> 1
      end

    final_status = if exit_code == 0, do: :completed, else: :failed

    Logger.info("Container #{state.id} exited with code #{exit_code} (#{final_status})")

    notify_agent(state, exit_code)

    Phoenix.PubSub.broadcast(
      Hive.PubSub,
      "containers",
      {:stopped, state.id, final_status}
    )

    # Clean up the docker container
    docker_rm(state.id)

    {:stop, :normal, %{state | status: final_status}}
  end

  def handle_info({:container_exited, _exit_code_str, _cmd_exit}, %{status: :timed_out} = state) do
    Logger.info("Container #{state.id} exited after timeout")

    notify_agent(state, :timeout)

    Phoenix.PubSub.broadcast(
      Hive.PubSub,
      "containers",
      {:stopped, state.id, :timed_out}
    )

    # Clean up the docker container
    docker_rm(state.id)

    {:stop, :normal, state}
  end

  def handle_info({:container_exited, _exit_code_str, _cmd_exit}, state) do
    # Already stopped — clean up
    docker_rm(state.id)
    {:noreply, state}
  end

  def handle_info(:timeout, %{status: :running} = state) do
    Logger.warning("Container #{state.id} timed out — stopping")
    docker_stop(state.id)
    {:noreply, %{state | status: :timed_out}}
  end

  def handle_info(:timeout, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp normalize_wait_ms(ms) when is_number(ms), do: ms |> trunc() |> max(0) |> min(10_000)
  defp normalize_wait_ms(_), do: 1000

  # Build a tmux target from opts: main:{window} or main:{window}.{pane}
  defp build_target(opts) when is_map(opts) do
    window = Map.get(opts, "window", "0")
    pane = Map.get(opts, "pane")

    if pane, do: "main:#{window}.#{pane}", else: "main:#{window}"
  end

  defp build_target(window) when is_binary(window), do: "main:#{window}"

  defp via(id, agent_name) do
    {:via, Registry, {Hive.ContainerRegistry, id, agent_name}}
  end

  defp launch_detached_container(state) do
    docker = docker_executable()
    env_args = auth_env_args()

    # Start container in detached mode with tmux entrypoint
    docker_args =
      ["run", "-d", "--name", state.id] ++
        env_args ++
        ["--network", "bridge", image_name()]

    case System.cmd(docker, docker_args, stderr_to_stdout: true) do
      {_, 0} ->
        # Wait for tmux session to be ready
        wait_for_tmux(docker, state.id)

        # Inject OAuth credentials so interactive Claude Code skips login
        inject_oauth_credentials(docker, state.id)

        # Monitor container exit in background
        self_pid = self()

        Task.start(fn ->
          {output, code} = System.cmd(docker, ["wait", state.id], stderr_to_stdout: true)
          send(self_pid, {:container_exited, String.trim(output), code})
        end)

        :ok

      {output, _code} ->
        {:error, "docker run failed: #{String.trim(output)}"}
    end
  rescue
    e -> {:error, format_reason(e)}
  end

  # Poll until the tmux session is ready (up to 3 seconds)
  defp wait_for_tmux(docker, container_id, attempts \\ 15) do
    case System.cmd(docker, ["exec", container_id, "tmux", "has-session", "-t", "main"],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(200)
        wait_for_tmux(docker, container_id, attempts - 1)

      _ ->
        Logger.warning("tmux session not ready after timeout for #{container_id}")
        :timeout
    end
  end

  # Execute send-keys based on input/keys combination.
  # Uses two calls when both literal text and key names are needed,
  # since tmux -l makes everything literal (no key name interpretation).
  defp exec_send_keys(docker, container_id, target, input, keys) do
    has_input = is_binary(input) and input != ""
    has_keys = is_binary(keys) and keys != ""

    cond do
      has_input and has_keys ->
        # Literal text first, then raw key names
        System.cmd(docker, ["exec", container_id, "tmux", "send-keys", "-l", "-t", target, input],
          stderr_to_stdout: true
        )

        System.cmd(
          docker,
          ["exec", container_id, "tmux", "send-keys", "-t", target | String.split(keys)],
          stderr_to_stdout: true
        )

      has_input ->
        # Text + Enter (default for shell commands)
        System.cmd(docker, ["exec", container_id, "tmux", "send-keys", "-l", "-t", target, input],
          stderr_to_stdout: true
        )

        System.cmd(docker, ["exec", container_id, "tmux", "send-keys", "-t", target, "Enter"],
          stderr_to_stdout: true
        )

      has_keys ->
        # Raw key names only (for TUI interaction)
        System.cmd(
          docker,
          ["exec", container_id, "tmux", "send-keys", "-t", target | String.split(keys)],
          stderr_to_stdout: true
        )

      true ->
        # Just Enter
        System.cmd(docker, ["exec", container_id, "tmux", "send-keys", "-t", target, "Enter"],
          stderr_to_stdout: true
        )
    end
  end

  # Inject OAuth credentials file so interactive Claude Code skips the login flow.
  # The env var CLAUDE_CODE_OAUTH_TOKEN works for -p mode but interactive mode
  # requires stored credentials in ~/.claude/.credentials.json.
  defp inject_oauth_credentials(docker, container_id) do
    token = oauth_token()

    if token != "" do
      # Build a credentials JSON matching Claude Code's expected format.
      # Far-future expiry so it doesn't try to refresh.
      credentials = %{
        "claudeAiOauth" => %{
          "accessToken" => token,
          "refreshToken" => "",
          "expiresAt" => System.system_time(:millisecond) + 365 * 86_400_000,
          "scopes" => [
            "user:inference",
            "user:profile",
            "user:sessions:claude_code"
          ]
        }
      }

      tmp = "/tmp/#{container_id}_credentials.json"
      File.write!(tmp, Jason.encode!(credentials))

      System.cmd(docker, ["cp", tmp, "#{container_id}:/home/hive/.claude/.credentials.json"],
        stderr_to_stdout: true
      )

      File.rm(tmp)
    end
  rescue
    e -> Logger.warning("Failed to inject credentials for #{container_id}: #{inspect(e)}")
  end

  # Capture tmux pane from a running container via docker exec
  defp capture_pane(container_id) do
    docker = docker_executable()

    case System.cmd(
           docker,
           ["exec", container_id, "tmux", "capture-pane", "-p", "-t", "main"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> output
      {_, _} -> "(unable to capture terminal output)"
    end
  rescue
    _ -> "(unable to capture terminal output)"
  end

  # Extract saved output from a stopped container via docker cp.
  # The entrypoint saves tmux pane content to /tmp/last_output.txt every second.
  defp extract_saved_output(container_id) do
    docker = docker_executable()
    tmp = "/tmp/#{container_id}_output.txt"

    case System.cmd(docker, ["cp", "#{container_id}:/tmp/last_output.txt", tmp],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        output = File.read!(tmp)
        File.rm(tmp)
        output

      _ ->
        "(no output captured)"
    end
  rescue
    _ -> "(no output captured)"
  end

  defp notify_agent(state, exit_code, extra_info \\ nil) do
    # For stopped containers, extract saved output file.
    # For running containers (e.g. killed), capture live pane.
    output =
      case exit_code do
        :killed -> capture_pane(state.id)
        :startup_failed -> extra_info || "(startup failed)"
        _ -> extract_saved_output(state.id)
      end

    status_label =
      case exit_code do
        0 -> "completed successfully"
        :timeout -> "timed out"
        :killed -> "was killed"
        :startup_failed -> "failed to start"
        code when is_integer(code) -> "failed with exit code #{code}"
        other -> "ended with status: #{inspect(other)}"
      end

    msg =
      "[Container #{state.id}] #{status_label}\n" <>
        "Task: #{state.task}\n" <>
        if(extra_info, do: "Info: #{extra_info}\n", else: "") <>
        "--- Output ---\n" <>
        output

    case Registry.lookup(Hive.AgentRegistry, state.agent_name) do
      [{pid, _}] -> send(pid, {:system_message, msg})
      [] -> Logger.debug("Agent #{state.agent_name} not found — skipping notification")
    end
  end

  defp count_by_agent(agent_name) do
    Hive.ContainerRegistry
    |> Registry.select([
      {{:_, :_, :"$1"}, [{:==, :"$1", agent_name}], [true]}
    ])
    |> length()
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(ref) do
    Process.cancel_timer(ref)
  end

  defp docker_stop(container_id) do
    Task.start(fn ->
      docker = docker_executable()
      System.cmd(docker, ["stop", "-t", "2", container_id], stderr_to_stdout: true)
    end)
  end

  defp docker_rm(container_id) do
    Task.start(fn ->
      docker = docker_executable()
      System.cmd(docker, ["rm", "-f", container_id], stderr_to_stdout: true)
    end)
  end

  defp docker_executable do
    Application.get_env(:hive, :container_docker_executable) ||
      System.find_executable("docker") ||
      "docker"
  end

  defp resolve_timeout_ms(task_input, default_timeout_ms) do
    case Map.get(task_input, "timeout_minutes") do
      nil ->
        {:ok, default_timeout_ms}

      minutes ->
        with {:ok, normalized_minutes} <- normalize_timeout_minutes(minutes),
             true <-
               normalized_minutes >= @min_timeout_minutes and
                 normalized_minutes <= @max_timeout_minutes do
          {:ok, round(normalized_minutes * 60_000)}
        else
          _ ->
            {:error,
             "timeout_minutes must be between #{@min_timeout_minutes} and #{@max_timeout_minutes}"}
        end
    end
  end

  defp normalize_timeout_minutes(minutes) when is_number(minutes), do: {:ok, minutes}

  defp normalize_timeout_minutes(minutes) when is_binary(minutes) do
    case Float.parse(minutes) do
      {value, ""} -> {:ok, value}
      _ -> {:error, :invalid_timeout}
    end
  end

  defp normalize_timeout_minutes(_minutes), do: {:error, :invalid_timeout}

  defp validate_docker_available do
    case Application.get_env(:hive, :container_docker_available) do
      nil ->
        if System.find_executable("docker") do
          :ok
        else
          {:error, "docker is not installed or not on PATH"}
        end

      true ->
        :ok

      false ->
        {:error, "docker is not installed or not on PATH"}
    end
  end

  defp validate_image_available do
    case Application.get_env(:hive, :container_image_available) do
      nil ->
        case System.cmd(docker_executable(), ["image", "inspect", image_name()],
               stderr_to_stdout: true
             ) do
          {_, 0} -> :ok
          {_output, _code} -> {:error, "container image #{image_name()} is not available locally"}
        end

      true ->
        :ok

      false ->
        {:error, "container image #{image_name()} is not available locally"}
    end
  rescue
    ErlangError -> {:error, "container image #{image_name()} is not available locally"}
  end

  defp validate_api_key do
    if oauth_token() == "" do
      {:error, "CLAUDE_CODE_OAUTH_TOKEN is not configured"}
    else
      :ok
    end
  end

  defp auth_env_args do
    token = oauth_token()
    if token != "", do: ["--env", "CLAUDE_CODE_OAUTH_TOKEN=#{token}"], else: []
  end

  defp image_name do
    Application.get_env(:hive, :container_image_name, @default_image)
  end

  defp format_reason({kind, reason}), do: "#{kind}: #{Exception.format_banner(kind, reason)}"
  defp format_reason(%{message: msg}), do: msg
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp oauth_token do
    Application.get_env(:hive, :claude_oauth_token) |> to_string() |> String.trim()
  end
end
