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
    send_to_container capture_container_output
    container_new_window container_list_windows
    container_split_pane container_list_panes
    write_skill read_skill delete_skill write_claude_md
    upload_media extract_container_file view_image
    create_event_source list_event_sources delete_event_source
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
         :ok <- Hive.Topic.post(topic, agent, text) do
      {:ok, "Message sent to #{topic}"}
    else
      error -> error
    end
  end

  defp execute_tool(agent, "send_dm", %{"text" => text} = params) do
    with {:ok, recipient} <- resolve_dm_recipient(agent, params),
         {:ok, dm_name} <- Hive.Topic.ensure_dm(agent, recipient),
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
    case Hive.Container.start(agent, params) do
      {:ok, container_id} ->
        {:ok, "Container #{container_id} launched with an empty bash shell. Use send_to_container to run commands."}

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp execute_tool(_agent, "check_execution", %{"container_id" => id}) do
    Hive.Container.check(id)
  end

  defp execute_tool(_agent, "send_to_container", %{"container_id" => id} = params) do
    Hive.Container.send_input(id, params)
  end

  defp execute_tool(_agent, "capture_container_output", %{"container_id" => id} = params) do
    Hive.Container.capture_output(id, params)
  end

  defp execute_tool(_agent, "container_new_window", %{"container_id" => id, "name" => name} = params) do
    Hive.Container.new_window(id, name, params["command"])
  end

  defp execute_tool(_agent, "container_list_windows", %{"container_id" => id}) do
    Hive.Container.list_windows(id)
  end

  defp execute_tool(_agent, "container_split_pane", %{"container_id" => id} = params) do
    Hive.Container.split_pane(
      id,
      Map.get(params, "direction", "vertical"),
      Map.get(params, "window", "0"),
      params["command"]
    )
  end

  defp execute_tool(_agent, "container_list_panes", %{"container_id" => id} = params) do
    Hive.Container.list_panes(id, Map.get(params, "window", "0"))
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

  defp execute_tool(_agent, "upload_media", %{"data" => base64, "media_type" => media_type}) do
    with {:ok, data} <- Base.decode64(base64),
         {:ok, url} <- Hive.Media.save(data, media_type) do
      {:ok, url}
    else
      :error -> {:error, "invalid base64 data"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_tool(_agent, "extract_container_file", %{"container_id" => id, "path" => path}) do
    with {:ok, data, media_type} <- Hive.Container.extract_file(id, path),
         {:ok, url} <- Hive.Media.save(data, media_type) do
      {:ok, url}
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

  defp execute_tool(_agent, "create_event_source", params) do
    name = params["name"]
    type = params["type"]
    topic = params["topic"]
    config = params["config"] || %{}

    with :ok <- Hive.Validation.validate_name(name) do
      config_json = if is_binary(config), do: config, else: Jason.encode!(config)

      webhook_secret =
        if type == "webhook" do
          :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
        end

      attrs = %{
        type: type,
        topic: topic,
        config: config_json,
        webhook_secret: webhook_secret,
        mcp_server: params["mcp_server"],
        enabled: 1
      }

      case Hive.Persistence.create_event_source(name, attrs) do
        :ok ->
          # Start if poll type
          if type == "poll" do
            DynamicSupervisor.start_child(
              Hive.EventSourceSup,
              {Hive.Connector.EventSource,
               [
                 name: name,
                 type: type,
                 topic: topic,
                 config: config_json,
                 enabled: 1
               ]}
            )
          end

          result = %{name: name, type: type, topic: topic}

          result =
            if webhook_secret,
              do: Map.put(result, :webhook_url, "/api/hooks/#{name}/#{webhook_secret}"),
              else: result

          {:ok, Jason.encode!(result)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp execute_tool(_agent, "list_event_sources", _params) do
    case Hive.Persistence.get_event_sources() do
      {:ok, sources} -> {:ok, Jason.encode!(sources)}
      {:error, _} = error -> error
    end
  end

  defp execute_tool(_agent, "delete_event_source", %{"name" => name}) do
    # Stop GenServer if running
    try do
      Hive.Connector.EventSource.stop(name)
    catch
      :exit, _ -> :ok
    end

    case Hive.Persistence.delete_event_source(name) do
      :ok -> {:ok, "Event source '#{name}' deleted"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_tool(_agent, tool, _params) do
    {:error, "Unknown tool: #{tool}"}
  end

  defdelegate sender_kind(sender), to: Hive.Util
  defdelegate format_history_timestamp(ts), to: Hive.Util, as: :format_timestamp

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
end
