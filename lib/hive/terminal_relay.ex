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

  @doc "Resize the terminal. Restarts the PTY with new dimensions."
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
    cols = Keyword.get(opts, :cols, 120)
    rows = Keyword.get(opts, :rows, 35)

    # Monitor the viewer (LiveView process) so we terminate when it disconnects
    Process.monitor(viewer)

    port = open_port(container_id, cols, rows)

    {:ok,
     %{
       port: port,
       container_id: container_id,
       viewer: viewer,
       cols: cols,
       rows: rows
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
    # Skip if dimensions haven't changed
    if cols == state.cols and rows == state.rows do
      {:noreply, state}
    else
      # Close old port (docker exec detaches, tmux session persists)
      try do
        Port.close(state.port)
      rescue
        ArgumentError -> :ok
      end

      # Open new port with correct PTY dimensions
      port = open_port(state.container_id, cols, rows)

      {:noreply, %{state | port: port, cols: cols, rows: rows}}
    end
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

  # Ignore exit_status from a previously closed port
  def handle_info({_old_port, {:exit_status, _code}}, state) do
    {:noreply, state}
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

  defp open_port(container_id, cols, rows) do
    docker = docker_executable()
    script = System.find_executable("script") || "/usr/bin/script"

    # Use stty to set the PTY size before attaching to tmux.
    # This ensures tmux sees the correct client dimensions.
    cmd =
      "stty cols #{cols} rows #{rows} 2>/dev/null; exec #{docker} exec -it #{container_id} tmux attach -t main"

    Port.open(
      {:spawn_executable, script},
      [
        :binary,
        :exit_status,
        args: ["-qfc", cmd, "/dev/null"]
      ]
    )
  end

  defp docker_executable do
    Application.get_env(:hive, :container_docker_executable) ||
      System.find_executable("docker") ||
      "docker"
  end
end
