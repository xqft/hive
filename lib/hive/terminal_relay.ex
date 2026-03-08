defmodule Hive.TerminalRelay do
  @moduledoc """
  Per-viewer GenServer that manages a PTY-wrapped `docker exec` connection
  to a container's tmux session. Streams raw terminal output to a LiveView
  process and forwards user keystrokes to the tmux session.

  Each browser tab gets its own relay. When the LiveView disconnects, the
  relay terminates and the docker exec detaches — tmux keeps running.
  """

  use GenServer

  require Logger

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Send raw input bytes to the tmux session."
  def send_input(pid, data) do
    GenServer.cast(pid, {:input, data})
  end

  @doc "Request terminal resize."
  def resize(pid, cols, rows) do
    GenServer.cast(pid, {:resize, cols, rows})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    container_id = Keyword.fetch!(opts, :container_id)
    viewer = Keyword.fetch!(opts, :viewer)

    # Monitor the viewer (LiveView process) so we terminate when it disconnects
    Process.monitor(viewer)

    docker = docker_executable()

    # Use `script` to allocate a PTY for the docker exec subprocess.
    # -q: quiet (no "Script started" header), -f: flush after write, -c: command
    port =
      Port.open(
        {:spawn_executable, System.find_executable("script") || "/usr/bin/script"},
        [
          :binary,
          :exit_status,
          args: ["-qfc", "#{docker} exec -it #{container_id} tmux attach -t main", "/dev/null"]
        ]
      )

    {:ok,
     %{
       port: port,
       container_id: container_id,
       viewer: viewer
     }}
  end

  @impl true
  def handle_cast({:input, data}, state) do
    try do
      Port.command(state.port, data)
    rescue
      ArgumentError -> :ok
    end

    {:noreply, state}
  end

  def handle_cast({:resize, cols, rows}, state) do
    # Resize via a separate docker exec (not through the relay port)
    docker = docker_executable()

    Task.start(fn ->
      System.cmd(docker, [
        "exec",
        state.container_id,
        "tmux",
        "resize-window",
        "-t",
        "main",
        "-x",
        to_string(cols),
        "-y",
        to_string(rows)
      ], stderr_to_stdout: true)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    send(state.viewer, {:terminal_output, data})
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, _code}}, %{port: port} = state) do
    send(state.viewer, :terminal_closed)
    {:stop, :normal, state}
  end

  # Viewer (LiveView) went down — clean up
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{viewer: pid} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    try do
      Port.close(state.port)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp docker_executable do
    Application.get_env(:hive, :container_docker_executable) ||
      System.find_executable("docker") ||
      "docker"
  end
end
