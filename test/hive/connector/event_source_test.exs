defmodule Hive.Connector.EventSourceTest do
  use ExUnit.Case, async: false

  alias Hive.Connector.EventSource
  alias Hive.Topic

  setup do
    # Ensure no API key so formatter uses fallback
    Application.put_env(:hive, :anthropic_api_key, nil)

    # Ensure the EventSourceRegistry is running (may already be started by app)
    case Registry.start_link(keys: :unique, name: Hive.EventSourceRegistry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Start a topic for event sources to post to
    topic_name = "es-test-#{:erlang.unique_integer([:positive])}"
    start_supervised!({Topic, name: topic_name, description: "test", type: :topic, created_by: "test"})

    %{topic: topic_name}
  end

  describe "poll event source" do
    test "executes command and posts to topic on output change", %{topic: topic} do
      {:ok, pid} =
        EventSource.start_link(
          name: "poll-test-#{:erlang.unique_integer([:positive])}",
          type: "poll",
          topic: topic,
          config: %{"command" => "echo", "args" => ["hello world"], "interval_ms" => 60_000}
        )

      # Wait for the initial poll to complete
      Process.sleep(200)

      # Check that a message was posted to the topic
      msgs = Topic.recent(topic, 10)
      assert length(msgs) >= 1
      assert Enum.any?(msgs, fn msg -> String.contains?(msg.body, "hello world") end)

      GenServer.stop(pid)
    end

    test "dedup by hash — same output does not produce new message", %{topic: topic} do
      name = "dedup-test-#{:erlang.unique_integer([:positive])}"

      {:ok, pid} =
        EventSource.start_link(
          name: name,
          type: "poll",
          topic: topic,
          config: %{"command" => "echo", "args" => ["stable"], "interval_ms" => 60_000}
        )

      # Wait for initial poll
      Process.sleep(200)

      msgs_before = Topic.recent(topic, 50)
      count_before = length(msgs_before)

      # Trigger another poll manually
      send(pid, :poll)
      Process.sleep(200)

      msgs_after = Topic.recent(topic, 50)
      count_after = length(msgs_after)

      # Same output should not produce another message
      assert count_after == count_before

      GenServer.stop(pid)
    end
  end

  describe "post_event/2" do
    test "formats and posts to topic", %{topic: topic} do
      name = "post-test-#{:erlang.unique_integer([:positive])}"

      {:ok, pid} =
        EventSource.start_link(
          name: name,
          type: "webhook",
          topic: topic,
          config: %{}
        )

      EventSource.post_event(name, "webhook payload arrived")
      Process.sleep(200)

      msgs = Topic.recent(topic, 10)
      assert Enum.any?(msgs, fn msg -> String.contains?(msg.body, "webhook payload arrived") end)

      GenServer.stop(pid)
    end
  end

  describe "start/stop/registration" do
    test "registers in EventSourceRegistry and can be stopped", %{topic: topic} do
      name = "reg-test-#{:erlang.unique_integer([:positive])}"

      {:ok, _pid} =
        EventSource.start_link(
          name: name,
          type: "webhook",
          topic: topic,
          config: %{}
        )

      # Verify registration
      assert [{_pid, _}] = Registry.lookup(Hive.EventSourceRegistry, name)

      # Stop and verify unregistered
      EventSource.stop(name)
      Process.sleep(50)
      assert [] = Registry.lookup(Hive.EventSourceRegistry, name)
    end

    test "info/1 returns state", %{topic: topic} do
      name = "info-test-#{:erlang.unique_integer([:positive])}"

      {:ok, _pid} =
        EventSource.start_link(
          name: name,
          type: "webhook",
          topic: topic,
          config: %{}
        )

      info = EventSource.info(name)
      assert info.name == name
      assert info.type == "webhook"
      assert info.topic == topic
      assert info.consecutive_failures == 0

      EventSource.stop(name)
    end
  end
end
