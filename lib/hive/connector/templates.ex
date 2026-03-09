defmodule Hive.Connector.Templates do
  def list do
    case File.ls(templates_dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(fn f -> load_template(Path.join(templates_dir(), f)) end)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  def get(slug) do
    path = Path.join(templates_dir(), "#{slug}.json")
    load_template(path)
  end

  def apply_config(template, user_config) do
    mcp_attrs =
      if template["mcp"] do
        mcp = template["mcp"]
        env = resolve_placeholders(mcp["env"] || %{}, user_config)

        %{
          command: mcp["command"],
          args: mcp["args"] || [],
          env: env,
          description: template["description"]
        }
      end

    event_attrs =
      if template["event"] do
        ev = template["event"]

        %{
          type: ev["type"],
          topic: user_config["topic"] || ev["default_topic"],
          config: resolve_placeholders(ev["config"] || %{}, user_config)
        }
      end

    %{mcp: mcp_attrs, event: event_attrs}
  end

  defp templates_dir do
    Application.app_dir(:hive, "priv/connector_templates")
  end

  defp load_template(path) do
    case File.read(path) do
      {:ok, content} -> Jason.decode!(content)
      {:error, _} -> nil
    end
  end

  defp resolve_placeholders(map, config) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, resolve_value(v, config)} end)
  end

  defp resolve_value("{{" <> _ = tmpl, config) do
    key = tmpl |> String.trim_leading("{{") |> String.trim_trailing("}}")
    Map.get(config, key, tmpl)
  end

  defp resolve_value(v, _), do: v
end
