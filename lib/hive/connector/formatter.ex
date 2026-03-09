defmodule Hive.Connector.Formatter do
  @moduledoc """
  Formats raw event payloads into concise summaries using Claude Haiku,
  falling back to truncation when no API key is configured.
  """

  def format(source_name, raw_payload) do
    api_key = Application.get_env(:hive, :anthropic_api_key)

    if api_key do
      format_with_haiku(source_name, raw_payload, api_key)
    else
      fallback(source_name, raw_payload)
    end
  end

  defp format_with_haiku(source_name, raw_payload, api_key) do
    body = %{
      model: "claude-haiku-4-5-20251001",
      max_tokens: 256,
      system:
        "You summarize external events for a multi-agent system. Produce one concise line (max 280 chars). Include key identifiers. No markdown, no preamble.",
      messages: [
        %{role: "user", content: "[#{source_name}] event:\n#{truncate(raw_payload, 4000)}"}
      ]
    }

    case Req.post("https://api.anthropic.com/v1/messages",
           json: body,
           headers: [{"x-api-key", api_key}, {"anthropic-version", "2023-06-01"}],
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
        {:ok, "[#{source_name}] #{text}"}

      _ ->
        fallback(source_name, raw_payload)
    end
  end

  defp fallback(source_name, raw_payload),
    do: {:ok, "[#{source_name}] #{truncate(raw_payload, 500)}"}

  defp truncate(s, max) when byte_size(s) <= max, do: s
  defp truncate(s, max), do: String.slice(s, 0, max) <> "..."
end
