defmodule ArchiveWeb.PagesTest do
  use ArchiveWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Archive.Fixtures
  alias Archive.{Libraries, Repo, Videos}

  setup do
    clean_dirs!()
    :ok
  end

  describe "home" do
    test "shows an empty state without videos", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#shelves")
      assert render(view) =~ "Your archive is empty"
    end

    test "shows a shelf per library and live search results", %{conn: conn} do
      music = library_fixture(%{name: "Music"})
      talks = library_fixture(%{name: "Talks"})
      song = video_fixture(music, %{title: "Great song"})
      talk = video_fixture(talks, %{title: "Great talk"})

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#shelf-#{music.id}")
      assert has_element?(view, "#shelf-#{talks.id}")
      assert has_element?(view, "#nav-library-#{music.id}")

      view |> element("#global-search") |> render_change(%{"q" => "talk"})
      assert_patch(view, ~p"/?q=talk")
      assert has_element?(view, "#result-#{talk.id}")
      refute has_element?(view, "#result-#{song.id}")
    end

    test "the Add dialog queues a URL into a new library", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#open-add-video") |> render_click()
      assert has_element?(view, "#add-video-form")

      view
      |> form("#add-video-form",
        add: %{url: "https://example.com/watch?v=1", library_id: "new", new_library: "Fresh"}
      )
      |> render_submit()

      assert [%{name: "Fresh"} = library] = Libraries.list_libraries()

      assert [%{url: "https://example.com/watch?v=1", library_id: id}] =
               Repo.all(Archive.Downloads.Download)

      assert id == library.id
    end
  end

  describe "library page" do
    setup do
      library = library_fixture(%{name: "Big"})
      videos = for i <- 1..60, do: video_fixture(library, %{title: "Clip #{i}"})
      %{library: library, videos: videos}
    end

    test "loads more videos on scroll (infinite scrolling)", %{
      conn: conn,
      library: library,
      videos: videos
    } do
      {:ok, view, _html} = live(conn, ~p"/libraries/#{library.slug}")
      newest = List.last(videos)
      oldest = hd(videos)

      assert has_element?(view, "#videos-#{newest.id}")
      refute has_element?(view, "#videos-#{oldest.id}")

      render_hook(view, "load_more", %{})
      assert has_element?(view, "#videos-#{oldest.id}")
    end

    test "filters by category chips", %{conn: conn, library: library, videos: [a, b | _]} do
      category = category_fixture(library, "Picked")
      Videos.bulk_categorize([a.id], category.id, :add)

      {:ok, view, _html} = live(conn, ~p"/libraries/#{library.slug}")
      view |> element("#chip-#{category.id}") |> render_click()
      assert_patch(view, ~p"/libraries/#{library.slug}?category=#{category.id}")

      assert has_element?(view, "#videos-#{a.id}")
      refute has_element?(view, "#videos-#{b.id}")
    end

    test "bulk-assigns a category to selected videos", %{
      conn: conn,
      library: library,
      videos: videos
    } do
      category = category_fixture(library, "Bulk")
      [v1, v2 | _] = Enum.reverse(videos)

      {:ok, view, _html} = live(conn, ~p"/libraries/#{library.slug}")
      view |> element("#toggle-select-mode") |> render_click()
      render_click(view, "toggle_select", %{"id" => to_string(v1.id)})
      render_click(view, "toggle_select", %{"id" => to_string(v2.id)})
      assert has_element?(view, "#bulk-actions")

      view
      |> form("#bulk-category-form", %{category_id: category.id})
      |> render_submit(%{action: "add"})

      ids = Videos.list_library_videos(library.id, category_id: category.id) |> Enum.map(& &1.id)
      assert Enum.sort(ids) == Enum.sort([v1.id, v2.id])
    end

    test "deleting the library asks whether to delete files", %{conn: conn, library: library} do
      {:ok, view, _html} = live(conn, ~p"/libraries/#{library.slug}")
      view |> element("#delete-library") |> render_click()
      assert has_element?(view, "#delete-library-form input[name=delete_files][type=checkbox]")

      view |> form("#delete-library-form", %{delete_files: "false"}) |> render_submit()
      assert_redirect(view, ~p"/")
      assert Libraries.list_libraries() == []
      assert File.dir?(Archive.Paths.library_dir(library))
    end
  end

  describe "video page" do
    test "shows the player and toggles categories", %{conn: conn} do
      library = library_fixture()
      category = category_fixture(library, "Funny")
      video = video_fixture(library, %{title: "Watch me", description: "Line one"})

      {:ok, view, html} = live(conn, ~p"/videos/#{video.id}")
      assert html =~ "Watch me"
      assert has_element?(view, "#player-#{video.id}[data-mode=direct]")

      view
      |> form("#video-categories", %{category_ids: [to_string(category.id)]})
      |> render_change()

      assert [%{id: id}] = Videos.get_video!(video.id).categories
      assert id == category.id
    end

    test "deletes a video keeping its files", %{conn: conn} do
      library = library_fixture()
      video = video_fixture(library, %{}, with_file: true)

      {:ok, view, _html} = live(conn, ~p"/videos/#{video.id}")
      view |> element("#delete-video") |> render_click()
      view |> form("#delete-video-form", %{delete_files: "false"}) |> render_submit()

      assert_redirect(view, ~p"/libraries/#{library.slug}")
      assert Videos.get_video(video.id) == nil
      assert File.exists?(Archive.Paths.absolute(video.file_path))
    end
  end

  test "downloads, import and settings pages render", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/downloads")
    assert html =~ "Downloads"
    {:ok, _view, html} = live(conn, ~p"/import")
    assert html =~ "Import existing files"
    {:ok, view, _html} = live(conn, ~p"/settings")
    assert has_element?(view, "#tools-status")

    view |> form("#settings-form", form: %{download_concurrency: "3"}) |> render_submit()
    assert Archive.Settings.get(:download_concurrency) == 3
  end
end
