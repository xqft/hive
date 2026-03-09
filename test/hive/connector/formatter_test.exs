defmodule Hive.Connector.FormatterTest do
  use ExUnit.Case, async: true

  alias Hive.Connector.Formatter

  describe "format/2" do
    test "falls back when no API key is configured" do
      original = Application.get_env(:hive, :anthropic_api_key)

      try do
        Application.put_env(:hive, :anthropic_api_key, nil)
        assert {:ok, result} = Formatter.format("test-source", "some event data")
        assert result == "[test-source] some event data"
      after
        if original, do: Application.put_env(:hive, :anthropic_api_key, original)
      end
    end

    test "truncates long payloads in fallback" do
      original = Application.get_env(:hive, :anthropic_api_key)

      try do
        Application.put_env(:hive, :anthropic_api_key, nil)
        long_payload = String.duplicate("x", 1000)
        assert {:ok, result} = Formatter.format("src", long_payload)
        # Prefix "[src] " is 6 chars, truncated to 500 + "..."
        assert String.starts_with?(result, "[src] ")
        assert String.ends_with?(result, "...")
        # The payload portion should be at most 503 chars (500 + "...")
        payload_part = String.replace_prefix(result, "[src] ", "")
        assert byte_size(payload_part) <= 503
      after
        if original, do: Application.put_env(:hive, :anthropic_api_key, original)
      end
    end

    test "returns {:ok, string} format" do
      original = Application.get_env(:hive, :anthropic_api_key)

      try do
        Application.put_env(:hive, :anthropic_api_key, nil)
        assert {:ok, result} = Formatter.format("my-source", "payload")
        assert is_binary(result)
      after
        if original, do: Application.put_env(:hive, :anthropic_api_key, original)
      end
    end
  end
end
