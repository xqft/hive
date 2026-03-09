defmodule HiveWeb.WebhookControllerTest do
  use HiveWeb.ConnCase, async: false

  setup %{conn: conn} do
    conn = put_req_header(conn, "content-type", "application/json")
    {:ok, conn: conn}
  end

  defp unique(prefix) do
    ts = rem(System.system_time(:millisecond), 100_000)
    n = :erlang.unique_integer([:positive])
    "#{prefix}-#{ts}n#{n}"
  end

  defp create_event_source(name, opts \\ []) do
    topic = Keyword.get(opts, :topic, "test-topic")
    secret = Keyword.get(opts, :secret, "test-secret-123")
    enabled = Keyword.get(opts, :enabled, true)

    # Ensure the topic exists
    Hive.Persistence.create_topic(topic, "test", "topic", nil)

    attrs = %{
      type: "webhook",
      topic: topic,
      config: %{},
      webhook_secret: secret,
      enabled: enabled
    }

    :ok = Hive.Persistence.create_event_source(name, attrs)

    on_exit(fn ->
      Hive.Persistence.delete_event_source(name)
      Hive.Persistence.delete_topic(topic)
    end)

    {name, secret, topic}
  end

  describe "receive_event" do
    test "valid webhook returns 200 and posts event", %{conn: conn} do
      name = unique("wh-src")
      topic = unique("wh-topic")
      {_name, secret, _topic} = create_event_source(name, topic: topic, secret: "mysecret")

      # Start the topic GenServer so post_event can deliver
      start_supervised!(
        {Hive.Topic, name: topic, description: "test", type: :topic, created_by: "system"}
      )

      conn =
        conn
        |> post("/api/hooks/#{name}/#{secret}", %{event: "push", repo: "test/repo"})

      assert json_response(conn, 200) == %{"ok" => true}
    end

    test "wrong secret returns 401", %{conn: conn} do
      name = unique("wh-auth")
      topic = unique("wh-auth-t")
      create_event_source(name, topic: topic, secret: "correct-secret")

      conn =
        conn
        |> post("/api/hooks/#{name}/wrong-secret", %{data: "test"})

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "non-existent source returns 404", %{conn: conn} do
      conn =
        conn
        |> post("/api/hooks/nonexistent/anysecret", %{data: "test"})

      assert json_response(conn, 404) == %{"error" => "not found"}
    end

    test "disabled source returns 503", %{conn: conn} do
      name = unique("wh-dis")
      topic = unique("wh-dis-t")
      {_name, secret, _topic} = create_event_source(name, topic: topic, secret: "dis-secret", enabled: false)

      conn =
        conn
        |> post("/api/hooks/#{name}/#{secret}", %{data: "test"})

      assert json_response(conn, 503) == %{"error" => "event source disabled"}
    end
  end
end
