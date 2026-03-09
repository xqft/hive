defmodule HiveWeb.WebhookController do
  use HiveWeb, :controller
  require Logger

  def receive_event(conn, %{"event_source_name" => name, "secret" => secret}) do
    case Hive.Persistence.get_event_source(name) do
      {:ok, nil} ->
        conn |> put_status(404) |> json(%{error: "not found"})

      {:ok, source} ->
        cond do
          not Plug.Crypto.secure_compare(source.webhook_secret || "", secret) ->
            conn |> put_status(401) |> json(%{error: "unauthorized"})

          source.enabled != 1 ->
            conn |> put_status(503) |> json(%{error: "event source disabled"})

          true ->
            payload = Jason.encode!(conn.body_params)
            Hive.Connector.EventSource.post_event(name, payload)
            json(conn, %{ok: true})
        end

      {:error, _} ->
        conn |> put_status(500) |> json(%{error: "internal error"})
    end
  end
end
