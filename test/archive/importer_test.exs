defmodule Archive.ImporterTest do
  use Archive.DataCase, async: false

  import Archive.Fixtures
  alias Archive.{Importer, Paths, Videos}

  setup do
    clean_dirs!()
    src = Path.join(Paths.data_dir(), "import-src-#{System.unique_integer([:positive])}")
    File.mkdir_p!(src)
    %{src: src}
  end

  describe "detect_youtube_id/1" do
    test "finds ids in common filename patterns" do
      assert Importer.detect_youtube_id("Some Title [dQw4w9WgXcQ].mp4") == "dQw4w9WgXcQ"
      assert Importer.detect_youtube_id("Some Title-dQw4w9WgXcQ.mkv") == "dQw4w9WgXcQ"
      assert Importer.detect_youtube_id("dQw4w9WgXcQ.webm") == "dQw4w9WgXcQ"
      assert Importer.detect_youtube_id("clip (GM_3IlttE-I).mp4") == "GM_3IlttE-I"
    end

    test "ignores ordinary words" do
      assert Importer.detect_youtube_id("holiday-video-final.mp4") == nil
      assert Importer.detect_youtube_id("Masterpiece.mp4") == nil
      assert Importer.detect_youtube_id("my favourite.mp4") == nil
      assert Importer.detect_youtube_id("20240101123.mp4") == nil
    end
  end

  describe "clean_title/2" do
    test "removes ids, technical tags and separators" do
      assert Importer.clean_title("My_Test.Clip [1080p] (x265).mkv") == "My Test Clip"
      assert Importer.clean_title("Some Title [dQw4w9WgXcQ].mp4") == "Some Title"

      assert Importer.clean_title("Great.Movie.Trailer.2020.WEBRip.mp4") ==
               "Great Movie Trailer 2020 WEBRip"

      assert Importer.clean_title("Song (Official Video).mp4") == "Song (Official Video)"
      assert Importer.clean_title("Mr. Smith goes.mp4") == "Mr. Smith goes"
    end

    test "can keep the id token" do
      assert Importer.clean_title("trip dQw4w9WgXcQ.mp4", strip_id: false) == "trip dQw4w9WgXcQ"
    end
  end

  test "scan/1 lists video files with what was detected", %{src: src} do
    File.cp!(fixture_path("sample.mp4"), Path.join(src, "Plain name.mp4"))
    File.mkdir_p!(Path.join(src, "nested"))
    File.cp!(fixture_path("sample.mp4"), Path.join(src, "nested/x [dQw4w9WgXcQ].mp4"))
    File.write!(Path.join(src, "notes.txt"), "ignore me")

    assert {:ok, entries} = Importer.scan(src)
    assert length(entries) == 2
    sources = Map.new(entries, &{&1.name, &1.source})
    assert sources == %{"Plain name.mp4" => :filename, "x [dQw4w9WgXcQ].mp4" => :youtube_id}

    assert {:error, _} = Importer.scan(Path.join(src, "missing"))
  end

  test "imports a plain file: moves it, converts srt subtitles, cleans the title", %{src: src} do
    library = library_fixture(%{name: "Imported"})
    file = Path.join(src, "family_trip.mp4")
    File.cp!(fixture_path("sample.mp4"), file)

    File.write!(
      Path.join(src, "family_trip.en.srt"),
      "1\n00:00:01,000 --> 00:00:02,000\nHello walrus\n"
    )

    assert {:ok, video, nil} = Importer.import_file(file, library)
    refute File.exists?(file)
    assert video.title == "family trip"
    assert video.extractor_key == "local"
    assert video.file_path == "imported/family trip/family trip.mp4"
    assert video.duration == 3
    assert video.vcodec == "h264"

    video = Videos.get_video!(video.id)
    assert [%{lang: "en", path: "imported/family trip/family trip.en.vtt"}] = video.subtitles

    assert File.read!(Paths.absolute("imported/family trip/family trip.en.vtt")) =~
             "00:00:01.000 --> 00:00:02.000"

    assert [_] = Archive.Search.search("walrus")
    assert File.exists?(Paths.grid_thumb(video.id))
  end

  test "imports with an info.json sidecar and skips duplicates", %{src: src} do
    library = library_fixture(%{name: "Lib"})
    file = Path.join(src, "whatever.mp4")
    File.cp!(fixture_path("sample.mp4"), file)
    File.cp!(fixture_path("sample.jpg"), Path.join(src, "whatever.jpg"))

    File.write!(
      Path.join(src, "whatever.info.json"),
      Jason.encode!(%{
        "id" => "abc123",
        "title" => "From Vimeo",
        "extractor_key" => "Vimeo",
        "uploader" => "Someone",
        "upload_date" => "20230405"
      })
    )

    assert {:ok, video, nil} = Importer.import_file(file, library)
    assert video.title == "From Vimeo"
    assert video.extractor_key == "Vimeo"
    assert video.upload_date == ~D[2023-04-05]
    assert video.file_path == "lib/From Vimeo [abc123]/From Vimeo [abc123].mp4"
    assert video.thumbnail_path == "lib/From Vimeo [abc123]/From Vimeo [abc123].jpg"
    assert video.info_json_path == "lib/From Vimeo [abc123]/From Vimeo [abc123].info.json"

    copy = Path.join(src, "again.mp4")
    File.cp!(fixture_path("sample.mp4"), copy)

    File.write!(
      Path.join(src, "again.info.json"),
      Jason.encode!(%{"id" => "abc123", "extractor_key" => "Vimeo"})
    )

    assert {:skipped, _note, _id} = Importer.import_file(copy, library)
    assert File.exists?(copy)
  end

  test "imports a file with a YouTube id using looked-up metadata", %{src: src} do
    library = library_fixture(%{name: "YT"})
    file = Path.join(src, "old [dQw4w9WgXcQ].mp4")
    File.cp!(fixture_path("sample.mp4"), file)

    assert {:ok, video, nil} = Importer.import_file(file, library)
    assert video.title == "Fake video dQw4w9WgXcQ"
    assert video.remote_id == "dQw4w9WgXcQ"

    assert video.file_path ==
             "yt/Fake video dQw4w9WgXcQ [dQw4w9WgXcQ]/Fake video dQw4w9WgXcQ [dQw4w9WgXcQ].mp4"

    assert video.thumbnail_path ==
             "yt/Fake video dQw4w9WgXcQ [dQw4w9WgXcQ]/Fake video dQw4w9WgXcQ [dQw4w9WgXcQ].jpg"

    assert File.exists?(Paths.absolute(video.info_json_path))
    assert [_] = Videos.get_video!(video.id).subtitles
  end
end
