defmodule HiveWeb.AgentRoutingTest do
  use HiveWeb.ConnCase, async: false

  defp mcp_secret(agent_name) do
    app_secret = Application.get_env(:hive, :secret_key_base)

    :crypto.mac(:hmac, :sha256, app_secret, "mcp:#{agent_name}")
    |> Base.url_encode64(padding: false)
  end

  defp authed_conn(conn, agent_name) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{mcp_secret(agent_name)}")
  end

  defp tool_call(conn, agent, tool, params) do
    conn
    |> authed_conn(agent)
    |> post("/api/tools", %{agent: agent, tool: tool, params: params})
  end

  defp put_hive_env(key, value) do
    previous = Application.get_env(:hive, key)
    Application.put_env(:hive, key, value)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:hive, key)
      else
        Application.put_env(:hive, key, previous)
      end
    end)
  end

  defp create_topic(name) do
    case Hive.Persistence.create_topic(name, "routing test", "topic", "human") do
      :ok -> :ok
      {:error, :name_taken} -> :ok
    end

    case Registry.lookup(Hive.TopicRegistry, name) do
      [{pid, _}] ->
        pid

      [] ->
        start_supervised!(%{
          id: {Hive.Topic, name},
          start:
            {Hive.Topic, :start_link,
             [[name: name, description: "routing test", type: :topic, created_by: "human"]]}
        })
    end
  end

  defp cleanup_topic(name) do
    case Registry.lookup(Hive.TopicRegistry, name) do
      [{pid, _}] ->
        try do
          GenServer.stop(pid, :normal)
        catch
          :exit, _ -> :ok
        end

      [] ->
        :ok
    end

    Hive.Persistence.delete_topic(name)
  end

  setup do
    put_hive_env(:agent_active_channel_overrides, %{})
    :ok
  end

  describe "agent reply routing" do
    test "send_message defaults to the active topic context", %{conn: conn} do
      topic = "routing-topic-#{:erlang.unique_integer([:positive])}"
      create_topic(topic)
      on_exit(fn -> cleanup_topic(topic) end)

      put_hive_env(:agent_active_channel_overrides, %{"routing-agent" => {"topic", topic}})

      body =
        conn
        |> tool_call("routing-agent", "send_message", %{"text" => "in-thread reply"})
        |> json_response(200)

      assert body["ok"] == true
      assert body["result"] =~ topic

      messages = Hive.Topic.recent(topic, 10)
      assert Enum.any?(messages, &(&1.body == "in-thread reply"))
    end

    test "send_message allows cross-topic posting", %{conn: conn} do
      active_topic = "routing-active-#{:erlang.unique_integer([:positive])}"
      other_topic = "routing-other-#{:erlang.unique_integer([:positive])}"

      create_topic(active_topic)
      create_topic(other_topic)

      on_exit(fn ->
        cleanup_topic(active_topic)
        cleanup_topic(other_topic)
      end)

      put_hive_env(:agent_active_channel_overrides, %{"routing-agent" => {"topic", active_topic}})

      body =
        conn
        |> tool_call("routing-agent", "send_message", %{
          "topic" => other_topic,
          "text" => "cross-topic post"
        })
        |> json_response(200)

      assert body["ok"] == true
      assert body["result"] =~ other_topic

      messages = Hive.Topic.recent(other_topic, 10)
      assert Enum.any?(messages, &(&1.body == "cross-topic post"))
    end

    test "send_dm from a topic context works without reason", %{conn: conn} do
      topic = "routing-topic-dm-#{:erlang.unique_integer([:positive])}"
      dm_name = Hive.Topic.dm_channel_name("routing-agent", "human")

      create_topic(topic)

      on_exit(fn ->
        cleanup_topic(topic)
        cleanup_topic(dm_name)
      end)

      put_hive_env(:agent_active_channel_overrides, %{"routing-agent" => {"topic", topic}})

      body =
        conn
        |> tool_call("routing-agent", "send_dm", %{
          "to" => "human",
          "text" => "private follow-up"
        })
        |> json_response(200)

      assert body["ok"] == true
      assert body["result"] =~ "DM sent to human"

      messages = Hive.Topic.recent(dm_name, 10)
      assert Enum.any?(messages, &(&1.body == "private follow-up"))
    end
  end
end
