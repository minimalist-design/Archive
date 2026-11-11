defmodule Archive.VideosTest do
  use Archive.DataCase, async: false

  import Archive.Fixtures
  alias Archive.{Paths, Repo, Videos}
  alias Archive.Videos.Video

  setup do
    clean_dirs!()
    :ok
  end

  defp all_pages(library_id, opts, acc \\ [], last \\ nil) do
    page = Videos.list_library_videos(library_id, Keyword.merge(opts, after: last, limit: 3))

    case page do
      [] -> acc
      page -> all_pages(library_id, opts, acc ++ page, List.last(page))
    end
  end

  describe "list_library_videos/2 (keyset pagination)" do
    setup do
      library = library_fixture()

      videos =
        for {title, duration, date} <- [
              {"banana", 30, ~D[2020-01-01]},
              {"Apple", 30, nil},
              {"cherry", 10, ~D[2021-05-05]},
              {"apple", nil, ~D[2019-01-01]},
              {"date", 50, ~D[2021-05-05]},
              {"elder", 20, nil},
              {"fig", 30, ~D[2018-01-01]}
            ] do
          video_fixture(library, %{title: title, duration: duration, upload_date: date})
        end

      %{library: library, videos: videos}
    end

    test "every sort returns each video exactly once across pages", %{
      library: library,
      videos: videos
    } do
      for sort <- Videos.sorts() do
        ids = library.id |> all_pages(sort: sort) |> Enum.map(& &1.id)
        assert length(ids) == length(videos), "sort #{sort} returned #{length(ids)}"
        assert Enum.sort(ids) == Enum.sort(Enum.map(videos, & &1.id)), "sort #{sort}"
      end
    end

    test "sorts by title case-insensitively", %{library: library} do
      titles = library.id |> all_pages(sort: "title_asc") |> Enum.map(&String.downcase(&1.title))
      assert titles == Enum.sort(titles)
    end

    test "sorts by duration with missing durations last when descending", %{library: library} do
      durations = library.id |> all_pages(sort: "duration_desc") |> Enum.map(& &1.duration)
      assert durations == [50, 30, 30, 30, 20, 10, nil]
    end

    test "filters by category", %{library: library, videos: [a, b | _]} do
      category = category_fixture(library, "Fruit")
      {:ok, 2} = Videos.bulk_categorize([a.id, b.id], category.id, :add)

      ids = library.id |> all_pages(category_id: category.id) |> Enum.map(& &1.id)
      assert Enum.sort(ids) == Enum.sort([a.id, b.id])

      {:ok, 1} = Videos.bulk_categorize([a.id], category.id, :remove)
      assert [%{id: id}] = all_pages(library.id, category_id: category.id)
      assert id == b.id
    end

    test "filters by search query within the library", %{library: library} do
      assert [%{title: "cherry"}] = all_pages(library.id, query: "cher")
    end
  end

  test "a video can be in several categories of its library only" do
    library = library_fixture()
    other = library_fixture()
    c1 = category_fixture(library, "One")
    c2 = category_fixture(library, "Two")
    foreign = category_fixture(other, "Foreign")
    video = video_fixture(library)

    {:ok, _} = Videos.set_categories(video, [c1.id, c2.id, foreign.id])
    names = Videos.get_video!(video.id).categories |> Enum.map(& &1.name)
    assert names == ["One", "Two"]
  end

  test "the same remote video can't be archived twice" do
    library = library_fixture()
    video_fixture(library, %{remote_id: "dup", extractor_key: "Youtube"})

    assert {:error, changeset} =
             Videos.create_video(library_fixture(), %{
               extractor_key: "Youtube",
               remote_id: "dup",
               title: "again",
               file_path: "x/y.mp4"
             })

    assert "is already archived" in errors_on(changeset).extractor_key
  end

  test "move_to_library/2 moves the video folder and clears categories" do
    source = library_fixture(%{name: "Source"})
    target = library_fixture(%{name: "Target"})
    category = category_fixture(source, "C")

    File.mkdir_p!(Path.join(Paths.library_dir(source), "Clip [x1]"))
    sub_rel = "source/Clip [x1]/Clip [x1].en.vtt"
    File.write!(Paths.absolute(sub_rel), "WEBVTT\n")
    File.write!(Paths.absolute("source/Clip [x1]/notes.txt"), "extra file")

    video =
      video_fixture(source, %{base: "Clip [x1]"},
        with_file: true,
        category_ids: [category.id],
        subtitles: [%{lang: "en", auto: false, path: sub_rel}]
      )

    assert {:ok, moved} = Videos.move_to_library(video, target)
    assert moved.library_id == target.id
    assert moved.file_path == "target/Clip [x1]/Clip [x1].mp4"
    assert moved.categories == []
    assert File.exists?(Paths.absolute(moved.file_path))
    assert [%{path: "target/Clip [x1]/Clip [x1].en.vtt"}] = moved.subtitles
    assert File.exists?(Paths.absolute("target/Clip [x1]/Clip [x1].en.vtt"))
    assert File.exists?(Paths.absolute("target/Clip [x1]/notes.txt"))
    refute File.exists?(Paths.absolute("source/Clip [x1]"))
  end

  test "move_to_library/2 avoids folder name clashes and handles legacy flat videos" do
    source = library_fixture(%{name: "Src"})
    target = library_fixture(%{name: "Dst"})
    File.mkdir_p!(Paths.absolute("dst/Same"))

    video = video_fixture(source, %{base: "Same"}, with_file: true, flat: true)

    assert {:ok, moved} = Videos.move_to_library(video, target)
    assert moved.file_path == "dst/Same (2)/Same.mp4"
    assert File.exists?(Paths.absolute(moved.file_path))
  end

  test "delete_video/2 keeps or removes the video folder" do
    library = library_fixture()
    keep = video_fixture(library, %{}, with_file: true)
    remove = video_fixture(library, %{}, with_file: true)
    File.write!(Path.join(Archive.Layout.video_dir(remove), "extra.txt"), "x")

    {:ok, _} = Videos.delete_video(keep)
    {:ok, _} = Videos.delete_video(remove, delete_files: true)

    assert File.exists?(Paths.absolute(keep.file_path))
    refute File.exists?(Archive.Layout.video_dir(remove))
    assert File.dir?(Paths.library_dir(library))
    assert Repo.aggregate(Video, :count) == 0
    assert Archive.Search.search("Video") == []
  end

  test "delete_video/2 removes only known files of a legacy flat video" do
    library = library_fixture()
    video = video_fixture(library, %{}, with_file: true, flat: true)
    other = Path.join(Paths.library_dir(library), "unrelated.txt")
    File.write!(other, "x")

    {:ok, _} = Videos.delete_video(video, delete_files: true)
    refute File.exists?(Paths.absolute(video.file_path))
    assert File.exists?(other)
  end

  test "verify_files/0 flags missing files" do
    library = library_fixture()
    present = video_fixture(library, %{}, with_file: true)
    missing = video_fixture(library)

    assert Videos.verify_files() == 1
    assert Repo.get!(Video, missing.id).status == "missing"
    assert Repo.get!(Video, present.id).status == "ready"
  end
end
