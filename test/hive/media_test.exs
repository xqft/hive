defmodule Hive.MediaTest do
  use ExUnit.Case, async: true

  @tiny_png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0,
              1, 8, 2, 0, 0, 0, 144, 119, 83, 222, 0, 0, 0, 12, 73, 68, 65, 84, 8, 215, 99, 248,
              207, 192, 0, 0, 0, 2, 0, 1, 226, 33, 188, 51, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66,
              96, 130>>

  setup do
    # Use a temp directory for uploads during tests
    tmp_dir =
      Path.join(System.tmp_dir!(), "hive_media_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    # Override the upload dir for this test by saving files there directly
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir}
  end

  defp cleanup(url) do
    "/uploads/" <> filename = url
    File.rm(Path.join(Hive.Media.upload_dir(), filename))
  end

  describe "save/2 — image types" do
    test "saves a PNG image and returns a URL" do
      assert {:ok, "/uploads/" <> filename} = Hive.Media.save(@tiny_png, "image/png")
      assert String.ends_with?(filename, ".png")

      # Verify the file exists on disk
      path = Path.join(Hive.Media.upload_dir(), filename)
      assert File.exists?(path)
      assert File.read!(path) == @tiny_png

      cleanup("/uploads/" <> filename)
    end

    test "saves JPEG images" do
      data = <<0xFF, 0xD8, 0xFF, 0xE0>> <> :crypto.strong_rand_bytes(100)
      assert {:ok, "/uploads/" <> filename} = Hive.Media.save(data, "image/jpeg")
      assert String.ends_with?(filename, ".jpg")
      cleanup("/uploads/" <> filename)
    end

    test "saves GIF images" do
      data = "GIF89a" <> :crypto.strong_rand_bytes(100)
      assert {:ok, "/uploads/" <> filename} = Hive.Media.save(data, "image/gif")
      assert String.ends_with?(filename, ".gif")
      cleanup("/uploads/" <> filename)
    end

    test "saves WebP images" do
      data = "RIFF" <> :crypto.strong_rand_bytes(100)
      assert {:ok, "/uploads/" <> filename} = Hive.Media.save(data, "image/webp")
      assert String.ends_with?(filename, ".webp")
      cleanup("/uploads/" <> filename)
    end
  end

  describe "save/2 — document and file types" do
    test "saves PDF files" do
      data = "%PDF-1.4" <> :crypto.strong_rand_bytes(100)
      assert {:ok, "/uploads/" <> filename} = Hive.Media.save(data, "application/pdf")
      assert String.ends_with?(filename, ".pdf")
      cleanup("/uploads/" <> filename)
    end

    test "saves plain text files" do
      data = "Hello, world!"
      assert {:ok, "/uploads/" <> filename} = Hive.Media.save(data, "text/plain")
      assert String.ends_with?(filename, ".txt")
      cleanup("/uploads/" <> filename)
    end

    test "saves CSV files" do
      data = "name,age\nAlice,30\nBob,25"
      assert {:ok, "/uploads/" <> filename} = Hive.Media.save(data, "text/csv")
      assert String.ends_with?(filename, ".csv")
      cleanup("/uploads/" <> filename)
    end

    test "saves JSON files" do
      data = ~s({"key": "value"})
      assert {:ok, "/uploads/" <> filename} = Hive.Media.save(data, "application/json")
      assert String.ends_with?(filename, ".json")
      cleanup("/uploads/" <> filename)
    end

    test "saves ZIP archives" do
      data = "PK" <> :crypto.strong_rand_bytes(100)
      assert {:ok, "/uploads/" <> filename} = Hive.Media.save(data, "application/zip")
      assert String.ends_with?(filename, ".zip")
      cleanup("/uploads/" <> filename)
    end

    test "saves markdown files" do
      data = "# Hello\n\nThis is **markdown**."
      assert {:ok, "/uploads/" <> filename} = Hive.Media.save(data, "text/markdown")
      assert String.ends_with?(filename, ".md")
      cleanup("/uploads/" <> filename)
    end

    test "saves application/octet-stream as .bin" do
      data = :crypto.strong_rand_bytes(100)
      assert {:ok, "/uploads/" <> filename} = Hive.Media.save(data, "application/octet-stream")
      assert String.ends_with?(filename, ".bin")
      cleanup("/uploads/" <> filename)
    end
  end

  describe "save/3 — with filename option" do
    test "uses the provided filename's extension for octet-stream" do
      data = :crypto.strong_rand_bytes(100)

      assert {:ok, "/uploads/" <> filename} =
               Hive.Media.save(data, "application/octet-stream", filename: "report.xlsx")

      # octet-stream maps to "bin" via ext_map, filename not used for extension in this case
      # because ext_map has a mapping for octet-stream
      assert String.ends_with?(filename, ".bin")
      cleanup("/uploads/" <> filename)
    end
  end

  describe "save/2 — any file type" do
    test "accepts files with unknown MIME types" do
      data = "some binary data"
      assert {:ok, "/uploads/" <> filename} = Hive.Media.save(data, "application/x-executable")
      assert String.ends_with?(filename, ".bin")
      cleanup("/uploads/" <> filename)
    end

    test "accepts completely custom MIME types" do
      data = "custom format data"
      assert {:ok, "/uploads/" <> filename} = Hive.Media.save(data, "application/x-custom-format")
      assert String.ends_with?(filename, ".bin")
      cleanup("/uploads/" <> filename)
    end

    test "uses filename extension for unknown MIME types" do
      data = "print('hello')"

      assert {:ok, "/uploads/" <> filename} =
               Hive.Media.save(data, "text/x-python", filename: "script.py")

      assert String.ends_with?(filename, ".py")
      cleanup("/uploads/" <> filename)
    end
  end

  describe "save/2 — size limits" do
    test "rejects files over 10MB" do
      big_data = :crypto.strong_rand_bytes(10_000_001)
      assert {:error, msg} = Hive.Media.save(big_data, "image/png")
      assert msg =~ "too large"
    end

    test "accepts files exactly at 10MB" do
      data = :crypto.strong_rand_bytes(10_000_000)
      assert {:ok, "/uploads/" <> filename} = Hive.Media.save(data, "image/png")
      cleanup("/uploads/" <> filename)
    end
  end

  describe "image_type?/1" do
    test "returns true for image types" do
      assert Hive.Media.image_type?("image/png")
      assert Hive.Media.image_type?("image/jpeg")
      assert Hive.Media.image_type?("image/gif")
      assert Hive.Media.image_type?("image/webp")
      assert Hive.Media.image_type?("image/svg+xml")
    end

    test "returns false for non-image types" do
      refute Hive.Media.image_type?("application/pdf")
      refute Hive.Media.image_type?("text/plain")
      refute Hive.Media.image_type?("application/zip")
    end
  end

  describe "ext_for/2" do
    test "returns correct extensions for known MIME types" do
      assert Hive.Media.ext_for("image/png") == "png"
      assert Hive.Media.ext_for("image/jpeg") == "jpg"
      assert Hive.Media.ext_for("application/pdf") == "pdf"
      assert Hive.Media.ext_for("text/plain") == "txt"
      assert Hive.Media.ext_for("application/zip") == "zip"
    end

    test "falls back to filename extension for unknown MIME types" do
      assert Hive.Media.ext_for("application/x-unknown", "report.xlsx") == "xlsx"
      assert Hive.Media.ext_for("application/x-unknown", "data.parquet") == "parquet"
    end

    test "returns bin when no mapping and no filename" do
      assert Hive.Media.ext_for("application/x-unknown") == "bin"
      assert Hive.Media.ext_for("application/x-unknown", nil) == "bin"
    end
  end

  describe "ensure_upload_dir/0" do
    test "creates the upload directory" do
      Hive.Media.ensure_upload_dir()
      assert File.dir?(Hive.Media.upload_dir())
    end
  end

  describe "unique filenames" do
    test "generates unique filenames for identical content" do
      {:ok, url1} = Hive.Media.save(@tiny_png, "image/png")
      {:ok, url2} = Hive.Media.save(@tiny_png, "image/png")
      assert url1 != url2

      cleanup(url1)
      cleanup(url2)
    end
  end
end
