defmodule Hive.Media do
  @moduledoc """
  Saves uploaded media files to disk and returns public URLs.
  Files are stored in `priv/static/uploads/` and served via Plug.Static.
  Supports images and general file uploads (documents, archives, code, etc.).
  """

  @upload_dir Path.join([:code.priv_dir(:hive) |> to_string(), "static", "uploads"])
  @max_size 10_000_000

  @allowed_types ~w(
    image/png image/jpeg image/gif image/webp image/svg+xml
    application/pdf
    application/zip application/gzip application/x-tar
    application/x-7z-compressed application/x-rar-compressed
    application/json application/xml
    application/msword application/vnd.openxmlformats-officedocument.wordprocessingml.document
    application/vnd.ms-excel application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
    application/vnd.ms-powerpoint application/vnd.openxmlformats-officedocument.presentationml.presentation
    text/plain text/csv text/html text/css text/javascript text/markdown text/xml
    audio/mpeg audio/wav audio/ogg
    video/mp4 video/webm
    application/octet-stream
  )

  @image_types ~w(image/png image/jpeg image/gif image/webp image/svg+xml)

  @ext_map %{
    "image/png" => "png",
    "image/jpeg" => "jpg",
    "image/gif" => "gif",
    "image/webp" => "webp",
    "image/svg+xml" => "svg",
    "application/pdf" => "pdf",
    "application/zip" => "zip",
    "application/gzip" => "gz",
    "application/x-tar" => "tar",
    "application/x-7z-compressed" => "7z",
    "application/x-rar-compressed" => "rar",
    "application/json" => "json",
    "application/xml" => "xml",
    "application/msword" => "doc",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => "docx",
    "application/vnd.ms-excel" => "xls",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => "xlsx",
    "application/vnd.ms-powerpoint" => "ppt",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation" => "pptx",
    "text/plain" => "txt",
    "text/csv" => "csv",
    "text/html" => "html",
    "text/css" => "css",
    "text/javascript" => "js",
    "text/markdown" => "md",
    "text/xml" => "xml",
    "audio/mpeg" => "mp3",
    "audio/wav" => "wav",
    "audio/ogg" => "ogg",
    "video/mp4" => "mp4",
    "video/webm" => "webm",
    "application/octet-stream" => "bin"
  }

  def upload_dir, do: @upload_dir

  def ensure_upload_dir, do: File.mkdir_p!(@upload_dir)

  def max_size, do: @max_size

  def allowed_types, do: @allowed_types

  def image_type?(media_type), do: media_type in @image_types

  @doc """
  Saves file data to disk. Returns `{:ok, url}` or `{:error, reason}`.
  Optionally accepts an original filename to preserve the extension.
  """
  def save(data, media_type, opts \\ [])

  def save(data, media_type, opts) when is_binary(data) and is_binary(media_type) do
    if byte_size(data) > @max_size do
      {:error, "file too large (max #{div(@max_size, 1_000_000)}MB)"}
    else
      id = Base.hex_encode32(:crypto.strong_rand_bytes(10), case: :lower, padding: false)
      ext = ext_for(media_type, opts[:filename])
      filename = "#{id}.#{ext}"
      path = Path.join(@upload_dir, filename)
      ensure_upload_dir()
      File.write!(path, data)
      {:ok, "/uploads/#{filename}"}
    end
  end

  @doc """
  Returns the file extension for a MIME type.
  Falls back to extracting from the original filename if provided.
  """
  def ext_for(media_type, filename \\ nil) do
    case Map.get(@ext_map, media_type) do
      nil ->
        # Fallback: try to extract from original filename, or use "bin"
        if filename do
          case Path.extname(filename) do
            "." <> ext -> ext
            _ -> "bin"
          end
        else
          "bin"
        end

      ext ->
        ext
    end
  end
end
