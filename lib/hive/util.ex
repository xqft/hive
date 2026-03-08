defmodule Hive.Util do
  @moduledoc """
  Shared utility functions used across Hive modules.
  """

  @doc "Broadcast via PubSub, silently swallowing crashes if PubSub is unavailable."
  def safe_broadcast(topic, payload) do
    Phoenix.PubSub.broadcast(Hive.PubSub, topic, payload)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Infer sender kind from the sender name."
  def sender_kind("human"), do: "human"
  def sender_kind("system"), do: "system"
  def sender_kind(_sender), do: "agent"

  @doc "Ensure a message map has a `:sender_kind` field."
  def with_sender_kind(message) do
    Map.put_new(message, :sender_kind, sender_kind(Map.get(message, :sender)))
  end

  @doc "Format a timestamp for display in agent messages."
  def format_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  def format_timestamp(timestamp) when is_binary(timestamp), do: timestamp
  def format_timestamp(_timestamp), do: "unknown"

  @doc "Parse a JSON string field, returning `default` on nil or decode failure."
  def parse_json_field(nil, default), do: default

  def parse_json_field(value, default) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, parsed} -> parsed
      _ -> default
    end
  end

  def parse_json_field(value, _default), do: value

  @doc "Extract the other party from a DM channel name like `dm:a:b`."
  def dm_other_party("dm:" <> rest, self_name) do
    case String.split(rest, ":", parts: 2) do
      [a, b] -> if a == self_name, do: b, else: a
      _ -> self_name
    end
  end

  def dm_other_party(_, self_name), do: self_name
end
