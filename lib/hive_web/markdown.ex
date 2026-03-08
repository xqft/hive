defmodule HiveWeb.Markdown do
  @moduledoc false

  @spec render(String.t() | nil) :: Phoenix.HTML.safe()
  def render(nil), do: ""

  def render(markdown) when is_binary(markdown) do
    markdown
    |> Earmark.as_html!(%Earmark.Options{breaks: true, code_class_prefix: "language-"})
    |> HtmlSanitizeEx.basic_html()
    |> Phoenix.HTML.raw()
  rescue
    _ -> Phoenix.HTML.html_escape(markdown)
  end
end
