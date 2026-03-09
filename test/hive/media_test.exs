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

  describe "save/2" do
    test "saves a PNG image and returns a URL" do
      assert {:ok, "/uploads/" <> filename} = Hive.Media.save(@tiny_png, "image/png")
      assert String.ends_with?(filename, ".png")

      # Verify the file exists on disk
      path = Path.join(Hive.Media.upload_dir(), filename)
      assert File.exists?(path)
      assert File.read!(path) == @tiny_png

      # Cleanup
      File.rm(path)
    end

    test "saves JPEG images" do
      # Not a valid JPEG, but we're testing the save logic
      data = <<0xFF, 0xD8, 0xFF, 0xE0>> <> :crypto.strong_rand_bytes(100)
      assert {:ok, "/uploads/" <> filename} = Hive.Media.save(data, "image/jpeg")
      assert String.ends_with?(filename, ".jpg")
      File.rm(Path.join(Hive.Media.upload_dir(), filename))
    end

    test "saves GIF images" do
      data = "GIF89a" <> :crypto.strong_rand_bytes(100)
      assert {:ok, "/uploads/" <> filename} = Hive.Media.save(data, "image/gif")
      assert String.ends_with?(filename, ".gif")
      File.rm(Path.join(Hive.Media.upload_dir(), filename))
    end

    test "saves WebP images" do
      data = "RIFF" <> :crypto.strong_rand_bytes(100)
      assert {:ok, "/uploads/" <> filename} = Hive.Media.save(data, "image/webp")
      assert String.ends_with?(filename, ".webp")
      File.rm(Path.join(Hive.Media.upload_dir(), filename))
    end

    test "rejects unsupported media types" do
      assert {:error, msg} = Hive.Media.save("data", "text/plain")
      assert msg =~ "unsupported media type"
    end

    test "rejects application/pdf" do
      assert {:error, _} = Hive.Media.save("data", "application/pdf")
    end

    test "rejects files over 5MB" do
      big_data = :crypto.strong_rand_bytes(5_000_001)
      assert {:error, msg} = Hive.Media.save(big_data, "image/png")
      assert msg =~ "too large"
    end

    test "accepts files exactly at 5MB" do
      data = :crypto.strong_rand_bytes(5_000_000)
      assert {:ok, "/uploads/" <> filename} = Hive.Media.save(data, "image/png")
      File.rm(Path.join(Hive.Media.upload_dir(), filename))
    end

    test "generates unique filenames" do
      {:ok, url1} = Hive.Media.save(@tiny_png, "image/png")
      {:ok, url2} = Hive.Media.save(@tiny_png, "image/png")
      assert url1 != url2

      # Cleanup
      for url <- [url1, url2] do
        "/uploads/" <> filename = url
        File.rm(Path.join(Hive.Media.upload_dir(), filename))
      end
    end
  end

  describe "ensure_upload_dir/0" do
    test "creates the upload directory" do
      Hive.Media.ensure_upload_dir()
      assert File.dir?(Hive.Media.upload_dir())
    end
  end
end
