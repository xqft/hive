defmodule Hive.Validation do
  @name_regex ~r/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,30}$/

  def validate_name(name) do
    if Regex.match?(@name_regex, name), do: :ok, else: {:error, :invalid_name}
  end
end
