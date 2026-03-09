defmodule Hive.Connector.EventSource do
  @moduledoc """
  GenServer managing a single event source (poll or webhook).

  Poll sources execute a command at a configurable interval and post to a topic
  when the output changes. Webhook sources wait for external POST events.
  """

  use GenServer

  require Logger

  @default_interval_ms 60_000
  @backoff_multiplier 5
  @max_consecutive_failures 3

  defstruct [
    :name,
    :type,
    :topic,
    :command,
    :args,
    :interval_ms,
    :last_hash,
    :timer_ref,
    consecutive_failures: 0
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  def stop(name) do
    GenServer.stop(via(name))
  end

  def post_event(name, raw_payload) do
    GenServer.cast(via(name), {:post_event, raw_payload})
  end

  def info(name) do
    GenServer.call(via(name), :info)
  end

  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    type = Keyword.fetch!(opts, :type)
    topic = Keyword.fetch!(opts, :topic)
    config = Keyword.get(opts, :config, %{})

    state = %__MODULE__{
      name: name,
      type: type,
      topic: topic
    }

    case type do
      "poll" ->
        command = Map.get(config, "command", Map.get(config, :command))
        args = Map.get(config, "args", Map.get(config, :args, []))
        interval_ms = Map.get(config, "interval_ms", Map.get(config, :interval_ms, @default_interval_ms))

        state = %{state |
          command: command,
          args: args,
          interval_ms: interval_ms
        }

        {:ok, state, {:continue, :poll}}

      _ ->
        {:ok, state}
    end
  end

  @impl true
  def handle_continue(:poll, state) do
    state = do_poll(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = do_poll(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:post_event, raw_payload}, state) do
    {:ok, formatted} = Hive.Connector.Formatter.format(state.name, raw_payload)

    try do
      Hive.Topic.post(state.topic, "system", formatted)
    rescue
      e ->
        Logger.warning("EventSource #{state.name}: failed to post to topic #{state.topic}: #{inspect(e)}")
    catch
      :exit, reason ->
        Logger.warning("EventSource #{state.name}: topic #{state.topic} not available: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply, Map.from_struct(state), state}
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp via(name), do: {:via, Registry, {Hive.EventSourceRegistry, name}}

  defp do_poll(state) do
    case System.cmd(state.command, state.args, stderr_to_stdout: true) do
      {output, 0} ->
        hash = :crypto.hash(:sha256, output)

        if hash != state.last_hash do
          do_post_event(state, output)
          schedule_poll(%{state | last_hash: hash, consecutive_failures: 0})
        else
          schedule_poll(%{state | consecutive_failures: 0})
        end

      {error_output, exit_code} ->
        Logger.warning("EventSource #{state.name}: command failed (exit #{exit_code}): #{String.slice(error_output, 0, 200)}")
        failures = state.consecutive_failures + 1
        schedule_poll(%{state | consecutive_failures: failures})
    end
  end

  defp do_post_event(state, raw_payload) do
    {:ok, formatted} = Hive.Connector.Formatter.format(state.name, raw_payload)

    try do
      Hive.Topic.post(state.topic, "system", formatted)
    rescue
      e ->
        Logger.warning("EventSource #{state.name}: failed to post to topic #{state.topic}: #{inspect(e)}")
    catch
      :exit, reason ->
        Logger.warning("EventSource #{state.name}: topic #{state.topic} not available: #{inspect(reason)}")
    end
  end

  defp schedule_poll(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    interval =
      if state.consecutive_failures >= @max_consecutive_failures do
        state.interval_ms * @backoff_multiplier
      else
        state.interval_ms
      end

    ref = Process.send_after(self(), :poll, interval)
    %{state | timer_ref: ref}
  end
end
