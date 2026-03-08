defmodule Hive.IntegrationTest do
  @moduledoc """
  Integration tests that verify multiple Hive modules working together.

  These tests spin up a real Persistence GenServer (with a temp SQLite DB),
  the TopicRegistry, AgentRegistry, PubSub, and TopicSup — then exercise
  cross-module flows end-to-end.
  """

  use ExUnit.Case, async: false

  alias Hive.Persistence
  alias Hive.Topic
  alias Hive.Validation

  # ── Setup ──────────────────────────────────────────────────────────────

  setup do
    # The application supervisor already starts these globally:
    #   - Hive.PubSub
    #   - Hive.TopicRegistry
    #   - Hive.AgentRegistry
    #   - Hive.ContainerRegistry
    #   - Hive.TopicSup
    #   - Hive.Persistence (default name)
    #
    # For integration tests we need Persistence under its default name
    # (Hive.Persistence) so that Topic GenServers can find it.
    # The app-level Persistence is already running, so we use it directly
    # but clean up any test data we create.

    # Generate unique prefixes to avoid collisions between tests and across VM restarts
    ts = rem(System.system_time(:millisecond), 100_000)
    n = :erlang.unique_integer([:positive])
    prefix = "it#{ts}x#{n}"

    on_exit(fn ->
      # Clean up all agents/topics/etc we may have created.
      # Persistence and registries survive across tests, but may have been
      # shut down if the application stopped. Guard against that.
      try do
        cleanup_agents(prefix)
        cleanup_topics(prefix)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end

      # Unregister any agent entries this test may have put in AgentRegistry
      for suffix <- ~w(alice bob charlie dave sender) do
        try do
          Registry.unregister(Hive.AgentRegistry, "#{prefix}-#{suffix}")
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{p: prefix}
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp cleanup_agents(prefix) do
    case Persistence.get_agents() do
      {:ok, agents} ->
        agents
        |> Enum.filter(&String.starts_with?(&1.name, prefix))
        |> Enum.each(&Persistence.delete_agent(&1.name))

      _ ->
        :ok
    end
  end

  defp cleanup_topics(prefix) do
    case Persistence.get_topics() do
      {:ok, topics} ->
        topics
        |> Enum.filter(&String.starts_with?(&1.name, prefix))
        |> Enum.each(fn t ->
          # Stop the Topic GenServer if running
          case Registry.lookup(Hive.TopicRegistry, t.name) do
            [{pid, _}] -> GenServer.stop(pid, :normal)
            [] -> :ok
          end

          Persistence.delete_topic(t.name)
        end)

      _ ->
        :ok
    end

    # Also clean up DM topics
    case Persistence.get_topics() do
      {:ok, topics} ->
        topics
        |> Enum.filter(&String.contains?(&1.name, prefix))
        |> Enum.each(fn t ->
          case Registry.lookup(Hive.TopicRegistry, t.name) do
            [{pid, _}] -> GenServer.stop(pid, :normal)
            [] -> :ok
          end

          Persistence.delete_topic(t.name)
        end)

      _ ->
        :ok
    end
  end

  defp start_topic(name, opts \\ []) do
    defaults = [
      name: name,
      description: "integration test topic",
      type: :topic,
      created_by: "test"
    ]

    start_supervised!({Topic, Keyword.merge(defaults, opts)})
  end

  defp agent_name(prefix, suffix), do: "#{prefix}-#{suffix}"
  defp topic_name(prefix, suffix), do: "#{prefix}-#{suffix}"

  # ── 1. Full message flow ──────────────────────────────────────────────

  describe "full message flow" do
    test "message is persisted, buffered, and broadcast", %{p: p} do
      agent = agent_name(p, "alice")
      topic = topic_name(p, "general")

      # Create agent and topic in persistence
      :ok = Persistence.create_agent(agent, "Test agent", "Helpful")
      :ok = Persistence.create_topic(topic, "General chat", "topic", nil)

      # Start the Topic GenServer
      start_topic(topic)

      # Subscribe to PubSub for broadcasts
      Phoenix.PubSub.subscribe(Hive.PubSub, "topic:#{topic}")

      # Subscribe the agent to the topic
      {:ok, []} = Topic.join(topic, agent)

      # Post a message
      :ok = Topic.post(topic, agent, "hello world")

      # Wait for persistence cast to complete
      :sys.get_state(Hive.Persistence)

      # 1) Verify message is persisted in SQLite
      {:ok, msgs} = Persistence.get_messages(topic, 50)
      assert length(msgs) >= 1
      last = List.last(msgs)
      assert last.sender == agent
      assert last.body == "hello world"

      # 2) Verify message appears in the ring buffer
      [buffered] = Topic.recent(topic, 1)
      assert buffered.sender == agent
      assert buffered.body == "hello world"

      # 3) Verify PubSub broadcast occurred
      assert_receive {:message,
                      %{topic: ^topic, sender: ^agent, body: "hello world", ts: %DateTime{}}}
    end

    test "multiple messages maintain order in persistence and buffer", %{p: p} do
      agent = agent_name(p, "alice")
      topic = topic_name(p, "ordered")

      :ok = Persistence.create_agent(agent, "d", "p")
      :ok = Persistence.create_topic(topic, "d", "topic", nil)
      start_topic(topic)
      {:ok, _} = Topic.join(topic, agent)

      for i <- 1..5 do
        :ok = Topic.post(topic, agent, "msg #{i}")
      end

      :sys.get_state(Hive.Persistence)

      # Persistence returns ASC order
      {:ok, msgs} = Persistence.get_messages(topic, 50)
      bodies = Enum.map(msgs, & &1.body)
      assert bodies == ["msg 1", "msg 2", "msg 3", "msg 4", "msg 5"]

      # Ring buffer returns most-recent-first
      recent = Topic.recent(topic, 5)
      recent_bodies = Enum.map(recent, & &1.body)
      assert recent_bodies == ["msg 5", "msg 4", "msg 3", "msg 2", "msg 1"]
    end
  end

  # ── 2. DM flow ────────────────────────────────────────────────────────

  describe "DM flow" do
    test "ensure_dm creates channel, persists messages, and is idempotent", %{p: p} do
      a = agent_name(p, "alice")
      b = agent_name(p, "bob")

      :ok = Persistence.create_agent(a, "d", "p")
      :ok = Persistence.create_agent(b, "d", "p")

      # Create DM channel
      {:ok, dm_name} = Topic.ensure_dm(a, b)

      # Verify canonical naming (alphabetical)
      [sorted_a, sorted_b] = Enum.sort([a, b])
      assert dm_name == "dm:#{sorted_a}:#{sorted_b}"

      # Post a message from agent_a
      :ok = Topic.post(dm_name, a, "hey bob")

      :sys.get_state(Hive.Persistence)

      # Verify persisted under the DM topic name
      {:ok, msgs} = Persistence.get_messages(dm_name, 50)
      assert length(msgs) >= 1
      assert List.last(msgs).sender == a
      assert List.last(msgs).body == "hey bob"

      # Verify idempotent: calling with reversed order returns same channel
      {:ok, dm_name2} = Topic.ensure_dm(b, a)
      assert dm_name2 == dm_name
    end

    test "both parties are subscribed after ensure_dm", %{p: p} do
      a = agent_name(p, "alice")
      b = agent_name(p, "bob")

      :ok = Persistence.create_agent(a, "d", "p")
      :ok = Persistence.create_agent(b, "d", "p")

      {:ok, dm_name} = Topic.ensure_dm(a, b)

      subs = Topic.subscribers(dm_name)
      assert MapSet.member?(subs, a)
      assert MapSet.member?(subs, b)
    end
  end

  # ── 3. @mention auto-invite ───────────────────────────────────────────

  describe "@mention auto-invite" do
    test "mentioning a non-subscriber adds them and sends context", %{p: p} do
      poster = agent_name(p, "alice")
      mentioned = agent_name(p, "bob")
      topic = topic_name(p, "mentions")

      :ok = Persistence.create_agent(poster, "d", "p")
      :ok = Persistence.create_agent(mentioned, "d", "p")
      :ok = Persistence.create_topic(topic, "d", "topic", nil)

      start_topic(topic)
      {:ok, _} = Topic.join(topic, poster)

      # Register a fake agent process for bob so we receive messages
      {:ok, _} = Registry.register(Hive.AgentRegistry, mentioned, nil)

      # Verify bob is not subscribed
      refute MapSet.member?(Topic.subscribers(topic), mentioned)

      # Post some context messages first
      :ok = Topic.post(topic, poster, "context message 1")
      :ok = Topic.post(topic, poster, "context message 2")

      # Now mention bob
      :ok = Topic.post(topic, poster, "hey @#{mentioned} check this out")

      # Bob should now be a subscriber
      assert MapSet.member?(Topic.subscribers(topic), mentioned)

      # Bob should receive a mention_invite with context
      assert_receive {:mention_invite, ^topic, context}
      assert is_list(context)
      # Should include the 3 messages posted so far (including the mention)
      assert length(context) >= 3
    end

    test "mentioning an already-subscribed agent does not change subscribers", %{p: p} do
      poster = agent_name(p, "alice")
      existing = agent_name(p, "bob")
      topic = topic_name(p, "mentdup")

      :ok = Persistence.create_agent(poster, "d", "p")
      :ok = Persistence.create_agent(existing, "d", "p")
      :ok = Persistence.create_topic(topic, "d", "topic", nil)

      start_topic(topic)
      {:ok, _} = Topic.join(topic, poster)
      {:ok, _} = Topic.join(topic, existing)

      subs_before = Topic.subscribers(topic)
      :ok = Topic.post(topic, poster, "hey @#{existing} still there?")
      subs_after = Topic.subscribers(topic)

      assert subs_before == subs_after
    end

    test "multiple mentions in one message invite all", %{p: p} do
      poster = agent_name(p, "sender")
      bob = agent_name(p, "bob")
      charlie = agent_name(p, "charlie")
      topic = topic_name(p, "multi")

      :ok = Persistence.create_agent(poster, "d", "p")
      :ok = Persistence.create_agent(bob, "d", "p")
      :ok = Persistence.create_agent(charlie, "d", "p")
      :ok = Persistence.create_topic(topic, "d", "topic", nil)

      start_topic(topic)
      {:ok, _} = Topic.join(topic, poster)

      :ok = Topic.post(topic, poster, "cc @#{bob} @#{charlie}")

      subs = Topic.subscribers(topic)
      assert MapSet.member?(subs, bob)
      assert MapSet.member?(subs, charlie)
    end
  end

  # ── 4. Shared namespace validation ────────────────────────────────────

  describe "shared namespace validation" do
    test "cannot create topic with same name as agent", %{p: p} do
      name = topic_name(p, "shared")
      :ok = Persistence.create_agent(name, "d", "p")
      assert {:error, :name_taken} = Persistence.create_topic(name, "d", "topic", nil)
    end

    test "cannot create agent with same name as topic", %{p: p} do
      name = topic_name(p, "shared2")
      :ok = Persistence.create_topic(name, "d", "topic", nil)
      assert {:error, :name_taken} = Persistence.create_agent(name, "d", "p")
    end

    test "name_exists? is true for both agents and topics", %{p: p} do
      agent = agent_name(p, "agentx")
      topic = topic_name(p, "topicy")

      :ok = Persistence.create_agent(agent, "d", "p")
      :ok = Persistence.create_topic(topic, "d", "topic", nil)

      assert Persistence.name_exists?(agent) == true
      assert Persistence.name_exists?(topic) == true
      assert Persistence.name_exists?("#{p}-nonexistent") == false
    end

    test "DM topic names do not collide with the shared namespace", %{p: p} do
      # DM names start with "dm:" and bypass normal name validation
      agent = agent_name(p, "alice")
      :ok = Persistence.create_agent(agent, "d", "p")

      dm_name = "dm:#{agent}:other"
      assert :ok = Persistence.create_topic(dm_name, "DM", "dm", nil)
    end
  end

  # ── 5. MCP server management flow ────────────────────────────────────

  describe "MCP server management flow" do
    test "full lifecycle: create, assign, update, unassign", %{p: p} do
      agent = agent_name(p, "alice")
      srv = topic_name(p, "obsidian")

      :ok = Persistence.create_agent(agent, "d", "p")

      :ok =
        Persistence.create_mcp_server(srv, "Obsidian MCP", "npx", ["obsidian-mcp"], %{
          "KEY" => "val"
        })

      # Assign with allowed_tools
      :ok = Persistence.assign_mcp_server(agent, srv, ["read", "write"])

      {:ok, assigned} = Persistence.get_agent_mcp_servers(agent)
      assert length(assigned) == 1
      assert hd(assigned).name == srv
      assert hd(assigned).allowed_tools == Jason.encode!(["read", "write"])

      # Update allowed_tools by re-assigning
      :ok = Persistence.assign_mcp_server(agent, srv, ["read", "write", "delete"])

      {:ok, assigned} = Persistence.get_agent_mcp_servers(agent)
      assert length(assigned) == 1
      assert hd(assigned).allowed_tools == Jason.encode!(["read", "write", "delete"])

      # Unassign
      :ok = Persistence.unassign_mcp_server(agent, srv)

      {:ok, assigned} = Persistence.get_agent_mcp_servers(agent)
      assert assigned == []

      # Cleanup
      Persistence.delete_mcp_server(srv)
    end

    test "multiple MCP servers assigned to one agent", %{p: p} do
      agent = agent_name(p, "bob")
      srv1 = topic_name(p, "srv1")
      srv2 = topic_name(p, "srv2")

      :ok = Persistence.create_agent(agent, "d", "p")
      :ok = Persistence.create_mcp_server(srv1, "d", "cmd1", [], %{})
      :ok = Persistence.create_mcp_server(srv2, "d", "cmd2", [], %{})

      :ok = Persistence.assign_mcp_server(agent, srv1, ["t1"])
      :ok = Persistence.assign_mcp_server(agent, srv2, ["t2"])

      {:ok, assigned} = Persistence.get_agent_mcp_servers(agent)
      names = Enum.map(assigned, & &1.name) |> Enum.sort()
      assert names == Enum.sort([srv1, srv2])

      # Cleanup
      Persistence.delete_mcp_server(srv1)
      Persistence.delete_mcp_server(srv2)
    end
  end

  # ── 6. Topic subscriber management ───────────────────────────────────

  describe "topic subscriber management" do
    test "subscribe, list, unsubscribe, re-subscribe flow", %{p: p} do
      topic = topic_name(p, "subflow")
      a1 = agent_name(p, "alice")
      a2 = agent_name(p, "bob")
      a3 = agent_name(p, "charlie")

      :ok = Persistence.create_agent(a1, "d", "p")
      :ok = Persistence.create_agent(a2, "d", "p")
      :ok = Persistence.create_agent(a3, "d", "p")
      :ok = Persistence.create_topic(topic, "d", "topic", nil)

      start_topic(topic)

      # Subscribe multiple agents
      {:ok, _} = Topic.join(topic, a1)
      {:ok, _} = Topic.join(topic, a2)
      {:ok, _} = Topic.join(topic, a3)

      subs = Topic.subscribers(topic)
      assert MapSet.size(subs) == 3
      assert MapSet.member?(subs, a1)
      assert MapSet.member?(subs, a2)
      assert MapSet.member?(subs, a3)

      # Unsubscribe one
      Topic.leave(topic, a2)
      subs = Topic.subscribers(topic)
      assert MapSet.size(subs) == 2
      refute MapSet.member?(subs, a2)

      # Re-subscribe is idempotent
      {:ok, _} = Topic.join(topic, a1)
      subs = Topic.subscribers(topic)
      assert MapSet.size(subs) == 2
      assert MapSet.member?(subs, a1)
    end

    test "persistence tracks subscriptions across Topic restarts", %{p: p} do
      topic = topic_name(p, "persist")
      agent = agent_name(p, "alice")

      :ok = Persistence.create_agent(agent, "d", "p")
      :ok = Persistence.create_topic(topic, "d", "topic", nil)

      start_topic(topic)
      {:ok, _} = Topic.join(topic, agent)

      # Verify subscription is in persistence
      {:ok, subs} = Persistence.get_topic_subscribers(topic)
      assert agent in subs

      # Stop the Topic GenServer via the ExUnit supervisor
      stop_supervised!(Topic)

      # Restart with the same name — it should reload subscribers from persistence
      start_topic(topic)

      # The reloaded Topic should have the subscriber
      subs = Topic.subscribers(topic)
      assert MapSet.member?(subs, agent)
    end

    test "message order remains chronological in ChatLive after Topic restart", %{p: p} do
      topic = topic_name(p, "restart-order")
      human = "human"
      agent = agent_name(p, "alice")

      :ok = Persistence.create_agent(agent, "d", "p")
      :ok = Persistence.create_topic(topic, "d", "topic", nil)

      start_topic(topic)
      {:ok, _} = Topic.join(topic, human)
      {:ok, _} = Topic.join(topic, agent)

      :ok = Topic.post(topic, human, "human first")
      :ok = Topic.post(topic, agent, "agent second")
      :sys.get_state(Hive.Persistence)

      stop_supervised!(Topic)
      start_topic(topic)

      reloaded = Topic.recent(topic, 50) |> Enum.reverse()
      assert Enum.map(reloaded, & &1.body) == ["human first", "agent second"]
    end
  end

  # ── 7. Message ring buffer overflow ───────────────────────────────────

  describe "message ring buffer overflow" do
    test "ring buffer holds 50, persistence holds all", %{p: p} do
      agent = agent_name(p, "alice")
      topic = topic_name(p, "overflow")

      :ok = Persistence.create_agent(agent, "d", "p")
      :ok = Persistence.create_topic(topic, "d", "topic", nil)

      start_topic(topic)
      {:ok, _} = Topic.join(topic, agent)

      # Post 60 messages
      for i <- 1..60 do
        :ok = Topic.post(topic, agent, "msg #{i}")
      end

      # Ring buffer should only have 50
      all_buffered = Topic.recent(topic, 100)
      assert length(all_buffered) == 50

      # Most recent should be msg 60
      assert hd(all_buffered).body == "msg 60"

      # Oldest in buffer should be msg 11
      assert List.last(all_buffered).body == "msg 11"

      # Persistence should have all 60
      :sys.get_state(Hive.Persistence)
      {:ok, persisted} = Persistence.get_messages(topic, 100)
      assert length(persisted) == 60
    end
  end

  # ── 8. Persistence edge cases ─────────────────────────────────────────

  describe "persistence edge cases" do
    test "invalid name formats are rejected", %{p: _p} do
      # Empty
      assert {:error, :invalid_name} = Persistence.create_agent("", "d", "p")
      # Too long (32 chars)
      assert {:error, :invalid_name} =
               Persistence.create_agent(String.duplicate("a", 32), "d", "p")

      # Starts with underscore
      assert {:error, :invalid_name} = Persistence.create_agent("_bad", "d", "p")
      # Starts with hyphen
      assert {:error, :invalid_name} = Persistence.create_agent("-bad", "d", "p")
      # Contains spaces
      assert {:error, :invalid_name} = Persistence.create_agent("has space", "d", "p")
      # Special characters
      assert {:error, :invalid_name} = Persistence.create_agent("a!b", "d", "p")
      assert {:error, :invalid_name} = Persistence.create_agent("a@b", "d", "p")

      # Same rules apply to topics
      assert {:error, :invalid_name} = Persistence.create_topic("", "d", "topic", nil)
      assert {:error, :invalid_name} = Persistence.create_topic("has space", "d", "topic", nil)
    end

    test "DM topic names bypass regular name validation", %{p: p} do
      dm_name = "dm:#{p}-x:#{p}-y"
      assert :ok = Persistence.create_topic(dm_name, nil, "dm", nil)
      {:ok, topic} = Persistence.get_topic(dm_name)
      assert topic.type == "dm"

      # Cleanup
      Persistence.delete_topic(dm_name)
    end

    test "update non-existent agent succeeds silently (SQL UPDATE no match)", %{p: _p} do
      # The current implementation runs an UPDATE that matches zero rows,
      # which returns :ok (not an error). This is the expected behavior.
      result = Persistence.update_agent("nonexistent-agent-xyz", %{description: "x"})
      assert result == :ok
    end

    test "deleting agent cascades to subscriptions", %{p: p} do
      agent = agent_name(p, "doomed")
      topic = topic_name(p, "surv")

      :ok = Persistence.create_agent(agent, "d", "p")
      :ok = Persistence.create_topic(topic, "d", "topic", nil)
      :ok = Persistence.subscribe(topic, agent)

      # Verify subscription exists
      {:ok, subs} = Persistence.get_topic_subscribers(topic)
      assert agent in subs

      # Delete agent
      :ok = Persistence.delete_agent(agent)

      # Subscription should be gone (CASCADE)
      {:ok, subs} = Persistence.get_topic_subscribers(topic)
      refute agent in subs
    end

    test "deleting topic cascades to subscriptions", %{p: p} do
      agent = agent_name(p, "alive")
      topic = topic_name(p, "doomed")

      :ok = Persistence.create_agent(agent, "d", "p")
      :ok = Persistence.create_topic(topic, "d", "topic", nil)
      :ok = Persistence.subscribe(topic, agent)

      {:ok, agent_subs} = Persistence.get_subscriptions(agent)
      assert topic in agent_subs

      # Delete topic
      :ok = Persistence.delete_topic(topic)

      # Agent's subscription to that topic should be gone
      {:ok, agent_subs} = Persistence.get_subscriptions(agent)
      refute topic in agent_subs
    end
  end

  # ── 9. Validation module integration ──────────────────────────────────

  describe "validation module integration" do
    test "validate_name accepts boundary cases" do
      assert :ok = Validation.validate_name("a")
      assert :ok = Validation.validate_name(String.duplicate("a", 31))
      assert :ok = Validation.validate_name("agent-1_2")
      assert :ok = Validation.validate_name("A1")
      assert :ok = Validation.validate_name("z")
    end

    test "validate_name rejects invalid inputs" do
      assert {:error, :invalid_name} = Validation.validate_name("")
      assert {:error, :invalid_name} = Validation.validate_name(String.duplicate("a", 32))
      assert {:error, :invalid_name} = Validation.validate_name("_leading")
      assert {:error, :invalid_name} = Validation.validate_name("-leading")
      assert {:error, :invalid_name} = Validation.validate_name("has space")
      assert {:error, :invalid_name} = Validation.validate_name("dot.name")
    end
  end

  # ── 10. PubSub + Topic cross-module ───────────────────────────────────

  describe "PubSub and Topic cross-module interaction" do
    test "PubSub receives messages from different senders", %{p: p} do
      topic = topic_name(p, "pubsub")
      a = agent_name(p, "alice")
      b = agent_name(p, "bob")

      :ok = Persistence.create_agent(a, "d", "p")
      :ok = Persistence.create_agent(b, "d", "p")
      :ok = Persistence.create_topic(topic, "d", "topic", nil)

      start_topic(topic)
      {:ok, _} = Topic.join(topic, a)
      {:ok, _} = Topic.join(topic, b)

      Phoenix.PubSub.subscribe(Hive.PubSub, "topic:#{topic}")

      :ok = Topic.post(topic, a, "from alice")
      :ok = Topic.post(topic, b, "from bob")

      assert_receive {:message, %{topic: ^topic, sender: ^a, body: "from alice"}}
      assert_receive {:message, %{topic: ^topic, sender: ^b, body: "from bob"}}
    end

    test "self-message filtering: sender does not get their own topic_message", %{p: p} do
      topic = topic_name(p, "selfmsg")
      a = agent_name(p, "alice")
      b = agent_name(p, "bob")

      :ok = Persistence.create_agent(a, "d", "p")
      :ok = Persistence.create_agent(b, "d", "p")
      :ok = Persistence.create_topic(topic, "d", "topic", nil)

      start_topic(topic)

      # Register fake agent processes
      {:ok, _} = Registry.register(Hive.AgentRegistry, a, nil)
      {:ok, _} = Registry.register(Hive.AgentRegistry, b, nil)

      {:ok, _} = Topic.join(topic, a)
      {:ok, _} = Topic.join(topic, b)

      :ok = Topic.post(topic, a, "hello")

      # Bob should receive the message (this test process is registered as both,
      # but the Topic only delivers to non-sender subscribers)
      assert_receive {:topic_message, ^topic, message}
      assert message.sender == a
      assert message.sender_kind == "agent"
      assert message.body == "hello"
      assert %DateTime{} = message.ts

      # We should NOT receive a second :topic_message for the same post
      # because alice is the sender
      refute_receive {:topic_message, ^topic, _}, 100
    end
  end

  # ── 11. Topic info reflects state ─────────────────────────────────────

  describe "topic info reflects state changes" do
    test "info tracks subscriber count and message count", %{p: p} do
      topic = topic_name(p, "info")
      a = agent_name(p, "alice")
      b = agent_name(p, "bob")

      :ok = Persistence.create_agent(a, "d", "p")
      :ok = Persistence.create_agent(b, "d", "p")
      :ok = Persistence.create_topic(topic, "d", "topic", nil)

      start_topic(topic)

      info = Topic.info(topic)
      assert info.subscriber_count == 0
      assert info.message_count == 0

      {:ok, _} = Topic.join(topic, a)
      {:ok, _} = Topic.join(topic, b)

      info = Topic.info(topic)
      assert info.subscriber_count == 2

      :ok = Topic.post(topic, a, "msg 1")
      :ok = Topic.post(topic, b, "msg 2")
      :ok = Topic.post(topic, a, "msg 3")

      info = Topic.info(topic)
      assert info.message_count == 3
      assert info.name == topic
      assert info.type == :topic
    end
  end

  # ── 12. Join returns recent context ───────────────────────────────────

  describe "join returns recent context" do
    test "new joiner receives last 5 messages", %{p: p} do
      topic = topic_name(p, "joinctx")
      poster = agent_name(p, "alice")
      joiner = agent_name(p, "bob")

      :ok = Persistence.create_agent(poster, "d", "p")
      :ok = Persistence.create_agent(joiner, "d", "p")
      :ok = Persistence.create_topic(topic, "d", "topic", nil)

      start_topic(topic)
      {:ok, _} = Topic.join(topic, poster)

      # Post 7 messages
      for i <- 1..7 do
        :ok = Topic.post(topic, poster, "msg #{i}")
      end

      # New joiner gets last 5
      {:ok, recent} = Topic.join(topic, joiner)
      assert length(recent) == 5
      assert hd(recent).body == "msg 7"
      assert List.last(recent).body == "msg 3"
    end
  end

  # ── 13. DM canonical naming ──────────────────────────────────────────

  describe "DM canonical naming" do
    test "dm_channel_name is always alphabetically sorted" do
      assert Topic.dm_channel_name("zebra", "alpha") == "dm:alpha:zebra"
      assert Topic.dm_channel_name("alpha", "zebra") == "dm:alpha:zebra"
      assert Topic.dm_channel_name("a", "a") == "dm:a:a"
    end
  end

  # ── 14. Persistence and Topic state sync ──────────────────────────────

  describe "persistence and topic state sync" do
    test "messages persisted via Topic.post match Persistence.get_messages", %{p: p} do
      agent = agent_name(p, "alice")
      topic = topic_name(p, "sync")

      :ok = Persistence.create_agent(agent, "d", "p")
      :ok = Persistence.create_topic(topic, "d", "topic", nil)
      start_topic(topic)
      {:ok, _} = Topic.join(topic, agent)

      messages = ["first", "second", "third"]

      for msg <- messages do
        :ok = Topic.post(topic, agent, msg)
      end

      :sys.get_state(Hive.Persistence)

      # Persistence has them in ASC order
      {:ok, persisted} = Persistence.get_messages(topic, 50)
      persisted_bodies = Enum.map(persisted, & &1.body)
      assert persisted_bodies == messages

      # Ring buffer has them most-recent-first
      buffered = Topic.recent(topic, 3)
      buffered_bodies = Enum.map(buffered, & &1.body)
      assert buffered_bodies == Enum.reverse(messages)
    end

    test "subscription state is consistent between Topic and Persistence", %{p: p} do
      agent = agent_name(p, "alice")
      topic = topic_name(p, "subsync")

      :ok = Persistence.create_agent(agent, "d", "p")
      :ok = Persistence.create_topic(topic, "d", "topic", nil)
      start_topic(topic)

      # Before join
      refute MapSet.member?(Topic.subscribers(topic), agent)
      {:ok, db_subs} = Persistence.get_topic_subscribers(topic)
      refute agent in db_subs

      # After join
      {:ok, _} = Topic.join(topic, agent)
      assert MapSet.member?(Topic.subscribers(topic), agent)
      {:ok, db_subs} = Persistence.get_topic_subscribers(topic)
      assert agent in db_subs

      # After leave
      Topic.leave(topic, agent)
      refute MapSet.member?(Topic.subscribers(topic), agent)
      {:ok, db_subs} = Persistence.get_topic_subscribers(topic)
      refute agent in db_subs
    end
  end

  # ── 15. MCP server cascade on agent delete ────────────────────────────

  describe "MCP server cascade on agent delete" do
    test "deleting agent removes MCP server assignments", %{p: p} do
      agent = agent_name(p, "doomed")
      srv = topic_name(p, "mcsrv")

      :ok = Persistence.create_agent(agent, "d", "p")
      :ok = Persistence.create_mcp_server(srv, "d", "cmd", [], %{})
      :ok = Persistence.assign_mcp_server(agent, srv, ["tool1"])

      {:ok, assigned} = Persistence.get_agent_mcp_servers(agent)
      assert length(assigned) == 1

      # Delete the agent
      :ok = Persistence.delete_agent(agent)

      # Assignment should be gone due to CASCADE
      {:ok, assigned} = Persistence.get_agent_mcp_servers(agent)
      assert assigned == []

      # MCP server itself should still exist
      {:ok, servers} = Persistence.get_mcp_servers()
      assert Enum.any?(servers, &(&1.name == srv))

      # Cleanup
      Persistence.delete_mcp_server(srv)
    end

    test "deleting MCP server removes its assignments", %{p: p} do
      agent = agent_name(p, "alive")
      srv = topic_name(p, "doomedsrv")

      :ok = Persistence.create_agent(agent, "d", "p")
      :ok = Persistence.create_mcp_server(srv, "d", "cmd", [], %{})
      :ok = Persistence.assign_mcp_server(agent, srv, ["tool1"])

      {:ok, assigned} = Persistence.get_agent_mcp_servers(agent)
      assert length(assigned) == 1

      # Delete the MCP server
      :ok = Persistence.delete_mcp_server(srv)

      # Assignment should be gone due to CASCADE
      {:ok, assigned} = Persistence.get_agent_mcp_servers(agent)
      assert assigned == []

      # Agent should still exist
      {:ok, agent_data} = Persistence.get_agent(agent)
      assert agent_data != nil
    end
  end
end
