defmodule HiveWeb.ToolsController do
  @moduledoc """
  Single HTTP endpoint handling all agent tool calls via the MCP bridge.

  Every agent's MCP bridge POSTs here with `{agent, tool, params}` and an
  HMAC-based Authorization header. The controller verifies the HMAC, checks
  the tool is in the allow-list, dispatches to the appropriate Hive module,
  and returns a JSON response.
  """

  use HiveWeb, :controller

  require Logger

  @agent_tools ~w(
    send_message send_dm create_topic join_topic leave_topic
    get_topic_history list_agents list_topics
    execute_in_container check_execution
    write_skill read_skill delete_skill write_claude_md
  )

  def call_tool(conn, %{"agent" => agent, "tool" => tool, "params" => params}) do
    with :ok <- verify_hmac(conn, agent),
         :ok <- check_permission(tool) do
      case execute_tool(agent, tool, params) do
        {:ok, result} ->
          json(conn, %{ok: true, result: result})

        {:error, reason} ->
          json(conn, %{ok: false, error: to_string(reason)})
      end
    else
      {:error, :unauthorized} ->
        conn |> put_status(401) |> json(%{ok: false, error: "unauthorized"})

      {:error, :forbidden} ->
        conn |> put_status(403) |> json(%{ok: false, error: "forbidden"})
    end
  end

  # Catch malformed requests
  def call_tool(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{ok: false, error: "missing required fields: agent, tool, params"})
  end

  # ---------------------------------------------------------------------------
  # Auth & permission
  # ---------------------------------------------------------------------------

  defp verify_hmac(conn, agent) do
    expected = Hive.Agent.mcp_secret(agent)
    provided = get_req_header(conn, "authorization") |> List.first()

    if Plug.Crypto.secure_compare("Bearer #{expected}", provided || ""),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp check_permission(tool) do
    if tool in @agent_tools, do: :ok, else: {:error, :forbidden}
  end

  # ---------------------------------------------------------------------------
  # Tool implementations
  # ---------------------------------------------------------------------------

  defp execute_tool(agent, "send_message", %{"topic" => topic, "text" => text}) do
    case Hive.Topic.post(topic, agent, text) do
      :ok -> {:ok, "Message sent to #{topic}"}
      error -> error
    end
  end

  defp execute_tool(agent, "send_dm", %{"to" => to, "text" => text}) do
    {:ok, dm_name} = Hive.Topic.ensure_dm(agent, to)

    case Hive.Topic.post(dm_name, agent, text) do
      :ok -> {:ok, "DM sent to #{to}"}
      error -> error
    end
  end

  defp execute_tool(agent, "create_topic", params) do
    name = params["name"]
    description = params["description"] || ""
    invite = params["invite"] || []

    with :ok <- Hive.Validation.validate_name(name),
         :ok <- Hive.Persistence.create_topic(name, description, "topic", agent) do
      # Start the topic GenServer
      DynamicSupervisor.start_child(
        Hive.TopicSup,
        {Hive.Topic, name: name, description: description, type: :topic, created_by: agent}
      )

      # Auto-subscribe creator
      Hive.Topic.join(name, agent)

      # Invite others
      Enum.each(invite, fn invitee ->
        Hive.Topic.join(name, invitee)

        # Notify the invited agent
        case Registry.lookup(Hive.AgentRegistry, invitee) do
          [{pid, _}] ->
            send(pid, {:system_message, "You were invited to topic '#{name}' by #{agent}."})

          [] ->
            :ok
        end
      end)

      # Broadcast for UI
      Phoenix.PubSub.broadcast(Hive.PubSub, "registry", {:topic_created, name, agent})

      {:ok, "Topic '#{name}' created"}
    end
  end

  defp execute_tool(agent, "join_topic", %{"topic" => topic}) do
    case Hive.Topic.join(topic, agent) do
      {:ok, recent} ->
        # Format recent messages for the agent
        context =
          Enum.map_join(recent, "\n", fn msg ->
            "  [#{format_history_timestamp(msg.ts)}] #{msg.sender} (#{sender_kind(msg.sender)}): #{msg.body}"
          end)

        {:ok, "Joined topic '#{topic}'. Recent messages:\n#{context}"}

      error ->
        error
    end
  end

  defp execute_tool(agent, "leave_topic", %{"topic" => topic}) do
    case Hive.Topic.leave(topic, agent) do
      :ok -> {:ok, "Left topic '#{topic}'"}
      error -> error
    end
  end

  defp execute_tool(_agent, "get_topic_history", %{"topic" => topic} = params) do
    n = min(params["n"] || 20, 50)

    case Hive.Persistence.get_messages(topic, n) do
      {:ok, messages} ->
        formatted =
          Enum.map_join(messages, "\n", fn msg ->
            "[#{format_history_timestamp(msg.ts)}] #{msg.sender} (#{sender_kind(msg.sender)}): #{msg.body}"
          end)

        {:ok, formatted}

      {:error, _} = error ->
        error
    end
  end

  defp execute_tool(_agent, "list_agents", _params) do
    case Hive.Persistence.get_agents() do
      {:ok, agents} ->
        formatted =
          Enum.map(agents, fn a ->
            status =
              try do
                Hive.Agent.status(a.name)
              catch
                _, _ -> :unknown
              end

            %{name: a.name, description: a.description, status: status}
          end)

        {:ok, Jason.encode!(formatted)}

      {:error, _} = error ->
        error
    end
  end

  defp execute_tool(_agent, "list_topics", _params) do
    case Hive.Persistence.get_topics() do
      {:ok, topics} ->
        formatted =
          Enum.map(topics, fn t ->
            subscribers =
              try do
                Hive.Topic.subscribers(t.name) |> MapSet.size()
              catch
                _, _ -> 0
              end

            %{name: t.name, description: t.description, type: t.type, subscribers: subscribers}
          end)

        {:ok, Jason.encode!(formatted)}

      {:error, _} = error ->
        error
    end
  end

  defp execute_tool(agent, "execute_in_container", params) do
    timeout_ms = (params["timeout_minutes"] || 10) * 60_000

    case Hive.Container.start(agent, params, timeout_ms) do
      {:ok, container_id} ->
        {:ok, "Container #{container_id} launched. You'll be notified when it completes."}

      {:error, :limit_reached, msg} ->
        {:error, msg}
    end
  end

  defp execute_tool(_agent, "check_execution", %{"container_id" => id}) do
    Hive.Container.check(id)
  end

  defp execute_tool(agent, "write_skill", %{"name" => name, "content" => content}) do
    with :ok <- Hive.Validation.validate_name(name) do
      dir = Path.join(["priv", "agents", agent, ".claude", "skills", name])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "SKILL.md"), content)
      {:ok, "Skill '#{name}' written to #{dir}/SKILL.md"}
    end
  end

  defp execute_tool(agent, "read_skill", %{"name" => name}) do
    path = Path.join(["priv", "agents", agent, ".claude", "skills", name, "SKILL.md"])

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, "Skill '#{name}' not found"}
    end
  end

  defp execute_tool(agent, "delete_skill", %{"name" => name}) do
    dir = Path.join(["priv", "agents", agent, ".claude", "skills", name])

    if File.exists?(dir) do
      {:ok, _} = File.rm_rf(dir)
      {:ok, "Skill '#{name}' deleted"}
    else
      {:error, "Skill '#{name}' not found"}
    end
  end

  defp execute_tool(agent, "write_claude_md", %{"content" => content}) do
    path = Path.join(["priv", "agents", agent, "CLAUDE.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    Hive.Persistence.update_agent_personality(agent, content)
    {:ok, "CLAUDE.md updated at #{path}"}
  end

  defp execute_tool(_agent, tool, _params) do
    {:error, "Unknown tool: #{tool}"}
  end

  defp sender_kind("human"), do: "human"
  defp sender_kind(_sender), do: "agent"

  defp format_history_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp format_history_timestamp(timestamp) when is_binary(timestamp), do: timestamp
  defp format_history_timestamp(_timestamp), do: "unknown"
end
