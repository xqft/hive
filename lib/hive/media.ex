defmodule Hive.Media do
  @moduledoc """
  Saves uploaded media files to disk and returns public URLs.
  Files are stored in `priv/static/uploads/` and served via Plug.Static.
  """

  @upload_dir Path.join([:code.priv_dir(:hive) |> to_string(), "static", "uploads"])
  @max_size 5_000_000
  @allowed_types ~w(image/png image/jpeg image/gif image/webp)

  def upload_dir, do: @upload_dir

  def ensure_upload_dir, do: File.mkdir_p!(@upload_dir)

  def save(data, media_type) when media_type in @allowed_types do
    if byte_size(data) > @max_size do
      {:error, "file too large (max 5MB)"}
    else
      id = Base.hex_encode32(:crypto.strong_rand_bytes(10), case: :lower, padding: false)
      ext = ext_for(media_type)
      filename = "#{id}.#{ext}"
      path = Path.join(@upload_dir, filename)
      File.write!(path, data)
      {:ok, "/uploads/#{filename}"}
    end
  end

  def save(_data, _media_type) do
    {:error, "unsupported media type (allowed: png, jpeg, gif, webp)"}
  end

  defp ext_for("image/png"), do: "png"
  defp ext_for("image/jpeg"), do: "jpg"
  defp ext_for("image/gif"), do: "gif"
  defp ext_for("image/webp"), do: "webp"
end
