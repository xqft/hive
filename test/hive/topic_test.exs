defmodule Hive.TopicTest do
  use ExUnit.Case, async: false

  alias Hive.Topic

  # The registries (Hive.TopicRegistry, Hive.AgentRegistry) and
  # Hive.TopicSup are started by the application supervisor, so we
  # rely on the running app and just clean up agent registry entries
  # after each test.
  setup do
    on_exit(fn ->
      # Unregister any agent entries this test process registered
      Registry.unregister(Hive.AgentRegistry, "alice")
      Registry.unregister(Hive.AgentRegistry, "bob")
    end)

    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp start_topic(name, opts \\ []) do
    defaults = [name: name, description: "test topic", type: :topic, created_by: "human"]
    start_supervised!({Topic, Keyword.merge(defaults, opts)})
  end

  # ── Creating & joining topics ────────────────────────────────────────

  describe "creating and joining topics" do
    test "start_link registers the topic and info returns metadata" do
      start_topic("general")

      info = Topic.info("general")
      assert info.name == "general"
      assert info.description == "test topic"
      assert info.type == :topic
      assert info.created_by == "human"
      assert info.subscriber_count == 0
      assert info.message_count == 0
    end

    test "join adds subscriber and returns recent messages" do
      start_topic("dev")

      assert {:ok, []} = Topic.join("dev", "alice")
      assert MapSet.member?(Topic.subscribers("dev"), "alice")
    end

    test "join returns last 5 messages as context" do
      start_topic("ctx")

      # Post 7 messages
      for i <- 1..7 do
        Topic.join("ctx", "poster#{i}")
        Topic.post("ctx", "poster#{i}", "msg #{i}")
      end

      # New joiner should get last 5
      {:ok, recent} = Topic.join("ctx", "latecomer")
      assert length(recent) == 5
      # Most recent first (ring buffer head)
      assert hd(recent).body == "msg 7"
    end

    test "leave removes subscriber" do
      start_topic("leave-test")
      Topic.join("leave-test", "bob")
      assert MapSet.member?(Topic.subscribers("leave-test"), "bob")

      Topic.leave("leave-test", "bob")
      refute MapSet.member?(Topic.subscribers("leave-test"), "bob")
    end
  end

  # ── Posting messages & ring buffer ───────────────────────────────────

  describe "posting messages and ring buffer" do
    test "post adds message to ring buffer" do
      start_topic("msgs")
      Topic.join("msgs", "alice")

      :ok = Topic.post("msgs", "alice", "hello world")

      [msg] = Topic.recent("msgs", 1)
      assert msg.sender == "alice"
      assert msg.body == "hello world"
      assert %DateTime{} = msg.ts
    end

    test "ring buffer keeps only last 50 messages" do
      start_topic("overflow")
      Topic.join("overflow", "bot")

      for i <- 1..60 do
        Topic.post("overflow", "bot", "msg #{i}")
      end

      all = Topic.recent("overflow", 100)
      assert length(all) == 50
      # Most recent should be msg 60
      assert hd(all).body == "msg 60"
      # Oldest kept should be msg 11
      assert List.last(all).body == "msg 11"
    end

    test "recent returns requested number of messages" do
      start_topic("recent-n")
      Topic.join("recent-n", "alice")

      for i <- 1..10 do
        Topic.post("recent-n", "alice", "msg #{i}")
      end

      assert length(Topic.recent("recent-n", 3)) == 3
      assert length(Topic.recent("recent-n", 10)) == 10
    end
  end

  # ── DM channel naming ───────────────────────────────────────────────

  describe "DM channel naming" do
    test "dm_channel_name produces canonical sorted name" do
      assert Topic.dm_channel_name("bob", "alice") == "dm:alice:bob"
      assert Topic.dm_channel_name("alice", "bob") == "dm:alice:bob"
    end

    test "dm_channel_name is idempotent" do
      name1 = Topic.dm_channel_name("x", "y")
      name2 = Topic.dm_channel_name("y", "x")
      assert name1 == name2
    end
  end

  # ── Self-message filtering ──────────────────────────────────────────

  describe "self-message filtering" do
    test "sender does not receive their own message via Agent delivery" do
      start_topic("self-filter")

      # Register a fake agent process in AgentRegistry
      {:ok, _} = Registry.register(Hive.AgentRegistry, "alice", nil)
      {:ok, _} = Registry.register(Hive.AgentRegistry, "bob", nil)

      Topic.join("self-filter", "alice")
      Topic.join("self-filter", "bob")

      Topic.post("self-filter", "alice", "hello from alice")

      # bob should receive the message
      assert_receive {:topic_message, "self-filter", message}
      assert message.sender == "alice"
      assert message.sender_kind == "agent"
      assert message.body == "hello from alice"
      assert %DateTime{} = message.ts

      # alice (the sender) should NOT receive her own message
      refute_receive {:topic_message, "self-filter", _}
    end

    test "dm topics deliver dm_message envelopes with metadata" do
      start_topic("dm:alice:bob", type: :dm)

      {:ok, _} = Registry.register(Hive.AgentRegistry, "alice", nil)
      {:ok, _} = Registry.register(Hive.AgentRegistry, "bob", nil)

      Topic.join("dm:alice:bob", "alice")
      Topic.join("dm:alice:bob", "bob")

      Topic.post("dm:alice:bob", "alice", "private hello")

      assert_receive {:dm_message, "dm:alice:bob", message}
      assert message.sender == "alice"
      assert message.sender_kind == "agent"
      assert message.body == "private hello"
      assert %DateTime{} = message.ts
    end
  end

  # ── @mention detection ──────────────────────────────────────────────

  describe "@mention detection" do
    test "mentioning a non-subscriber auto-invites them" do
      start_topic("mentions")
      Topic.join("mentions", "alice")

      # bob is not subscribed
      refute MapSet.member?(Topic.subscribers("mentions"), "bob")

      # alice mentions bob
      Topic.post("mentions", "alice", "hey @bob check this out")

      # bob should now be a subscriber
      assert MapSet.member?(Topic.subscribers("mentions"), "bob")
    end

    test "mentioning an existing subscriber does not duplicate" do
      start_topic("mention-dup")
      Topic.join("mention-dup", "alice")
      Topic.join("mention-dup", "bob")

      subs_before = Topic.subscribers("mention-dup")
      Topic.post("mention-dup", "alice", "hey @bob you there?")
      subs_after = Topic.subscribers("mention-dup")

      assert subs_before == subs_after
    end

    test "multiple mentions in one message" do
      start_topic("multi-mention")
      Topic.join("multi-mention", "alice")

      Topic.post("multi-mention", "alice", "cc @bob @charlie @dave")

      subs = Topic.subscribers("multi-mention")
      assert MapSet.member?(subs, "bob")
      assert MapSet.member?(subs, "charlie")
      assert MapSet.member?(subs, "dave")
    end

    test "mentioned agent receives context via mention_invite" do
      start_topic("mention-ctx")

      # Register fake agent for bob
      {:ok, _} = Registry.register(Hive.AgentRegistry, "bob", nil)

      Topic.join("mention-ctx", "alice")

      # Post some context messages
      Topic.post("mention-ctx", "alice", "first message")
      Topic.post("mention-ctx", "alice", "second message")

      # Now mention bob
      Topic.post("mention-ctx", "alice", "hey @bob look at this")

      # bob should get context (mention_invite with last 5 messages)
      assert_receive {:mention_invite, "mention-ctx", context}
      assert is_list(context)
      assert length(context) == 3
      assert Enum.all?(context, &Map.has_key?(&1, :ts))
      assert Enum.all?(context, &Map.has_key?(&1, :sender_kind))
    end
  end

  # ── PubSub broadcasting ─────────────────────────────────────────────

  describe "PubSub broadcasting" do
    test "posting broadcasts to PubSub topic channel" do
      start_topic("pubsub-test")
      Topic.join("pubsub-test", "alice")

      Phoenix.PubSub.subscribe(Hive.PubSub, "topic:pubsub-test")

      Topic.post("pubsub-test", "alice", "broadcast me")

      assert_receive {:message,
                      %{
                        topic: "pubsub-test",
                        sender: "alice",
                        body: "broadcast me",
                        ts: %DateTime{}
                      }}
    end
  end
end
