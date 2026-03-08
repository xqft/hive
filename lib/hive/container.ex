defmodule Hive.Container do
  @moduledoc """
  GenServer managing a single Docker container running Claude Code for isolated
  code execution tasks.

  Each container is an independent GenServer under `Hive.ContainerSup`
  (DynamicSupervisor). Containers are registered via
  `{:via, Registry, {Hive.ContainerRegistry, id, agent_name}}` where the third
  element is metadata storing the owning agent name.

  Key design: if an agent crashes, its containers keep running and will notify
  the restarted agent on completion via Registry lookup.
  """

  use GenServer

  require Logger

  @max_per_agent 16
  @max_buffer_lines 30
  @default_timeout_ms 600_000
  @min_timeout_minutes 1
  @max_timeout_minutes 60
  @default_image "hive-claude-code:latest"

  defstruct [
    :id,
    :agent_name,
    :task,
    :task_input,
    :port,
    :timer_ref,
    :timeout_ms,
    :status,
    buffer: []
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
  Check the status of a container. Returns `{:ok, status_string}` or
  `{:error, :not_found}`.
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
           ["ps", "--filter", "name=hive-", "--format", "{{.Names}}"], stderr_to_stdout: true) do
      {output, 0} ->
        containers = String.split(output, "\n", trim: true)

        Enum.each(containers, fn name ->
          Logger.info("Cleaning up orphaned container: #{name}")
          System.cmd(docker_executable(), ["kill", name])
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
      port: nil,
      buffer: [],
      timer_ref: nil,
      timeout_ms: timeout_ms,
      status: :starting
    }

    {:ok, state, {:continue, :launch_container}}
  end

  @impl true
  def handle_continue(:launch_container, state) do
    case open_container_port(state) do
      {:ok, port} ->
        timer_ref = Process.send_after(self(), :timeout, state.timeout_ms)

        Phoenix.PubSub.broadcast(
          Hive.PubSub,
          "containers",
          {:started, state.agent_name, state.id, state.task}
        )

        Logger.info("Container #{state.id} started for agent #{state.agent_name}: #{state.task}")

        {:noreply, %{state | port: port, timer_ref: timer_ref, status: :running}}

      {:error, reason} ->
        message = "Startup failed: #{reason}"
        failed_state = %{state | status: :failed, buffer: [message]}

        Logger.error("Container #{state.id} failed to launch: #{reason}")

        notify_agent(failed_state, :startup_failed)

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
    recent_output =
      state.buffer
      |> Enum.reverse()
      |> Enum.join("\n")

    status_string =
      "Container: #{state.id}\n" <>
        "Status: #{state.status}\n" <>
        "Task: #{state.task}\n" <>
        "--- Recent Output ---\n" <>
        recent_output

    {:reply, {:ok, status_string}, state}
  end

  @impl true
  def handle_cast(:kill, %{status: status} = state) when status in [:starting, :running] do
    cancel_timer(state.timer_ref)
    docker_kill(state.id)

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
    # Already stopped — ignore
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    new_lines = String.split(data, "\n", trim: true)
    buffer = Enum.take(state.buffer ++ new_lines, -@max_buffer_lines)

    Phoenix.PubSub.broadcast(
      Hive.PubSub,
      "container:#{state.id}",
      {:output, data}
    )

    {:noreply, %{state | buffer: buffer}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port, status: :running} = state) do
    cancel_timer(state.timer_ref)

    final_status = if code == 0, do: :completed, else: :failed

    Logger.info("Container #{state.id} exited with code #{code} (#{final_status})")

    notify_agent(state, code)

    Phoenix.PubSub.broadcast(
      Hive.PubSub,
      "containers",
      {:stopped, state.id, final_status}
    )

    {:stop, :normal, %{state | status: final_status}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port, status: :timed_out} = state) do
    # Container exited after we already timed it out
    Logger.info("Container #{state.id} exited after timeout with code #{code}")

    notify_agent(state, :timeout)

    Phoenix.PubSub.broadcast(
      Hive.PubSub,
      "containers",
      {:stopped, state.id, :timed_out}
    )

    {:stop, :normal, state}
  end

  def handle_info(:timeout, %{status: :running} = state) do
    Logger.warning("Container #{state.id} timed out — killing")
    docker_kill(state.id)
    {:noreply, %{state | status: :timed_out}}
  end

  def handle_info(:timeout, state) do
    # Already exited — ignore stale timeout
    {:noreply, state}
  end

  # Catch-all for unexpected port messages (e.g. after status change)
  def handle_info({port, _}, %{port: port} = state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp via(id, agent_name) do
    {:via, Registry, {Hive.ContainerRegistry, id, agent_name}}
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
    You are a coding agent running in an isolated container. Complete the task below, \
    then provide a concise summary of what you did and any issues encountered.

    #{body}

    When finished, output a summary of your work.
    """
  end

  defp notify_agent(state, exit_code) do
    result =
      state.buffer
      |> Enum.reverse()
      |> Enum.join("\n")

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
        "--- Output ---\n" <>
        result

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

  defp docker_kill(container_id) do
    Task.start(fn ->
      System.cmd(docker_executable(), ["kill", container_id], stderr_to_stdout: true)
    end)
  end

  defp docker_executable do
    Application.get_env(:hive, :container_docker_executable) || System.find_executable("docker") ||
      "docker"
  end

  defp open_container_port(state) do
    prompt = build_prompt(state.task_input)

    docker_args = [
      "run",
      "--rm",
      "--name",
      state.id,
      "--env",
      "ANTHROPIC_API_KEY=#{api_key()}",
      "--network",
      "bridge",
      image_name(),
      "-p",
      prompt,
      "--output-format",
      "json"
    ]

    try do
      {:ok,
       Port.open({:spawn_executable, docker_executable()}, [
         :binary,
         :exit_status,
         :stderr_to_stdout,
         args: docker_args
       ])}
    catch
      kind, reason ->
        {:error, format_reason({kind, reason})}
    end
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
          false ->
            {:error,
             "timeout_minutes must be between #{@min_timeout_minutes} and #{@max_timeout_minutes}"}

          {:error, _} ->
            {:error,
             "timeout_minutes must be between #{@min_timeout_minutes} and #{@max_timeout_minutes}"}
        end
    end
  end

  defp normalize_timeout_minutes(minutes) when is_integer(minutes), do: {:ok, minutes}
  defp normalize_timeout_minutes(minutes) when is_float(minutes), do: {:ok, minutes}

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
    if api_key() |> to_string() |> String.trim() == "" do
      {:error, "ANTHROPIC_API_KEY is not configured"}
    else
      :ok
    end
  end

  defp image_name do
    Application.get_env(:hive, :container_image_name, @default_image)
  end

  defp format_reason({kind, reason}), do: "#{kind}: #{Exception.format_banner(kind, reason)}"
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp api_key do
    Application.get_env(:hive, :anthropic_api_key) || ""
  end
end
