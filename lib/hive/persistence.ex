defmodule Hive.Persistence do
  @moduledoc """
  Single-writer GenServer for SQLite persistence.

  Uses WAL mode for concurrent reads. All writes are serialized through
  GenServer callbacks. Reads use a separate connection and can be called
  directly from any process.
  """

  use GenServer

  alias Exqlite.Sqlite3
  alias Hive.Validation

  require Logger

  # -------------------------------------------------------------------
  # Client API — writes (serialized through GenServer)
  # -------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc "Fire-and-forget message write."
  def write_message(topic, sender, body, server \\ __MODULE__) do
    GenServer.cast(server, {:write_message, topic, sender, body})
  end

  def create_agent(name, description, personality, server \\ __MODULE__) do
    GenServer.call(server, {:create_agent, name, description, personality})
  end

  def create_topic(name, description, type \\ "topic", created_by \\ nil, server \\ __MODULE__) do
    GenServer.call(server, {:create_topic, name, description, type, created_by})
  end

  def update_agent(name, attrs, server \\ __MODULE__) do
    GenServer.call(server, {:update_agent, name, attrs})
  end

  def delete_agent(name, server \\ __MODULE__) do
    GenServer.call(server, {:delete_agent, name})
  end

  def delete_topic(name, server \\ __MODULE__) do
    GenServer.call(server, {:delete_topic, name})
  end

  def subscribe(topic, agent, server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, topic, agent})
  end

  def unsubscribe(topic, agent, server \\ __MODULE__) do
    GenServer.call(server, {:unsubscribe, topic, agent})
  end

  def update_agent_personality(agent, content, server \\ __MODULE__) do
    GenServer.call(server, {:update_agent_personality, agent, content})
  end

  def create_mcp_server(name, description, command, args, env, server \\ __MODULE__) do
    GenServer.call(server, {:create_mcp_server, name, description, command, args, env})
  end

  def update_mcp_server(name, attrs, server \\ __MODULE__) do
    GenServer.call(server, {:update_mcp_server, name, attrs})
  end

  def delete_mcp_server(name, server \\ __MODULE__) do
    GenServer.call(server, {:delete_mcp_server, name})
  end

  def assign_mcp_server(agent, mcp_server, allowed_tools \\ [], server \\ __MODULE__) do
    GenServer.call(server, {:assign_mcp_server, agent, mcp_server, allowed_tools})
  end

  def unassign_mcp_server(agent, mcp_server, server \\ __MODULE__) do
    GenServer.call(server, {:unassign_mcp_server, agent, mcp_server})
  end

  # -------------------------------------------------------------------
  # Client API — reads (direct, using reader connection)
  # -------------------------------------------------------------------

  def get_messages(topic, limit \\ 50, server \\ __MODULE__) do
    reader = get_reader(server)

    case query_all(
           reader,
           "SELECT sender, body, ts FROM (SELECT sender, body, ts, id FROM messages WHERE topic = ?1 ORDER BY id DESC LIMIT ?2) recent ORDER BY id ASC",
           [topic, limit],
           [:sender, :body, :ts]
         ) do
      {:ok, messages} -> {:ok, messages}
      error -> error
    end
  end

  def get_agents(server \\ __MODULE__) do
    reader = get_reader(server)

    query_all(reader, "SELECT name, description, personality, config FROM agents", [], [
      :name,
      :description,
      :personality,
      :config
    ])
  end

  def get_agent(name, server \\ __MODULE__) do
    reader = get_reader(server)

    query_one(
      reader,
      "SELECT name, description, personality, config FROM agents WHERE name = ?1",
      [name],
      [:name, :description, :personality, :config]
    )
  end

  def get_topics(server \\ __MODULE__) do
    reader = get_reader(server)

    query_all(reader, "SELECT name, description, type, created_by FROM topics", [], [
      :name,
      :description,
      :type,
      :created_by
    ])
  end

  def get_topic(name, server \\ __MODULE__) do
    reader = get_reader(server)

    query_one(
      reader,
      "SELECT name, description, type, created_by FROM topics WHERE name = ?1",
      [name],
      [:name, :description, :type, :created_by]
    )
  end

  def get_subscriptions(agent, server \\ __MODULE__) do
    reader = get_reader(server)

    case query_all(reader, "SELECT topic FROM subscriptions WHERE agent = ?1", [agent], [:topic]) do
      {:ok, rows} -> {:ok, Enum.map(rows, & &1.topic)}
      error -> error
    end
  end

  def get_topic_subscribers(topic, server \\ __MODULE__) do
    reader = get_reader(server)

    case query_all(reader, "SELECT agent FROM subscriptions WHERE topic = ?1", [topic], [:agent]) do
      {:ok, rows} -> {:ok, Enum.map(rows, & &1.agent)}
      error -> error
    end
  end

  def get_mcp_servers(server \\ __MODULE__) do
    reader = get_reader(server)

    query_all(reader, "SELECT name, description, command, args, env FROM mcp_servers", [], [
      :name,
      :description,
      :command,
      :args,
      :env
    ])
  end

  def get_agent_mcp_servers(agent, server \\ __MODULE__) do
    reader = get_reader(server)

    query_all(
      reader,
      """
      SELECT ms.name, ms.description, ms.command, ms.args, ms.env, ams.allowed_tools
      FROM agent_mcp_servers ams
      JOIN mcp_servers ms ON ms.name = ams.mcp_server
      WHERE ams.agent = ?1
      """,
      [agent],
      [:name, :description, :command, :args, :env, :allowed_tools]
    )
  end

  def name_exists?(name, server \\ __MODULE__) do
    reader = get_reader(server)

    case query_one(
           reader,
           "SELECT 1 FROM agents WHERE name = ?1 UNION SELECT 1 FROM topics WHERE name = ?1 LIMIT 1",
           [name],
           [:exists]
         ) do
      {:ok, nil} -> false
      {:ok, _} -> true
      {:error, _} = err -> err
    end
  end

  # -------------------------------------------------------------------
  # GenServer callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(opts) do
    db_path = opts[:db_path] || Application.get_env(:hive, :db_path, "priv/sqlite/hive.db")

    # Ensure parent directory exists
    db_path |> Path.dirname() |> File.mkdir_p!()

    {:ok, writer} = Sqlite3.open(db_path)
    set_pragmas(writer)
    run_migrations(writer)

    {:ok, reader} = Sqlite3.open(db_path, mode: :readonly)
    set_reader_pragmas(reader)

    # Store reader in a persistent term so reads can bypass the GenServer
    reader_key = reader_key(opts[:name] || __MODULE__)
    :persistent_term.put(reader_key, reader)

    {:ok, %{writer: writer, reader: reader, reader_key: reader_key, db_path: db_path}}
  end

  @impl true
  def terminate(_reason, state) do
    Sqlite3.close(state.writer)
    Sqlite3.close(state.reader)
    :persistent_term.erase(state.reader_key)
    :ok
  end

  # -- Write callbacks ------------------------------------------------

  @impl true
  def handle_cast({:write_message, topic, sender, body}, state) do
    exec_write(state.writer, "INSERT INTO messages (topic, sender, body) VALUES (?1, ?2, ?3)", [
      topic,
      sender,
      body
    ])

    {:noreply, state}
  end

  @impl true
  def handle_call({:create_agent, name, description, personality}, _from, state) do
    case Validation.validate_name(name) do
      {:error, _} = err ->
        {:reply, err, state}

      :ok ->
        if namespace_taken?(state.writer, name) do
          {:reply, {:error, :name_taken}, state}
        else
          case exec_write(
                 state.writer,
                 "INSERT INTO agents (name, description, personality) VALUES (?1, ?2, ?3)",
                 [
                   name,
                   description,
                   personality
                 ]
               ) do
            :ok -> {:reply, :ok, state}
            {:error, _} = err -> {:reply, err, state}
          end
        end
    end
  end

  def handle_call({:create_topic, name, description, type, created_by}, _from, state) do
    # DM topics (starting with "dm:") skip name validation
    valid =
      if String.starts_with?(name, "dm:") do
        :ok
      else
        Validation.validate_name(name)
      end

    case valid do
      {:error, _} = err ->
        {:reply, err, state}

      :ok ->
        if namespace_taken?(state.writer, name) do
          {:reply, {:error, :name_taken}, state}
        else
          case exec_write(
                 state.writer,
                 "INSERT INTO topics (name, description, type, created_by) VALUES (?1, ?2, ?3, ?4)",
                 [name, description, type, created_by]
               ) do
            :ok -> {:reply, :ok, state}
            {:error, _} = err -> {:reply, err, state}
          end
        end
    end
  end

  def handle_call({:update_agent, name, attrs}, _from, state) do
    sets = []
    params = []
    idx = 1

    {sets, params, idx} =
      if Map.has_key?(attrs, :description) do
        {sets ++ ["description = ?#{idx}"], params ++ [attrs[:description]], idx + 1}
      else
        {sets, params, idx}
      end

    {sets, params, _idx} =
      if Map.has_key?(attrs, :personality) do
        {sets ++ ["personality = ?#{idx}"], params ++ [attrs[:personality]], idx + 1}
      else
        {sets, params, idx}
      end

    if sets == [] do
      {:reply, {:error, :no_changes}, state}
    else
      param_idx = length(params) + 1
      sql = "UPDATE agents SET #{Enum.join(sets, ", ")} WHERE name = ?#{param_idx}"
      result = exec_write(state.writer, sql, params ++ [name])
      {:reply, result, state}
    end
  end

  def handle_call({:delete_agent, name}, _from, state) do
    result = exec_write(state.writer, "DELETE FROM agents WHERE name = ?1", [name])
    {:reply, result, state}
  end

  def handle_call({:delete_topic, name}, _from, state) do
    result = exec_write(state.writer, "DELETE FROM topics WHERE name = ?1", [name])
    {:reply, result, state}
  end

  def handle_call({:subscribe, topic, agent}, _from, state) do
    result =
      exec_write(
        state.writer,
        "INSERT OR IGNORE INTO subscriptions (topic, agent) VALUES (?1, ?2)",
        [
          topic,
          agent
        ]
      )

    {:reply, result, state}
  end

  def handle_call({:unsubscribe, topic, agent}, _from, state) do
    result =
      exec_write(state.writer, "DELETE FROM subscriptions WHERE topic = ?1 AND agent = ?2", [
        topic,
        agent
      ])

    {:reply, result, state}
  end

  def handle_call({:update_agent_personality, agent, content}, _from, state) do
    result =
      exec_write(state.writer, "UPDATE agents SET personality = ?1 WHERE name = ?2", [
        content,
        agent
      ])

    {:reply, result, state}
  end

  def handle_call({:create_mcp_server, name, description, command, args, env}, _from, state) do
    args_json = Jason.encode!(args)
    env_json = Jason.encode!(env)

    result =
      exec_write(
        state.writer,
        "INSERT INTO mcp_servers (name, description, command, args, env) VALUES (?1, ?2, ?3, ?4, ?5)",
        [name, description, command, args_json, env_json]
      )

    {:reply, result, state}
  end

  def handle_call({:update_mcp_server, name, attrs}, _from, state) do
    sets = []
    params = []
    idx = 1

    {sets, params, idx} =
      if Map.has_key?(attrs, :description) do
        {sets ++ ["description = ?#{idx}"], params ++ [attrs[:description]], idx + 1}
      else
        {sets, params, idx}
      end

    {sets, params, idx} =
      if Map.has_key?(attrs, :command) do
        {sets ++ ["command = ?#{idx}"], params ++ [attrs[:command]], idx + 1}
      else
        {sets, params, idx}
      end

    {sets, params, idx} =
      if Map.has_key?(attrs, :args) do
        {sets ++ ["args = ?#{idx}"], params ++ [Jason.encode!(attrs[:args])], idx + 1}
      else
        {sets, params, idx}
      end

    {sets, params, _idx} =
      if Map.has_key?(attrs, :env) do
        {sets ++ ["env = ?#{idx}"], params ++ [Jason.encode!(attrs[:env])], idx + 1}
      else
        {sets, params, idx}
      end

    if sets == [] do
      {:reply, {:error, :no_changes}, state}
    else
      param_idx = length(params) + 1
      sql = "UPDATE mcp_servers SET #{Enum.join(sets, ", ")} WHERE name = ?#{param_idx}"
      result = exec_write(state.writer, sql, params ++ [name])
      {:reply, result, state}
    end
  end

  def handle_call({:delete_mcp_server, name}, _from, state) do
    result = exec_write(state.writer, "DELETE FROM mcp_servers WHERE name = ?1", [name])
    {:reply, result, state}
  end

  def handle_call({:assign_mcp_server, agent, mcp_server, allowed_tools}, _from, state) do
    tools_json = Jason.encode!(allowed_tools)

    result =
      exec_write(
        state.writer,
        "INSERT OR REPLACE INTO agent_mcp_servers (agent, mcp_server, allowed_tools) VALUES (?1, ?2, ?3)",
        [agent, mcp_server, tools_json]
      )

    {:reply, result, state}
  end

  def handle_call({:unassign_mcp_server, agent, mcp_server}, _from, state) do
    result =
      exec_write(
        state.writer,
        "DELETE FROM agent_mcp_servers WHERE agent = ?1 AND mcp_server = ?2",
        [
          agent,
          mcp_server
        ]
      )

    {:reply, result, state}
  end

  # -------------------------------------------------------------------
  # Internal helpers
  # -------------------------------------------------------------------

  defp reader_key(server_name), do: {__MODULE__, :reader, server_name}

  defp get_reader(server) do
    :persistent_term.get(reader_key(server))
  end

  defp set_pragmas(conn) do
    :ok = Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
    :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout=5000")
    :ok = Sqlite3.execute(conn, "PRAGMA synchronous=NORMAL")
    :ok = Sqlite3.execute(conn, "PRAGMA foreign_keys=ON")
  end

  defp set_reader_pragmas(conn) do
    :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout=5000")
  end

  defp run_migrations(conn) do
    :ok =
      Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS agents (
        name TEXT PRIMARY KEY,
        description TEXT NOT NULL,
        personality TEXT NOT NULL,
        config TEXT DEFAULT '{}'
      )
      """)

    :ok =
      Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS topics (
        name TEXT PRIMARY KEY,
        description TEXT,
        type TEXT DEFAULT 'topic',
        created_by TEXT,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
      """)

    :ok =
      Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        topic TEXT NOT NULL REFERENCES topics(name),
        sender TEXT NOT NULL,
        body TEXT NOT NULL,
        ts DATETIME DEFAULT CURRENT_TIMESTAMP
      )
      """)

    :ok =
      Sqlite3.execute(
        conn,
        "CREATE INDEX IF NOT EXISTS idx_messages_topic_ts ON messages(topic, ts)"
      )

    :ok =
      Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS subscriptions (
        topic TEXT NOT NULL REFERENCES topics(name) ON DELETE CASCADE,
        agent TEXT NOT NULL REFERENCES agents(name) ON DELETE CASCADE,
        joined_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (topic, agent)
      )
      """)

    :ok =
      Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS mcp_servers (
        name TEXT PRIMARY KEY,
        description TEXT,
        command TEXT NOT NULL,
        args TEXT NOT NULL DEFAULT '[]',
        env TEXT NOT NULL DEFAULT '{}'
      )
      """)

    :ok =
      Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS agent_mcp_servers (
        agent TEXT NOT NULL REFERENCES agents(name) ON DELETE CASCADE,
        mcp_server TEXT NOT NULL REFERENCES mcp_servers(name) ON DELETE CASCADE,
        allowed_tools TEXT NOT NULL DEFAULT '[]',
        PRIMARY KEY (agent, mcp_server)
      )
      """)
  end

  defp with_statement(conn, sql, params, fun) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    :ok = Sqlite3.bind(stmt, params)

    try do
      fun.(stmt)
    after
      Sqlite3.release(conn, stmt)
    end
  end

  defp namespace_taken?(conn, name) do
    with_statement(
      conn,
      "SELECT 1 FROM agents WHERE name = ?1 UNION SELECT 1 FROM topics WHERE name = ?1 LIMIT 1",
      [name],
      fn stmt ->
        case Sqlite3.step(conn, stmt) do
          {:row, _} -> true
          :done -> false
          :busy -> true
        end
      end
    )
  end

  defp exec_write(conn, sql, params) do
    with_statement(conn, sql, params, fn stmt ->
      case Sqlite3.step(conn, stmt) do
        :done -> :ok
        {:error, reason} -> {:error, reason}
        :busy -> {:error, :busy}
        {:row, _} -> :ok
      end
    end)
  end

  defp query_all(conn, sql, params, columns) do
    with_statement(conn, sql, params, fn stmt ->
      case Sqlite3.fetch_all(conn, stmt) do
        {:ok, rows} -> {:ok, Enum.map(rows, fn row -> row_to_map(row, columns) end)}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp query_one(conn, sql, params, columns) do
    with_statement(conn, sql, params, fn stmt ->
      case Sqlite3.step(conn, stmt) do
        {:row, row} -> {:ok, row_to_map(row, columns)}
        :done -> {:ok, nil}
        :busy -> {:error, :busy}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp row_to_map(row, columns) do
    columns
    |> Enum.zip(row)
    |> Map.new()
  end
end
