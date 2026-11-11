defmodule Archive.LayoutTest do
  use Archive.DataCase, async: false

  import Archive.Fixtures
  alias Archive.{Layout, Paths, Videos}

  setup do
    clean_dirs!()
    %{library: library_fixture(%{name: "Lib"})}
  end

  defp flat_video_with_sidecars(library, base) do
    File.mkdir_p!(Paths.library_dir(library))
    File.cp!(fixture_path("sample.jpg"), Paths.absolute("lib/#{base}.jpg"))
    File.write!(Paths.absolute("lib/#{base}.info.json"), "{}")
    File.write!(Paths.absolute("lib/#{base}.en.vtt"), "WEBVTT\n")

    video_fixture(
      library,
      %{
        base: base,
        thumbnail_path: "lib/#{base}.jpg",
        info_json_path: "lib/#{base}.info.json"
      },
      with_file: true,
      flat: true,
      subtitles: [%{lang: "en", auto: false, path: "lib/#{base}.en.vtt"}]
    )
  end

  test "migrate_flat/0 moves flat videos and their sidecars into their own folder", %{
    library: library
  } do
    video = flat_video_with_sidecars(library, "Song [abc]")
    unrelated = Path.join(Paths.library_dir(library), "keep-me.txt")
    File.write!(unrelated, "x")

    assert Layout.migrate_flat() == {1, 0}

    video = Videos.get_video!(video.id)
    assert video.file_path == "lib/Song [abc]/Song [abc].mp4"
    assert video.thumbnail_path == "lib/Song [abc]/Song [abc].jpg"
    assert video.info_json_path == "lib/Song [abc]/Song [abc].info.json"
    assert [%{path: "lib/Song [abc]/Song [abc].en.vtt"}] = video.subtitles

    for rel <- Layout.relative_files(video), do: assert(File.exists?(Paths.absolute(rel)))
    refute File.exists?(Paths.absolute("lib/Song [abc].mp4"))
    assert File.exists?(unrelated)

    # Running again changes nothing.
    assert Layout.migrate_flat() == {0, 0}
    assert Videos.get_video!(video.id).file_path == "lib/Song [abc]/Song [abc].mp4"
  end

  test "migrate_flat/0 picks a unique folder name", %{library: library} do
    File.mkdir_p!(Paths.absolute("lib/Clip"))
    video = video_fixture(library, %{base: "Clip"}, with_file: true, flat: true)

    assert Layout.migrate_flat() == {1, 0}
    assert Videos.get_video!(video.id).file_path == "lib/Clip (2)/Clip.mp4"
  end

  test "migrate_flat/0 leaves videos already in a folder untouched", %{library: library} do
    video = video_fixture(library, %{base: "Done"}, with_file: true)

    assert Layout.migrate_flat() == {0, 0}
    assert Videos.get_video!(video.id).file_path == "lib/Done/Done.mp4"
  end

  test "migrate_flat/0 reports videos whose file is missing", %{library: library} do
    video = video_fixture(library, %{base: "Gone"}, flat: true)

    assert Layout.migrate_flat() == {0, 1}
    assert Videos.get_video!(video.id).file_path == "lib/Gone.mp4"
    refute File.exists?(Paths.absolute("lib/Gone"))
  end
end
