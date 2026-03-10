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
    create_agent delete_agent
    write_skill read_skill delete_skill write_claude_md
    upload_media view_image
    tmux_send tmux_read
  )

  def call_tool(conn, %{"agent" => agent, "tool" => tool, "params" => params}) do
    with :ok <- verify_hmac(conn, agent),
         :ok <- check_permission(tool) do
      case execute_tool(agent, tool, params) do
        {:ok, result} ->
          json(conn, %{ok: true, result: result})

        {:error, reason} ->
          json(conn, %{ok: false, error: format_error(reason)})
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

  defp execute_tool(agent, "send_message", %{"text" => text} = params) do
    with {:ok, topic} <- resolve_topic_reply_target(agent, params),
         :ok <- check_steering(agent, topic),
         :ok <- Hive.Topic.post(topic, agent, text) do
      {:ok, "Message sent to #{topic}"}
    else
      error -> error
    end
  end

  defp execute_tool(agent, "send_dm", %{"text" => text} = params) do
    with {:ok, recipient} <- resolve_dm_recipient(agent, params),
         {:ok, dm_name} <- Hive.Topic.ensure_dm(agent, recipient),
         :ok <- check_steering(agent, dm_name),
         :ok <- Hive.Topic.post(dm_name, agent, text) do
      {:ok, "DM sent to #{recipient}"}
    else
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

  defp execute_tool(_agent, "create_agent", params) do
    name = params["name"]
    description = params["description"] || ""
    personality = params["personality"] || ""

    with :ok <- Hive.Validation.validate_name(name),
         :ok <- Hive.Persistence.create_agent(name, description, personality) do
      DynamicSupervisor.start_child(
        Hive.AgentSup,
        {Hive.Agent, name: name, description: description, personality: personality}
      )

      Phoenix.PubSub.broadcast(Hive.PubSub, "registry", {:agent_created, name})

      {:ok, "Agent '#{name}' created"}
    end
  end

  defp execute_tool(_agent, "delete_agent", %{"name" => name}) do
    case Hive.Persistence.get_agent(name) do
      {:ok, nil} ->
        {:error, "Agent '#{name}' not found"}

      {:ok, _agent} ->
        # Stop the GenServer (may already be stopped)
        try do
          Hive.Agent.stop(name)
        catch
          :exit, _ -> :ok
        end

        Hive.Persistence.delete_agent(name)

        # Clean up working directory
        agent_dir = Path.join(["priv", "agents", name]) |> Path.expand()
        File.rm_rf(agent_dir)

        Phoenix.PubSub.broadcast(Hive.PubSub, "registry", {:agent_deleted, name})

        {:ok, "Agent '#{name}' deleted"}
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

  defp execute_tool(agent, "write_skill", %{"name" => name, "content" => content}) do
    with :ok <- Hive.Validation.validate_name(name) do
      dir = Path.join(["priv", "agents", agent, ".claude", "skills", name])
      File.mkdir_p!(dir)
      skill_path = Path.join(dir, "SKILL.md")
      File.write!(skill_path, content)
      sync_to_container(agent, skill_path, "/workspace/.claude/skills/#{name}/SKILL.md")
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
      delete_from_container(agent, "/workspace/.claude/skills/#{name}")
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
    sync_to_container(agent, path, "/workspace/CLAUDE.md")
    {:ok, "CLAUDE.md updated at #{path}"}
  end

  defp execute_tool(_agent, "upload_media", %{"data" => base64, "media_type" => media_type}) do
    with {:ok, data} <- Base.decode64(base64),
         {:ok, url} <- Hive.Media.save(data, media_type) do
      {:ok, url}
    else
      :error -> {:error, "invalid base64 data"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_tool(_agent, "view_image", %{"url" => url}) do
    if String.starts_with?(url, "/uploads/") do
      path = Path.join([:code.priv_dir(:hive) |> to_string(), "static", url])

      if File.exists?(path) do
        data = File.read!(path)
        {:ok, %{base64: Base.encode64(data), media_type: MIME.from_path(path)}}
      else
        {:error, "image not found"}
      end
    else
      {:error, "only /uploads/ URLs are supported"}
    end
  end

  defp execute_tool(agent, "tmux_send", params) do
    container_name = "hive-agent-#{agent}"
    docker = docker_executable()
    text = params["text"]
    keys = params["keys"]
    wait_ms = params["wait_ms"] || 0

    # Send literal text if provided
    if text do
      System.cmd(docker, [
        "exec", container_name, "tmux", "send-keys", "-t", "shell", "-l", text
      ], stderr_to_stdout: true)
    end

    # Send special keys if provided
    if keys do
      System.cmd(docker, [
        "exec", container_name, "tmux", "send-keys", "-t", "shell", keys
      ], stderr_to_stdout: true)
    end

    if wait_ms > 0 do
      wait_ms = min(wait_ms, 30_000)
      Process.sleep(wait_ms)
      capture_tmux_pane(container_name, docker)
    else
      {:ok, "sent"}
    end
  end

  defp execute_tool(agent, "tmux_read", params) do
    container_name = "hive-agent-#{agent}"
    docker = docker_executable()
    wait = min(params["wait"] || 1000, 30_000)

    if wait > 0, do: Process.sleep(wait)
    capture_tmux_pane(container_name, docker)
  end

  defp execute_tool(_agent, tool, _params) do
    {:error, "Unknown tool: #{tool}"}
  end

  defdelegate sender_kind(sender), to: Hive.Util
  defdelegate format_history_timestamp(ts), to: Hive.Util, as: :format_timestamp

  defp capture_tmux_pane(container_name, docker) do
    case System.cmd(docker, [
      "exec", container_name, "tmux", "capture-pane", "-p", "-S", "-200", "-t", "shell"
    ], stderr_to_stdout: true) do
      {output, 0} ->
        # Strip trailing blank lines, truncate to 50KB
        content = output |> String.trim_trailing() |> String.slice(0, 50_000)
        {:ok, content}
      {error, _} ->
        {:error, "Failed to read terminal: #{String.trim(error)}"}
    end
  end

  defp docker_executable do
    Application.get_env(:hive, :container_docker_executable) ||
      System.find_executable("docker") ||
      "docker"
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp resolve_topic_reply_target(agent, params) do
    requested_topic = blank_to_nil(params["topic"])

    case agent_active_channel(agent) do
      {"topic", active_topic} ->
        cond do
          is_nil(requested_topic) ->
            {:ok, active_topic}

          requested_topic == active_topic ->
            {:ok, active_topic}

          true ->
            {:error,
             "Current reply context is topic #{active_topic}; send_message can only post there"}
        end

      {"dm", dm_name} ->
        {:error, "Current reply context is DM #{dm_name}; use send_dm for same-channel replies"}

      nil ->
        if requested_topic do
          {:ok, requested_topic}
        else
          {:error, "topic is required when there is no active topic context"}
        end
    end
  end

  defp resolve_dm_recipient(agent, params) do
    requested_recipient = blank_to_nil(params["to"])

    case agent_active_channel(agent) do
      {"dm", dm_name} ->
        expected_recipient = dm_other_party(dm_name, agent)
        recipient = requested_recipient || expected_recipient

        if recipient == expected_recipient do
          {:ok, recipient}
        else
          {:error,
           "Current reply context is DM #{dm_name}; send_dm can only target #{expected_recipient}"}
        end

      {"topic", active_topic} ->
        if explicit_out_of_band_reason?(params) do
          require_dm_recipient(requested_recipient)
        else
          {:error,
           "Current reply context is topic #{active_topic}; reply there with send_message unless you intentionally need a DM and include a reason"}
        end

      nil ->
        require_dm_recipient(requested_recipient)
    end
  end

  defp require_dm_recipient(nil),
    do: {:error, "to is required when there is no active DM context"}

  defp require_dm_recipient(recipient), do: {:ok, recipient}

  defp explicit_out_of_band_reason?(params) do
    params["reason"]
    |> blank_to_nil()
    |> is_binary()
  end

  defp agent_active_channel(agent) do
    overrides = Application.get_env(:hive, :agent_active_channel_overrides, %{})

    case Map.get(overrides, agent) do
      nil ->
        try do
          Hive.Agent.active_channel(agent)
        catch
          :exit, _ -> nil
        end

      override ->
        override
    end
  end

  defdelegate dm_other_party(dm_name, self_name), to: Hive.Util

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  # ---------------------------------------------------------------------------
  # Mid-turn steering: surface new messages before the agent sends
  # ---------------------------------------------------------------------------

  # Only steer when:
  # 1. The agent is composing for this specific channel (same-channel check)
  # 2. The agent hasn't already been steered this turn (once-per-turn)
  # 3. New messages from others arrived after composing started
  defp check_steering(agent, topic) do
    {active_channel, composing_since, steered} = agent_steering_info(agent)

    target_channel = channel_tuple(topic)

    cond do
      # Not composing, or composing for a different channel — skip
      is_nil(composing_since) or active_channel != target_channel ->
        :ok

      # Already steered once this turn — let it through
      steered ->
        :ok

      true ->
        new_messages =
          topic
          |> Hive.Topic.recent(10)
          |> Enum.filter(fn msg ->
            msg.sender != agent and
              DateTime.compare(ensure_datetime(msg.ts), composing_since) == :gt
          end)

        if new_messages == [] do
          :ok
        else
          notify_steering_delivered(agent)

          formatted =
            new_messages
            |> Enum.reverse()
            |> Enum.map_join("\n", fn msg ->
              "[#{format_history_timestamp(msg.ts)}] #{msg.sender} (#{sender_kind(msg.sender)}): #{msg.body}"
            end)

          {:error,
           "HOLD — new messages arrived in #{topic} while you were composing. " <>
             "Review them before sending:\n#{formatted}\n\n" <>
             "Decide: adjust your message, wait for the conversation to settle, " <>
             "or send as-is by calling send_message again."}
        end
    end
  end

  defp agent_steering_info(agent) do
    overrides = Application.get_env(:hive, :agent_steering_overrides, %{})

    case Map.get(overrides, agent) do
      nil ->
        try do
          Hive.Agent.steering_info(agent)
        catch
          :exit, _ -> {nil, nil, false}
        end

      override ->
        override
    end
  end

  defp channel_tuple(topic) do
    if String.starts_with?(topic, "dm:"),
      do: {"dm", topic},
      else: {"topic", topic}
  end

  defp notify_steering_delivered(agent) do
    case Registry.lookup(Hive.AgentRegistry, agent) do
      [{pid, _}] -> send(pid, :steering_delivered)
      [] -> :ok
    end
  end

  defp ensure_datetime(%DateTime{} = dt), do: dt

  defp ensure_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} ->
        dt

      {:error, _} ->
        # SQLite timestamps are "YYYY-MM-DD HH:MM:SS" (no timezone)
        case NaiveDateTime.from_iso8601(str) do
          {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
          {:error, _} -> DateTime.utc_now()
        end
    end
  end

  defp ensure_datetime(_), do: DateTime.utc_now()

  # ---------------------------------------------------------------------------
  # Container file sync helpers
  # ---------------------------------------------------------------------------

  defp sync_to_container(agent, host_path, container_path) do
    try do
      Hive.Agent.copy_to_container(agent, host_path, container_path)
    catch
      :exit, _ -> :ok
    end
  end

  defp delete_from_container(agent, container_path) do
    try do
      container_name = "hive-agent-#{agent}"

      docker =
        Application.get_env(:hive, :container_docker_executable) ||
          System.find_executable("docker") || "docker"

      System.cmd(docker, ["exec", container_name, "rm", "-rf", container_path],
        stderr_to_stdout: true
      )
    catch
      :exit, _ -> :ok
    end
  end
end
