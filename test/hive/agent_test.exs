defmodule Hive.AgentTest do
  use ExUnit.Case, async: false

  # The Agent GenServer relies on the running application (Persistence, Registries,
  # PubSub, DynamicSupervisors). Tests run with `async: false` and use unique
  # agent names to avoid registry collisions.

  setup do
    Phoenix.PubSub.subscribe(Hive.PubSub, "agents")
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_agent(name, opts \\ []) do
    defaults = [name: name, description: "test agent", personality: "test personality"]
    {:ok, pid} = Hive.Agent.start_link(Keyword.merge(defaults, opts))

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)

      agent_dir = Path.join(["priv", "agents", name]) |> Path.expand()
      File.rm_rf(agent_dir)
    end)

    # Wait for init + catch_up to complete and initial idle status
    assert_receive {:status, ^name, :idle}, 3_000
    pid
  end

  defp get_port(pid) do
    :sys.get_state(pid).sdk_port
  end

  defp inject_port_message(pid, port, data) do
    send(pid, {port, {:data, {:eol, data}}})
  end

  defp read_stderr_log(name) do
    path = Path.join(["priv", "agents", name, "sdk_stderr.log"]) |> Path.expand()

    case File.read(path) do
      {:ok, content} -> content
      _ -> ""
    end
  end

  defp unique_name(label) do
    suffix = :erlang.unique_integer([:positive])
    "t#{suffix}_#{label}"
  end

  # ---------------------------------------------------------------------------
  # 1. Init sends catch-up context (REGRESSION test for Bug 2)
  # ---------------------------------------------------------------------------

  describe "init sends catch-up context" do
    test "agent receives Server restarted message with topic history" do
      name = unique_name("catchup")
      topic_name = unique_name("catchuptopic")

      # Set up persistence state: create topic, agent, subscription, messages
      :ok = Hive.Persistence.create_topic(topic_name, "test topic", "topic")
      :ok = Hive.Persistence.create_agent(name, "test agent", "test personality")
      :ok = Hive.Persistence.subscribe(topic_name, name)
      Hive.Persistence.write_message(topic_name, "human", "hello from before restart")
      Hive.Persistence.write_message(topic_name, "human", "another old message")
      # Flush persistence casts
      :sys.get_state(Hive.Persistence)

      # Now start the agent — init should build catch-up from subscribed topics
      pid = start_agent(name)
      assert Process.alive?(pid)

      # The mock SDK emits thinking->idle per batch. Wait for the catch-up
      # processing cycle to complete (initial idle + catch-up thinking + idle).
      # We already consumed the first idle in start_agent. The catch-up batch
      # should produce thinking then idle.
      assert_receive {:status, ^name, :thinking}, 3_000
      assert_receive {:status, ^name, :idle}, 3_000

      # Read stderr log to verify the mock SDK received the catch-up batch
      Process.sleep(200)
      stderr = read_stderr_log(name)
      assert stderr =~ "Server restarted"
      assert stderr =~ "hello from before restart"
      assert stderr =~ "another old message"
      assert stderr =~ topic_name

      # Cleanup persistence
      on_exit(fn ->
        Hive.Persistence.delete_agent(name)
        Hive.Persistence.delete_topic(topic_name)
      end)
    end

    test "agent with no subscriptions does not send catch-up" do
      name = unique_name("nocatchup")
      :ok = Hive.Persistence.create_agent(name, "test", "test")

      pid = start_agent(name)
      assert Process.alive?(pid)

      # Give time for any potential catch-up to arrive
      Process.sleep(300)
      stderr = read_stderr_log(name)

      # No batch should contain "Server restarted" — either empty or no batch
      refute stderr =~ "Server restarted"

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Port eol/noeol line reassembly
  # ---------------------------------------------------------------------------

  describe "port eol/noeol line reassembly" do
    test "noeol partials are buffered and combined with eol to parse JSON" do
      name = unique_name("lineasm")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      pid = start_agent(name)
      port = get_port(pid)

      # Verify line_buffer starts empty
      assert :sys.get_state(pid).line_buffer == ""

      # Send a partial (noeol) then the rest (eol)
      json = Jason.encode!(%{"type" => "session", "sessionId" => "reassembled-42"})
      {first_half, second_half} = String.split_at(json, div(String.length(json), 2))

      send(pid, {port, {:data, {:noeol, first_half}}})
      Process.sleep(50)

      # Buffer should contain the partial
      assert :sys.get_state(pid).line_buffer == first_half

      # Complete the line
      send(pid, {port, {:data, {:eol, second_half}}})
      Process.sleep(50)

      # Buffer should be cleared after successful parse
      assert :sys.get_state(pid).line_buffer == ""

      # Session ID should be updated
      info = Hive.Agent.info(name)
      assert info.session_id == "reassembled-42"

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end

    test "multiple noeol chunks accumulate before eol" do
      name = unique_name("multinoeol")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      pid = start_agent(name)
      port = get_port(pid)

      json = Jason.encode!(%{"type" => "session", "sessionId" => "multi-chunk-99"})
      chunk_size = div(String.length(json), 3)
      chunk1 = String.slice(json, 0, chunk_size)
      chunk2 = String.slice(json, chunk_size, chunk_size)
      chunk3 = String.slice(json, chunk_size * 2, String.length(json))

      send(pid, {port, {:data, {:noeol, chunk1}}})
      Process.sleep(20)
      send(pid, {port, {:data, {:noeol, chunk2}}})
      Process.sleep(20)
      send(pid, {port, {:data, {:eol, chunk3}}})
      Process.sleep(50)

      assert :sys.get_state(pid).line_buffer == ""
      assert Hive.Agent.info(name).session_id == "multi-chunk-99"

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Status transitions + PubSub
  # ---------------------------------------------------------------------------

  describe "status transitions and PubSub" do
    test "injected status JSON broadcasts on PubSub and updates state" do
      name = unique_name("status")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      pid = start_agent(name)
      port = get_port(pid)

      # Inject thinking status
      inject_port_message(pid, port, Jason.encode!(%{"type" => "status", "status" => "thinking"}))
      assert_receive {:status, ^name, :thinking}, 1_000
      assert Hive.Agent.status(name) == :thinking

      # Inject idle status
      inject_port_message(pid, port, Jason.encode!(%{"type" => "status", "status" => "idle"}))
      assert_receive {:status, ^name, :idle}, 1_000
      assert Hive.Agent.status(name) == :idle

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end

    test "initial status after start is idle" do
      name = unique_name("initstatus")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      _pid = start_agent(name)

      assert Hive.Agent.status(name) == :idle

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Session tracking
  # ---------------------------------------------------------------------------

  describe "session tracking" do
    test "session JSON updates session_id in state" do
      name = unique_name("session")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      pid = start_agent(name)
      port = get_port(pid)

      # Inject session with sessionId key
      inject_port_message(
        pid,
        port,
        Jason.encode!(%{"type" => "session", "sessionId" => "sess-abc"})
      )

      Process.sleep(50)
      assert Hive.Agent.info(name).session_id == "sess-abc"

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end

    test "session JSON with session_id key also works" do
      name = unique_name("sessalt")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      pid = start_agent(name)
      port = get_port(pid)

      inject_port_message(
        pid,
        port,
        Jason.encode!(%{"type" => "session", "session_id" => "sess-xyz"})
      )

      Process.sleep(50)
      assert Hive.Agent.info(name).session_id == "sess-xyz"

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end

    test "session_id starts as nil" do
      name = unique_name("sessinit")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      _pid = start_agent(name)

      # The mock SDK emits a session on first batch, but if no catch-up was sent
      # (no subscriptions), session_id stays nil until the mock processes something.
      # With no subscriptions, there's no catch-up batch, so session_id remains nil.
      info = Hive.Agent.info(name)
      assert info.session_id == nil

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end
  end

  # ---------------------------------------------------------------------------
  # 5. SDK crash recovery
  # ---------------------------------------------------------------------------

  describe "SDK crash recovery" do
    test "SDK process exit triggers restart with preserved session_id" do
      name = unique_name("crash")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      pid = start_agent(name)
      port = get_port(pid)

      # Set a session_id first
      inject_port_message(
        pid,
        port,
        Jason.encode!(%{"type" => "session", "sessionId" => "before-crash"})
      )

      Process.sleep(50)
      assert Hive.Agent.info(name).session_id == "before-crash"

      # Kill the OS process to simulate SDK crash — this triggers exit_status
      # on the port (unlike Port.close which just closes the Erlang side).
      {:os_pid, os_pid} = List.keyfind(Port.info(port), :os_pid, 0)
      System.cmd("kill", [to_string(os_pid)])

      # The Agent should get {:exit_status, _} and start a new port.
      # Wait for the restart log message to confirm handling.
      Process.sleep(500)
      assert Process.alive?(pid)

      # The new port should be alive and functional
      new_port = get_port(pid)
      assert Port.info(new_port) != nil

      # Session ID should be preserved through the crash
      assert Hive.Agent.info(name).session_id == "before-crash"

      # Verify the new SDK subprocess is responsive: inject a message and check
      inject_port_message(
        pid,
        new_port,
        Jason.encode!(%{"type" => "session", "sessionId" => "after-crash"})
      )

      Process.sleep(50)
      assert Hive.Agent.info(name).session_id == "after-crash"

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end

    test "agent remains functional after SDK crash recovery" do
      name = unique_name("crashfunc")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      pid = start_agent(name)
      port = get_port(pid)

      # Kill the OS process to simulate crash
      {:os_pid, os_pid} = List.keyfind(Port.info(port), :os_pid, 0)
      System.cmd("kill", [to_string(os_pid)])
      Process.sleep(500)

      assert Process.alive?(pid)
      new_port = get_port(pid)
      assert Port.info(new_port) != nil

      # Inject a status message on the new port — agent should handle it
      inject_port_message(
        pid,
        new_port,
        Jason.encode!(%{"type" => "status", "status" => "thinking"})
      )

      assert_receive {:status, ^name, :thinking}, 1_000

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end
  end

  # ---------------------------------------------------------------------------
  # 6. Topic/DM message delivery
  # ---------------------------------------------------------------------------

  describe "topic and DM message delivery" do
    test "topic_message is forwarded to SDK" do
      name = unique_name("topmsg")
      topic_name = unique_name("topmsgtopic")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      pid = start_agent(name)

      # Send a topic message from another sender
      msg = %{sender: "human", sender_kind: "human", body: "hello agent", ts: DateTime.utc_now()}
      send(pid, {:topic_message, topic_name, msg})

      # Wait for the mock SDK to process
      assert_receive {:status, ^name, :thinking}, 3_000
      assert_receive {:status, ^name, :idle}, 3_000

      Process.sleep(200)
      stderr = read_stderr_log(name)
      assert stderr =~ "hello agent"
      assert stderr =~ "[message]"
      assert stderr =~ "channel_type=topic"
      assert stderr =~ "channel_name=#{topic_name}"

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end

    test "self-messages are filtered and not sent to SDK" do
      name = unique_name("selfmsg")
      topic_name = unique_name("selfmsgtopic")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      pid = start_agent(name)

      # Wait for any catch-up to complete, then capture the current stderr size
      Process.sleep(300)
      stderr_before = read_stderr_log(name)

      # Send a message where sender == agent name (self-message)
      msg = %{sender: name, sender_kind: "agent", body: "my own message", ts: DateTime.utc_now()}
      send(pid, {:topic_message, topic_name, msg})

      # Give time for potential processing
      Process.sleep(300)
      stderr_after = read_stderr_log(name)

      # No new batch should contain the self-message
      new_output = String.replace_prefix(stderr_after, stderr_before, "")
      refute new_output =~ "my own message"

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end

    test "dm_message is forwarded to SDK" do
      name = unique_name("dmmsg")
      channel = "dm:#{name}:someone"
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      pid = start_agent(name)

      msg = %{
        sender: "someone",
        sender_kind: "agent",
        body: "private hello",
        ts: DateTime.utc_now()
      }

      send(pid, {:dm_message, channel, msg})

      assert_receive {:status, ^name, :thinking}, 3_000
      assert_receive {:status, ^name, :idle}, 3_000

      Process.sleep(200)
      stderr = read_stderr_log(name)
      assert stderr =~ "private hello"
      assert stderr =~ "channel_type=dm"

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end
  end

  # ---------------------------------------------------------------------------
  # 6b. Topic join/leave state sync (REGRESSION: Agent topics MapSet not updated)
  # ---------------------------------------------------------------------------

  describe "topic join/leave state sync" do
    test "topic_joined message adds topic to agent's topics set" do
      name = unique_name("joinsync")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      pid = start_agent(name)

      refute "new-topic" in Hive.Agent.info(name).topics

      send(pid, {:topic_joined, "new-topic"})
      Process.sleep(50)

      assert "new-topic" in Hive.Agent.info(name).topics

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end

    test "topic_left message removes topic from agent's topics set" do
      name = unique_name("leavesync")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      pid = start_agent(name)

      send(pid, {:topic_joined, "ephemeral"})
      Process.sleep(50)
      assert "ephemeral" in Hive.Agent.info(name).topics

      send(pid, {:topic_left, "ephemeral"})
      Process.sleep(50)
      refute "ephemeral" in Hive.Agent.info(name).topics

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end
  end

  # ---------------------------------------------------------------------------
  # 7. Mention invite
  # ---------------------------------------------------------------------------

  describe "mention invite" do
    test "mention_invite updates topics and sends context to SDK" do
      name = unique_name("mention")
      topic_name = unique_name("mentiontopic")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      pid = start_agent(name)

      # Agent should not be subscribed to the topic initially
      info_before = Hive.Agent.info(name)
      refute topic_name in info_before.topics

      # Send mention_invite with some recent messages
      recent = [
        %{sender: "alice", sender_kind: "agent", body: "context msg 1", ts: DateTime.utc_now()},
        %{sender: "bob", sender_kind: "agent", body: "context msg 2", ts: DateTime.utc_now()}
      ]

      send(pid, {:mention_invite, topic_name, recent})

      # Wait for SDK processing
      assert_receive {:status, ^name, :thinking}, 3_000
      assert_receive {:status, ^name, :idle}, 3_000

      # Topic should now be in agent's topics
      info_after = Hive.Agent.info(name)
      assert topic_name in info_after.topics

      # SDK should have received the mention_invite block
      Process.sleep(200)
      stderr = read_stderr_log(name)
      assert stderr =~ "[mention_invite]"
      assert stderr =~ "topic=#{topic_name}"
      assert stderr =~ "context msg 1"
      assert stderr =~ "context msg 2"

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end
  end

  # ---------------------------------------------------------------------------
  # 8. Typing indicators
  # ---------------------------------------------------------------------------

  describe "typing indicators" do
    test "topic_message triggers typing=true, idle status triggers typing=false" do
      name = unique_name("typing")
      topic_name = unique_name("typingtopic")
      :ok = Hive.Persistence.create_agent(name, "test", "test")

      Phoenix.PubSub.subscribe(Hive.PubSub, "topic:#{topic_name}")

      pid = start_agent(name)
      port = get_port(pid)

      # Send a topic message from someone else
      msg = %{
        sender: "human",
        sender_kind: "human",
        body: "trigger typing",
        ts: DateTime.utc_now()
      }

      send(pid, {:topic_message, topic_name, msg})

      # Should receive typing=true broadcast
      assert_receive {:typing, %{topic: ^topic_name, agent: ^name, typing: true}}, 1_000

      # Inject idle status to stop typing
      inject_port_message(pid, port, Jason.encode!(%{"type" => "status", "status" => "idle"}))

      # Should receive typing=false broadcast (after 3s grace period)
      assert_receive {:typing, %{topic: ^topic_name, agent: ^name, typing: false}}, 5_000

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end

    test "self-message does not trigger typing" do
      name = unique_name("selftyp")
      topic_name = unique_name("selftyptopic")
      :ok = Hive.Persistence.create_agent(name, "test", "test")

      Phoenix.PubSub.subscribe(Hive.PubSub, "topic:#{topic_name}")

      pid = start_agent(name)

      # Send self-message
      msg = %{sender: name, sender_kind: "agent", body: "self", ts: DateTime.utc_now()}
      send(pid, {:topic_message, topic_name, msg})

      # Should NOT receive typing broadcast
      refute_receive {:typing, %{agent: ^name}}, 300

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end
  end

  # ---------------------------------------------------------------------------
  # 9. active_channel tracking
  # ---------------------------------------------------------------------------

  describe "active_channel tracking" do
    test "topic_message sets active_channel" do
      name = unique_name("actchan")
      topic_name = unique_name("actchantopic")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      pid = start_agent(name)

      msg = %{sender: "human", sender_kind: "human", body: "hi", ts: DateTime.utc_now()}
      send(pid, {:topic_message, topic_name, msg})
      Process.sleep(50)

      assert Hive.Agent.active_channel(name) == {"topic", topic_name}

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end

    test "idle preserves active_channel" do
      name = unique_name("actpreserve")
      topic_name = unique_name("actpreservetop")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      pid = start_agent(name)
      port = get_port(pid)

      # Set active channel via message
      msg = %{sender: "human", sender_kind: "human", body: "hi", ts: DateTime.utc_now()}
      send(pid, {:topic_message, topic_name, msg})
      Process.sleep(50)
      assert Hive.Agent.active_channel(name) == {"topic", topic_name}

      # Go idle
      inject_port_message(pid, port, Jason.encode!(%{"type" => "status", "status" => "idle"}))
      Process.sleep(50)

      # Channel should be preserved on idle (preserve_channel: true)
      assert Hive.Agent.active_channel(name) == {"topic", topic_name}

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end

    test "new message from different channel clears old active_channel" do
      name = unique_name("actswitch")
      topic_a = unique_name("actswitcha")
      topic_b = unique_name("actswitchb")
      :ok = Hive.Persistence.create_agent(name, "test", "test")

      Phoenix.PubSub.subscribe(Hive.PubSub, "topic:#{topic_a}")
      Phoenix.PubSub.subscribe(Hive.PubSub, "topic:#{topic_b}")

      pid = start_agent(name)

      # Message on topic A
      msg_a = %{sender: "human", sender_kind: "human", body: "hi a", ts: DateTime.utc_now()}
      send(pid, {:topic_message, topic_a, msg_a})
      Process.sleep(50)
      assert Hive.Agent.active_channel(name) == {"topic", topic_a}

      # Message on topic B should switch channel and clear typing on A
      msg_b = %{sender: "human", sender_kind: "human", body: "hi b", ts: DateTime.utc_now()}
      send(pid, {:topic_message, topic_b, msg_b})

      # typing=false on old channel
      assert_receive {:typing, %{topic: ^topic_a, agent: ^name, typing: false}}, 1_000
      # typing=true on new channel
      assert_receive {:typing, %{topic: ^topic_b, agent: ^name, typing: true}}, 1_000

      assert Hive.Agent.active_channel(name) == {"topic", topic_b}

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end

    test "self-message does not change active_channel" do
      name = unique_name("actselfnoop")
      topic_name = unique_name("actselfnooptop")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      pid = start_agent(name)

      # active_channel should be nil initially
      assert Hive.Agent.active_channel(name) == nil

      # Self-message
      msg = %{sender: name, sender_kind: "agent", body: "self", ts: DateTime.utc_now()}
      send(pid, {:topic_message, topic_name, msg})
      Process.sleep(50)

      # Should still be nil — self-messages skip maybe_start_activity because
      # the Agent filters them before send_to_sdk, but maybe_start_activity is
      # called first. Actually, looking at the code, maybe_start_activity returns
      # state unchanged when sender == name. So active_channel stays nil.
      assert Hive.Agent.active_channel(name) == nil

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end

    test "dm_message sets active_channel with dm type" do
      name = unique_name("actdm")
      channel = "dm:#{name}:other"
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      pid = start_agent(name)

      msg = %{sender: "other", sender_kind: "agent", body: "dm hi", ts: DateTime.utc_now()}
      send(pid, {:dm_message, channel, msg})
      Process.sleep(50)

      assert Hive.Agent.active_channel(name) == {"dm", channel}

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end
  end

  # ---------------------------------------------------------------------------
  # 10. Multi-line message integrity (REGRESSION test for Bug 1, Elixir side)
  # ---------------------------------------------------------------------------

  describe "multi-line message integrity" do
    test "multi-line message body is received as single batch by SDK" do
      name = unique_name("multiline")
      topic_name = unique_name("multilinetopic")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      :ok = Hive.Persistence.create_topic(topic_name, "test", "topic")

      # Start a real topic so we can post through it
      {:ok, topic_pid} =
        Hive.Topic.start_link(
          name: topic_name,
          description: "test",
          type: :topic,
          created_by: "human"
        )

      _pid = start_agent(name)

      # Register the agent in AgentRegistry so Topic can deliver to it
      # (Agent already registers itself via `via`, so this is already done)

      # Join the topic
      Hive.Topic.join(topic_name, name)

      # Wait for any initial processing to settle
      Process.sleep(300)
      stderr_before = read_stderr_log(name)

      # Post a multi-line message
      multi_line_body = "line one\nline two\nline three\nline four"
      Hive.Topic.post(topic_name, "human", multi_line_body)

      # Wait for SDK to process
      assert_receive {:status, ^name, :thinking}, 3_000
      assert_receive {:status, ^name, :idle}, 3_000

      Process.sleep(200)
      stderr_after = read_stderr_log(name)
      new_output = String.replace_prefix(stderr_after, stderr_before, "")

      # The batch should contain ALL lines of the message body together
      assert new_output =~ "line one"
      assert new_output =~ "line two"
      assert new_output =~ "line three"
      assert new_output =~ "line four"

      # The [message] and [/message] tags should be in the same batch
      assert new_output =~ "[message]"
      assert new_output =~ "[/message]"

      on_exit(fn ->
        if Process.alive?(topic_pid), do: GenServer.stop(topic_pid, :normal, 1_000)
        Hive.Persistence.delete_agent(name)
        Hive.Persistence.delete_topic(topic_name)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # 11. Terminate cleans up port
  # ---------------------------------------------------------------------------

  describe "terminate cleans up port" do
    test "stopping agent closes the port and process is gone" do
      name = unique_name("terminate")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      pid = start_agent(name)
      port = get_port(pid)

      # Verify the port is open
      assert Port.info(port) != nil

      # Stop the agent gracefully — bypass the on_exit from start_agent by
      # stopping directly and then checking state.
      GenServer.stop(pid, :normal, 1_000)

      # Process should be dead
      refute Process.alive?(pid)

      # Port should be closed (terminate calls Port.close)
      assert Port.info(port) == nil

      on_exit(fn ->
        Hive.Persistence.delete_agent(name)

        agent_dir = Path.join(["priv", "agents", name]) |> Path.expand()
        File.rm_rf(agent_dir)
      end)
    end

    test "terminate is safe even if port is already closed" do
      name = unique_name("termsafe")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      pid = start_agent(name)
      port = get_port(pid)

      # Kill the OS process — the port closes from the OS side and sends
      # exit_status. The agent restarts the SDK port in the exit_status handler.
      {:os_pid, os_pid} = List.keyfind(Port.info(port), :os_pid, 0)
      System.cmd("kill", [to_string(os_pid)])
      Process.sleep(500)

      # Agent should still be alive (it recovered from the crash)
      assert Process.alive?(pid)

      # The new port should be alive and functional
      new_port = get_port(pid)
      assert Port.info(new_port) != nil

      # Now stop agent gracefully — should not crash
      GenServer.stop(pid, :normal, 1_000)
      refute Process.alive?(pid)

      # New port should be closed by terminate
      assert Port.info(new_port) == nil

      on_exit(fn ->
        Hive.Persistence.delete_agent(name)

        agent_dir = Path.join(["priv", "agents", name]) |> Path.expand()
        File.rm_rf(agent_dir)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Public API: info/1
  # ---------------------------------------------------------------------------

  describe "info/1" do
    test "returns complete agent info map" do
      name = unique_name("info")
      :ok = Hive.Persistence.create_agent(name, "info desc", "info personality")
      _pid = start_agent(name, description: "info desc", personality: "info personality")

      info = Hive.Agent.info(name)
      assert info.name == name
      assert info.description == "info desc"
      assert info.status == :idle
      assert is_list(info.topics)
      assert is_list(info.dms)
      assert Map.has_key?(info, :session_id)
      assert Map.has_key?(info, :active_channel)

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end
  end

  # ---------------------------------------------------------------------------
  # Public API: inject_message/2
  # ---------------------------------------------------------------------------

  describe "inject_message/2" do
    test "system message is forwarded to SDK as [system] block" do
      name = unique_name("inject")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      _pid = start_agent(name)

      Process.sleep(200)
      stderr_before = read_stderr_log(name)

      Hive.Agent.inject_message(name, "Container abc123 completed successfully")

      assert_receive {:status, ^name, :thinking}, 3_000
      assert_receive {:status, ^name, :idle}, 3_000

      Process.sleep(200)
      stderr_after = read_stderr_log(name)
      new_output = String.replace_prefix(stderr_after, stderr_before, "")

      assert new_output =~ "[system]"
      assert new_output =~ "Container abc123 completed successfully"
      assert new_output =~ "[/system]"

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end
  end

  # ---------------------------------------------------------------------------
  # Error JSON handling
  # ---------------------------------------------------------------------------

  describe "error JSON from SDK" do
    test "error type message is handled without crash" do
      name = unique_name("sdkerr")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      pid = start_agent(name)
      port = get_port(pid)

      # Inject an error message
      inject_port_message(
        pid,
        port,
        Jason.encode!(%{"type" => "error", "message" => "test error"})
      )

      Process.sleep(50)

      # Agent should still be alive and functional
      assert Process.alive?(pid)
      assert Hive.Agent.status(name) == :idle

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end

    test "unrecognized JSON is handled without crash" do
      name = unique_name("unrecog")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      pid = start_agent(name)
      port = get_port(pid)

      inject_port_message(pid, port, Jason.encode!(%{"type" => "unknown", "data" => "foo"}))
      Process.sleep(50)

      assert Process.alive?(pid)

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end

    test "non-JSON output is handled without crash" do
      name = unique_name("nonjson")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      pid = start_agent(name)
      port = get_port(pid)

      inject_port_message(pid, port, "this is not json at all")
      Process.sleep(50)

      assert Process.alive?(pid)

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end
  end

  # ---------------------------------------------------------------------------
  # Scratchpad: thinking events
  # ---------------------------------------------------------------------------

  describe "scratchpad thinking events" do
    test "thinking JSON from port is pushed to scratchpad and broadcast" do
      name = unique_name("scrthink")
      :ok = Hive.Persistence.create_agent(name, "test", "test")

      Phoenix.PubSub.subscribe(Hive.PubSub, "agent:scratchpad:#{name}")

      pid = start_agent(name)
      port = get_port(pid)

      inject_port_message(
        pid,
        port,
        Jason.encode!(%{"type" => "thinking", "text" => "Let me consider..."})
      )

      # Should receive PubSub broadcast (thinking uses :scratchpad_thinking for merging)
      assert_receive {:scratchpad_thinking, ^name, {:thinking, "Let me consider...", _ts}}, 1_000

      # Should be in scratchpad
      scratchpad = Hive.Agent.scratchpad(name)
      assert length(scratchpad) == 1
      assert {:thinking, "Let me consider...", _ts} = hd(scratchpad)

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end
  end

  # ---------------------------------------------------------------------------
  # Scratchpad: tool_use_start events
  # ---------------------------------------------------------------------------

  describe "scratchpad tool_use_start events" do
    test "tool_use_start JSON is pushed to scratchpad" do
      name = unique_name("scrtool")
      :ok = Hive.Persistence.create_agent(name, "test", "test")

      Phoenix.PubSub.subscribe(Hive.PubSub, "agent:scratchpad:#{name}")

      pid = start_agent(name)
      port = get_port(pid)

      inject_port_message(
        pid,
        port,
        Jason.encode!(%{
          "type" => "tool_use_start",
          "toolName" => "Bash",
          "toolInput" => %{"command" => "ls -la"},
          "toolUseId" => "tu_123"
        })
      )

      assert_receive {:scratchpad, ^name,
                      {:tool_use, "Bash", %{"command" => "ls -la"}, "tu_123", _ts}},
                     1_000

      scratchpad = Hive.Agent.scratchpad(name)
      assert length(scratchpad) == 1
      assert {:tool_use, "Bash", %{"command" => "ls -la"}, "tu_123", _ts} = hd(scratchpad)

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end
  end

  # ---------------------------------------------------------------------------
  # Scratchpad: tool_result events
  # ---------------------------------------------------------------------------

  describe "scratchpad tool_result events" do
    test "tool_result JSON is pushed to scratchpad" do
      name = unique_name("scrtoolr")
      :ok = Hive.Persistence.create_agent(name, "test", "test")

      Phoenix.PubSub.subscribe(Hive.PubSub, "agent:scratchpad:#{name}")

      pid = start_agent(name)
      port = get_port(pid)

      inject_port_message(
        pid,
        port,
        Jason.encode!(%{
          "type" => "tool_result",
          "toolUseId" => "tu_456",
          "output" => "file1.txt\nfile2.txt"
        })
      )

      assert_receive {:scratchpad, ^name, {:tool_result, "tu_456", "file1.txt\nfile2.txt", _ts}},
                     1_000

      scratchpad = Hive.Agent.scratchpad(name)
      assert length(scratchpad) == 1
      assert {:tool_result, "tu_456", "file1.txt\nfile2.txt", _ts} = hd(scratchpad)

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end
  end

  # ---------------------------------------------------------------------------
  # Scratchpad: API returns events
  # ---------------------------------------------------------------------------

  describe "scratchpad/1 API" do
    test "returns accumulated events in reverse chronological order" do
      name = unique_name("scrapi")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      pid = start_agent(name)
      port = get_port(pid)

      inject_port_message(
        pid,
        port,
        Jason.encode!(%{"type" => "thinking", "text" => "first"})
      )

      Process.sleep(20)

      inject_port_message(
        pid,
        port,
        Jason.encode!(%{"type" => "text", "text" => "second"})
      )

      Process.sleep(20)

      inject_port_message(
        pid,
        port,
        Jason.encode!(%{
          "type" => "tool_use_start",
          "toolName" => "Read",
          "toolInput" => %{},
          "toolUseId" => "tu_789"
        })
      )

      Process.sleep(20)

      scratchpad = Hive.Agent.scratchpad(name)
      assert length(scratchpad) == 3

      # Most recent first (prepended)
      assert {:tool_use, "Read", %{}, "tu_789", _} = Enum.at(scratchpad, 0)
      assert {:text, "second", _} = Enum.at(scratchpad, 1)
      assert {:thinking, "first", _} = Enum.at(scratchpad, 2)

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end
  end

  # ---------------------------------------------------------------------------
  # Scratchpad: ring buffer limit
  # ---------------------------------------------------------------------------

  describe "scratchpad ring buffer" do
    test "keeps only last 100 events when limit exceeded" do
      name = unique_name("scrlimit")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      pid = start_agent(name)
      port = get_port(pid)

      # Push 110 tool_use events (non-mergeable, each has a unique id)
      for i <- 1..110 do
        inject_port_message(
          pid,
          port,
          Jason.encode!(%{
            "type" => "tool_use_start",
            "toolName" => "tool-#{i}",
            "toolInput" => %{"n" => i},
            "toolUseId" => "id-#{i}"
          })
        )

        # Small delay so messages are processed sequentially
        Process.sleep(5)
      end

      Process.sleep(50)
      scratchpad = Hive.Agent.scratchpad(name)
      assert length(scratchpad) == 100

      # Most recent event should be tool-110 (first in list since prepended)
      assert {:tool_use, "tool-110", _, _, _} = hd(scratchpad)

      # Oldest should be tool-11 (events 1-10 were evicted)
      assert {:tool_use, "tool-11", _, _, _} = List.last(scratchpad)

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end
  end

  # ---------------------------------------------------------------------------
  # Scratchpad: clears on new thinking cycle
  # ---------------------------------------------------------------------------

  describe "scratchpad clears on new thinking cycle" do
    test "scratchpad clears when thinking event arrives while status is idle" do
      name = unique_name("scrclear")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      pid = start_agent(name)
      port = get_port(pid)

      # Push some events from the first turn
      inject_port_message(
        pid,
        port,
        Jason.encode!(%{"type" => "thinking", "text" => "old thought"})
      )

      Process.sleep(20)

      inject_port_message(
        pid,
        port,
        Jason.encode!(%{"type" => "text", "text" => "old text"})
      )

      Process.sleep(20)
      assert length(Hive.Agent.scratchpad(name)) == 2

      # Agent status is still :idle (status events come from SDK, not scratchpad events)
      # So the next thinking event should clear the scratchpad
      inject_port_message(
        pid,
        port,
        Jason.encode!(%{"type" => "thinking", "text" => "new thought"})
      )

      Process.sleep(20)
      scratchpad = Hive.Agent.scratchpad(name)

      # Scratchpad should have been cleared and only contain the new event
      assert length(scratchpad) == 1
      assert {:thinking, "new thought", _} = hd(scratchpad)

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end

    test "scratchpad does NOT clear when thinking arrives during thinking status" do
      name = unique_name("scrnoclr")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      pid = start_agent(name)
      port = get_port(pid)

      # Transition to thinking status first
      inject_port_message(
        pid,
        port,
        Jason.encode!(%{"type" => "status", "status" => "thinking"})
      )

      assert_receive {:status, ^name, :thinking}, 1_000

      # Push some scratchpad events while thinking
      inject_port_message(
        pid,
        port,
        Jason.encode!(%{"type" => "thinking", "text" => "thought A"})
      )

      Process.sleep(20)

      inject_port_message(
        pid,
        port,
        Jason.encode!(%{"type" => "thinking", "text" => "thought B"})
      )

      Process.sleep(20)
      scratchpad = Hive.Agent.scratchpad(name)

      # Consecutive thinking chunks are merged into a single event
      assert length(scratchpad) == 1
      assert {:thinking, "thought A" <> "thought B", _ts} = hd(scratchpad)

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end
  end

  # ---------------------------------------------------------------------------
  # Scratchpad: info includes scratchpad_count
  # ---------------------------------------------------------------------------

  describe "info includes scratchpad_count" do
    test "info/1 returns scratchpad_count field" do
      name = unique_name("scrinfo")
      :ok = Hive.Persistence.create_agent(name, "test", "test")
      pid = start_agent(name)
      port = get_port(pid)

      info = Hive.Agent.info(name)
      assert info.scratchpad_count == 0

      inject_port_message(
        pid,
        port,
        Jason.encode!(%{"type" => "text", "text" => "hello"})
      )

      Process.sleep(20)

      info = Hive.Agent.info(name)
      assert info.scratchpad_count == 1

      on_exit(fn -> Hive.Persistence.delete_agent(name) end)
    end
  end
end
