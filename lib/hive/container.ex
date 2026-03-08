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

      with :ok <- validate_execution(task_input, timeout_ms),
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
  def validate_execution(task_input, default_timeout_ms \\ @default_timeout_ms) do
    with :ok <- validate_task(task_input),
         {:ok, _timeout_ms} <- resolve_timeout_ms(task_input, default_timeout_ms),
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
  Send input text to a container's tmux session (followed by Enter).
  """
  def send_input(container_id, text) do
    case Registry.lookup(Hive.ContainerRegistry, container_id) do
      [{_pid, _}] ->
        docker = docker_executable()

        case System.cmd(docker, [
               "exec", container_id, "tmux", "send-keys", "-t", "main", text, "Enter"
             ], stderr_to_stdout: true) do
          {_, 0} -> {:ok, "Input sent to container #{container_id}"}
          {output, _} -> {:error, "Failed to send input: #{String.trim(output)}"}
        end

      [] ->
        {:error, "Container #{container_id} not found"}
    end
  end

  @doc """
  Capture the full scrollback output from a container's tmux session.
  """
  def capture_output(container_id) do
    case Registry.lookup(Hive.ContainerRegistry, container_id) do
      [{_pid, _}] ->
        docker = docker_executable()

        case System.cmd(docker, [
               "exec", container_id, "tmux", "capture-pane", "-p", "-S", "-", "-t", "main"
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

    task = task_input["task"] || "No task description provided"

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

  defp via(id, agent_name) do
    {:via, Registry, {Hive.ContainerRegistry, id, agent_name}}
  end

  defp launch_detached_container(state) do
    docker = docker_executable()
    prompt = build_prompt(state.task_input)

    env_args = auth_env_args()

    # Step 1: Start container in detached mode with tmux entrypoint
    docker_args =
      ["run", "-d", "--name", state.id] ++
        env_args ++
        ["--network", "bridge", image_name()]

    case System.cmd(docker, docker_args, stderr_to_stdout: true) do
      {_, 0} ->
        # Step 2: Write prompt to temp file and copy into container
        tmp = "/tmp/#{state.id}_task.txt"
        File.write!(tmp, prompt)
        System.cmd(docker, ["cp", tmp, "#{state.id}:/tmp/task.txt"], stderr_to_stdout: true)
        File.rm(tmp)

        # Step 3: Launch Claude Code in the tmux session
        claude_cmd =
          "claude --dangerously-skip-permissions --output-format json " <>
            "--settings '{\"effortLevel\":\"max\"}' -p \"$(cat /tmp/task.txt)\""

        System.cmd(
          docker,
          ["exec", state.id, "tmux", "send-keys", "-t", "main", claude_cmd, "Enter"],
          stderr_to_stdout: true
        )

        # Step 4: Monitor container exit in background
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

  defp build_prompt(task_input) do
    parts =
      [
        {"Task", task_input["task"]},
        {"Repository", task_input["repo"]},
        {"Files", task_input["files"]},
        {"Context", task_input["context"]}
      ]
      |> Enum.reject(fn {_label, value} -> is_nil(value) or value == "" end)
      |> Enum.map(fn {label, value} -> "## #{label}\n#{value}" end)

    body = Enum.join(parts, "\n\n")

    """
    You are a coding agent running inside a tmux session in an isolated Docker container.

    - Use Claude Code for coding and agentic tasks (it's available as `claude` CLI)
    - You can create new tmux windows: Ctrl-b c (or via the container_new_window tool)
    - You can switch windows: Ctrl-b <number>
    - You can run any shell command in additional windows
    - A human may be watching your terminal and can send steering inputs
    - Your main task runs in window 0

    Complete the task below, then provide a concise summary of what you did and any issues encountered.

    #{body}

    When finished, output a summary of your work.
    """
  end

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

  defp notify_agent(state, exit_code, extra_info \\ nil) do
    output = capture_pane(state.id)

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

  defp validate_task(%{"task" => task}) when is_binary(task) do
    if String.trim(task) == "" do
      {:error, "task is required"}
    else
      :ok
    end
  end

  defp validate_task(_task_input), do: {:error, "task is required"}

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
