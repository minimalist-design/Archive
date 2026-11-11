defmodule Archive.LibrariesTest do
  use Archive.DataCase, async: false

  import Archive.Fixtures
  alias Archive.{Libraries, Paths, Repo, Videos}

  setup do
    clean_dirs!()
    :ok
  end

  test "create_library/1 makes a unique slug and a folder" do
    {:ok, a} = Libraries.create_library(%{name: "Música Clásica!"})
    {:ok, b} = Libraries.create_library(%{name: "musica clasica"})

    assert a.slug == "musica-clasica"
    assert b.slug == "musica-clasica-2"
    assert File.dir?(Paths.library_dir(a))
  end

  test "create_library/1 validates the source URL" do
    assert {:error, changeset} = Libraries.create_library(%{name: "X", source_url: "ftp://nope"})
    assert errors_on(changeset).source_url != []
  end

  test "renaming a library renames its folder and rewrites stored paths" do
    library = library_fixture(%{name: "Old Name"})
    File.mkdir_p!(Path.join(Paths.library_dir(library), "a"))
    sub = Path.join([library.slug, "a", "a.en.vtt"])
    File.write!(Paths.absolute(sub), "WEBVTT\n")

    video =
      video_fixture(library, %{base: "a", thumbnail_path: "old-name/a/a.jpg"},
        with_file: true,
        subtitles: [%{lang: "en", auto: false, path: sub}]
      )

    assert {:ok, renamed} = Libraries.update_library(library, %{name: "New Name"})
    assert renamed.slug == "new-name"
    refute File.exists?(Path.join(Paths.storage_dir(), "old-name"))

    video = Videos.get_video!(video.id)
    assert video.file_path == "new-name/a/a.mp4"
    assert video.thumbnail_path == "new-name/a/a.jpg"
    assert [%{path: "new-name/a/a.en.vtt"}] = video.subtitles
    assert File.exists?(Paths.absolute(video.file_path))
  end

  test "delete_library/2 can keep or remove the folder" do
    keep = library_fixture()
    video_fixture(keep, %{}, with_file: true)
    remove = library_fixture()
    video_fixture(remove, %{}, with_file: true)

    {:ok, _} = Libraries.delete_library(keep)
    {:ok, _} = Libraries.delete_library(remove, delete_files: true)

    assert File.dir?(Paths.library_dir(keep))
    refute File.exists?(Paths.library_dir(remove))
    assert Repo.aggregate(Archive.Videos.Video, :count) == 0
  end

  test "categories can be created, renamed, reordered and deleted" do
    library = library_fixture()
    a = category_fixture(library, "A")
    b = category_fixture(library, "B")
    c = category_fixture(library, "C")

    assert {:error, _} = Libraries.create_category(library, %{name: "A"})

    Libraries.move_category(c, -1)
    assert Enum.map(Libraries.list_categories(library), & &1.name) == ["A", "C", "B"]

    {:ok, _} = Libraries.rename_category(a, "Z")
    {:ok, _} = Libraries.delete_category(b)
    assert Enum.map(Libraries.list_categories(library), & &1.name) == ["Z", "C"]
  end

  test "list_libraries/0 includes video counts" do
    library = library_fixture(%{name: "Counted"})
    video_fixture(library)
    video_fixture(library)
    library_fixture(%{name: "Empty"})

    counts = Map.new(Libraries.list_libraries(), &{&1.name, &1.video_count})
    assert counts == %{"Counted" => 2, "Empty" => 0}
  end
end
