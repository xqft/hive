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

  defstruct [
    :id,
    :agent_name,
    :task,
    :port,
    :timer_ref,
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

  Returns `{:ok, container_id}` or `{:error, :limit_reached, message}`.
  """
  def start(agent_name, task_input, timeout_ms \\ 600_000) do
    if count_by_agent(agent_name) >= @max_per_agent do
      {:error, :limit_reached,
       "Agent #{agent_name} has reached the maximum of #{@max_per_agent} concurrent containers"}
    else
      container_id = "hive-#{agent_name}-#{:erlang.unique_integer([:positive])}"

      # Allow timeout_minutes from task_input to override the default
      timeout_ms =
        case task_input do
          %{"timeout_minutes" => minutes} when is_number(minutes) and minutes > 0 ->
            round(minutes * 60_000)

          _ ->
            timeout_ms
        end

      case DynamicSupervisor.start_child(
             Hive.ContainerSup,
             {__MODULE__,
              id: container_id,
              agent_name: agent_name,
              task_input: task_input,
              timeout_ms: timeout_ms}
           ) do
        {:ok, _pid} -> {:ok, container_id}
        {:error, reason} -> {:error, reason}
      end
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
    case System.cmd("docker", ["ps", "--filter", "name=hive-", "--format", "{{.Names}}"]) do
      {output, 0} ->
        containers = String.split(output, "\n", trim: true)

        Enum.each(containers, fn name ->
          Logger.info("Cleaning up orphaned container: #{name}")
          System.cmd("docker", ["kill", name])
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
    prompt = build_prompt(task_input)

    docker_args = [
      "run",
      "--rm",
      "--name",
      id,
      "--env",
      "ANTHROPIC_API_KEY=#{api_key()}",
      "--network",
      "bridge",
      "hive-claude-code:latest",
      "-p",
      prompt,
      "--output-format",
      "json"
    ]

    port =
      Port.open({:spawn_executable, docker_executable()}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: docker_args
      ])

    timer_ref = Process.send_after(self(), :timeout, timeout_ms)

    Phoenix.PubSub.broadcast(
      Hive.PubSub,
      "containers",
      {:started, agent_name, id, task}
    )

    Logger.info("Container #{id} started for agent #{agent_name}: #{task}")

    state = %__MODULE__{
      id: id,
      agent_name: agent_name,
      task: task,
      port: port,
      buffer: [],
      timer_ref: timer_ref,
      status: :running
    }

    {:ok, state}
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
  def handle_cast(:kill, %{status: :running} = state) do
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
      System.cmd("docker", ["kill", container_id], stderr_to_stdout: true)
    end)
  end

  defp docker_executable do
    System.find_executable("docker") || "docker"
  end

  defp api_key do
    Application.get_env(:hive, :anthropic_api_key) || ""
  end
end
