defmodule Hive.PersistenceTest do
  use ExUnit.Case, async: true

  alias Hive.Persistence

  setup do
    # Use a unique temp database for each test
    db_path = Path.join(System.tmp_dir!(), "hive_test_#{:erlang.unique_integer([:positive])}.db")
    server_name = :"persistence_#{:erlang.unique_integer([:positive])}"

    {:ok, pid} = Persistence.start_link(db_path: db_path, name: server_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm(db_path)
      File.rm(db_path <> "-wal")
      File.rm(db_path <> "-shm")
    end)

    %{server: server_name, db_path: db_path}
  end

  # -------------------------------------------------------------------
  # Agent CRUD
  # -------------------------------------------------------------------

  describe "create_agent/4" do
    test "creates an agent with a valid name", %{server: s} do
      assert :ok = Persistence.create_agent("alice", "An agent", "Helpful", s)
      assert {:ok, agent} = Persistence.get_agent("alice", s)
      assert agent.name == "alice"
      assert agent.description == "An agent"
      assert agent.personality == "Helpful"
    end

    test "rejects invalid names", %{server: s} do
      assert {:error, :invalid_name} = Persistence.create_agent("", "d", "p", s)
      assert {:error, :invalid_name} = Persistence.create_agent("_bad", "d", "p", s)
      assert {:error, :invalid_name} = Persistence.create_agent("-bad", "d", "p", s)
      assert {:error, :invalid_name} = Persistence.create_agent("has space", "d", "p", s)
      assert {:error, :invalid_name} = Persistence.create_agent("a!", "d", "p", s)

      long_name = String.duplicate("a", 32)
      assert {:error, :invalid_name} = Persistence.create_agent(long_name, "d", "p", s)
    end

    test "accepts names at the boundary", %{server: s} do
      assert :ok = Persistence.create_agent("a", "d", "p", s)

      max_name = String.duplicate("a", 31)
      assert :ok = Persistence.create_agent(max_name, "d", "p", s)

      assert :ok = Persistence.create_agent("agent-1_2", "d", "p", s)
    end

    test "rejects duplicate agent name", %{server: s} do
      assert :ok = Persistence.create_agent("bob", "d", "p", s)
      assert {:error, :name_taken} = Persistence.create_agent("bob", "d2", "p2", s)
    end
  end

  describe "update_agent/3" do
    test "updates description and personality", %{server: s} do
      :ok = Persistence.create_agent("carol", "old desc", "old pers", s)

      assert :ok =
               Persistence.update_agent(
                 "carol",
                 %{description: "new desc", personality: "new pers"},
                 s
               )

      {:ok, agent} = Persistence.get_agent("carol", s)
      assert agent.description == "new desc"
      assert agent.personality == "new pers"
    end

    test "returns error with empty attrs", %{server: s} do
      :ok = Persistence.create_agent("dave", "d", "p", s)
      assert {:error, :no_changes} = Persistence.update_agent("dave", %{}, s)
    end
  end

  describe "delete_agent/2" do
    test "deletes an existing agent", %{server: s} do
      :ok = Persistence.create_agent("eve", "d", "p", s)
      assert :ok = Persistence.delete_agent("eve", s)
      assert {:ok, nil} = Persistence.get_agent("eve", s)
    end
  end

  describe "get_agents/1" do
    test "lists all agents", %{server: s} do
      :ok = Persistence.create_agent("a1", "d1", "p1", s)
      :ok = Persistence.create_agent("a2", "d2", "p2", s)

      {:ok, agents} = Persistence.get_agents(s)
      names = Enum.map(agents, & &1.name) |> Enum.sort()
      assert names == ["a1", "a2"]
    end
  end

  describe "update_agent_personality/3" do
    test "updates only the personality field", %{server: s} do
      :ok = Persistence.create_agent("frank", "desc", "old", s)
      :ok = Persistence.update_agent_personality("frank", "new personality", s)

      {:ok, agent} = Persistence.get_agent("frank", s)
      assert agent.personality == "new personality"
      assert agent.description == "desc"
    end
  end

  # -------------------------------------------------------------------
  # Topic CRUD
  # -------------------------------------------------------------------

  describe "create_topic/5" do
    test "creates a topic with a valid name", %{server: s} do
      assert :ok = Persistence.create_topic("general", "General chat", "topic", nil, s)
      assert {:ok, topic} = Persistence.get_topic("general", s)
      assert topic.name == "general"
      assert topic.type == "topic"
    end

    test "rejects invalid topic names", %{server: s} do
      assert {:error, :invalid_name} = Persistence.create_topic("", "d", "topic", nil, s)
      assert {:error, :invalid_name} = Persistence.create_topic("bad name", "d", "topic", nil, s)
    end

    test "allows DM names starting with dm: without validation", %{server: s} do
      assert :ok = Persistence.create_topic("dm:alice:bob", "DM", "dm", nil, s)
      {:ok, topic} = Persistence.get_topic("dm:alice:bob", s)
      assert topic.type == "dm"
    end
  end

  # -------------------------------------------------------------------
  # Shared namespace collision
  # -------------------------------------------------------------------

  describe "shared namespace" do
    test "cannot create topic with same name as agent", %{server: s} do
      :ok = Persistence.create_agent("shared", "d", "p", s)
      assert {:error, :name_taken} = Persistence.create_topic("shared", "d", "topic", nil, s)
    end

    test "cannot create agent with same name as topic", %{server: s} do
      :ok = Persistence.create_topic("shared", "d", "topic", nil, s)
      assert {:error, :name_taken} = Persistence.create_agent("shared", "d", "p", s)
    end

    test "name_exists? returns true for agents and topics", %{server: s} do
      :ok = Persistence.create_agent("agentx", "d", "p", s)
      :ok = Persistence.create_topic("topicy", "d", "topic", nil, s)

      assert Persistence.name_exists?("agentx", s) == true
      assert Persistence.name_exists?("topicy", s) == true
      assert Persistence.name_exists?("nonexistent", s) == false
    end
  end

  # -------------------------------------------------------------------
  # Messages
  # -------------------------------------------------------------------

  describe "messages" do
    test "write and retrieve messages", %{server: s} do
      :ok = Persistence.create_topic("chat", "Chat", "topic", nil, s)

      Persistence.write_message("chat", "alice", "hello", s)
      Persistence.write_message("chat", "bob", "world", s)

      # Give the casts a moment to process
      :sys.get_state(s)

      {:ok, msgs} = Persistence.get_messages("chat", 50, s)
      assert length(msgs) == 2
      assert Enum.at(msgs, 0).sender == "alice"
      assert Enum.at(msgs, 0).body == "hello"
      assert Enum.at(msgs, 1).sender == "bob"
    end

    test "respects limit", %{server: s} do
      :ok = Persistence.create_topic("limited", "Limited", "topic", nil, s)

      for i <- 1..5 do
        Persistence.write_message("limited", "sender", "msg #{i}", s)
      end

      :sys.get_state(s)

      {:ok, msgs} = Persistence.get_messages("limited", 3, s)
      assert length(msgs) == 3
    end
  end

  # -------------------------------------------------------------------
  # Subscriptions
  # -------------------------------------------------------------------

  describe "subscriptions" do
    test "subscribe and unsubscribe", %{server: s} do
      :ok = Persistence.create_agent("sub-agent", "d", "p", s)
      :ok = Persistence.create_topic("sub-topic", "d", "topic", nil, s)

      :ok = Persistence.subscribe("sub-topic", "sub-agent", s)

      {:ok, subs} = Persistence.get_subscriptions("sub-agent", s)
      assert subs == ["sub-topic"]

      {:ok, subscribers} = Persistence.get_topic_subscribers("sub-topic", s)
      assert subscribers == ["sub-agent"]

      :ok = Persistence.unsubscribe("sub-topic", "sub-agent", s)

      {:ok, subs} = Persistence.get_subscriptions("sub-agent", s)
      assert subs == []
    end

    test "duplicate subscribe is idempotent (INSERT OR IGNORE)", %{server: s} do
      :ok = Persistence.create_agent("dup-agent", "d", "p", s)
      :ok = Persistence.create_topic("dup-topic", "d", "topic", nil, s)

      :ok = Persistence.subscribe("dup-topic", "dup-agent", s)
      :ok = Persistence.subscribe("dup-topic", "dup-agent", s)

      {:ok, subs} = Persistence.get_subscriptions("dup-agent", s)
      assert subs == ["dup-topic"]
    end
  end

  # -------------------------------------------------------------------
  # MCP Servers
  # -------------------------------------------------------------------

  describe "MCP servers" do
    test "create, list, update, and delete", %{server: s} do
      :ok =
        Persistence.create_mcp_server(
          "obsidian",
          "Obsidian MCP",
          "npx",
          ["obsidian-mcp"],
          %{"KEY" => "val"},
          s
        )

      {:ok, servers} = Persistence.get_mcp_servers(s)
      assert length(servers) == 1
      srv = hd(servers)
      assert srv.name == "obsidian"
      assert srv.command == "npx"
      assert srv.args == "[\"obsidian-mcp\"]"
      assert srv.env == "{\"KEY\":\"val\"}"

      :ok = Persistence.update_mcp_server("obsidian", %{description: "Updated desc"}, s)
      {:ok, servers} = Persistence.get_mcp_servers(s)
      assert hd(servers).description == "Updated desc"

      :ok = Persistence.delete_mcp_server("obsidian", s)
      {:ok, servers} = Persistence.get_mcp_servers(s)
      assert servers == []
    end

    test "update with no changes returns error", %{server: s} do
      :ok = Persistence.create_mcp_server("srv", "d", "cmd", [], %{}, s)
      assert {:error, :no_changes} = Persistence.update_mcp_server("srv", %{}, s)
    end
  end

  describe "MCP server assignment" do
    test "assign, list, and unassign", %{server: s} do
      :ok = Persistence.create_agent("mcp-agent", "d", "p", s)
      :ok = Persistence.create_mcp_server("mcp-srv", "d", "cmd", [], %{}, s)

      :ok = Persistence.assign_mcp_server("mcp-agent", "mcp-srv", ["tool1", "tool2"], s)

      {:ok, assigned} = Persistence.get_agent_mcp_servers("mcp-agent", s)
      assert length(assigned) == 1
      assert hd(assigned).name == "mcp-srv"
      assert hd(assigned).allowed_tools == "[\"tool1\",\"tool2\"]"

      :ok = Persistence.unassign_mcp_server("mcp-agent", "mcp-srv", s)

      {:ok, assigned} = Persistence.get_agent_mcp_servers("mcp-agent", s)
      assert assigned == []
    end

    test "assign replaces allowed_tools on reassign", %{server: s} do
      :ok = Persistence.create_agent("re-agent", "d", "p", s)
      :ok = Persistence.create_mcp_server("re-srv", "d", "cmd", [], %{}, s)

      :ok = Persistence.assign_mcp_server("re-agent", "re-srv", ["old"], s)
      :ok = Persistence.assign_mcp_server("re-agent", "re-srv", ["new"], s)

      {:ok, assigned} = Persistence.get_agent_mcp_servers("re-agent", s)
      assert length(assigned) == 1
      assert hd(assigned).allowed_tools == "[\"new\"]"
    end
  end

  # -------------------------------------------------------------------
  # Topic deletion
  # -------------------------------------------------------------------

  describe "delete_topic/2" do
    test "deletes a topic", %{server: s} do
      :ok = Persistence.create_topic("doomed", "d", "topic", nil, s)
      :ok = Persistence.delete_topic("doomed", s)
      assert {:ok, nil} = Persistence.get_topic("doomed", s)
    end
  end
end
