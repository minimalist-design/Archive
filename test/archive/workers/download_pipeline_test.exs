defmodule Archive.Workers.DownloadPipelineTest do
  use Archive.DataCase, async: false
  use Oban.Testing, repo: Archive.Repo, engine: Oban.Engines.Lite

  import Archive.Fixtures
  alias Archive.{Downloads, Paths, Repo, Settings, Videos}
  alias Archive.Downloads.Download
  alias Archive.Workers.{DownloadWorker, ResolveWorker}

  setup do
    clean_dirs!()
    %{library: library_fixture(%{name: "Downloads"})}
  end

  defp run_resolve(download) do
    perform_job(ResolveWorker, %{"download_id" => download.id})
  end

  defp run_download(download) do
    perform_job(DownloadWorker, %{"download_id" => download.id})
  end

  test "rejects invalid URLs", %{library: library} do
    assert {:error, :invalid_url} = Downloads.enqueue_url("not a url", library)
  end

  test "a single video URL is resolved, downloaded and archived", %{library: library} do
    category = category_fixture(library, "Fav")

    {:ok, download} =
      Downloads.enqueue_url("https://www.youtube.com/watch?v=abc", library, [
        to_string(category.id)
      ])

    assert_enqueued(worker: ResolveWorker, args: %{"download_id" => download.id})
    assert :ok = run_resolve(download)

    download = Repo.get!(Download, download.id)
    assert download.kind == "video"
    assert download.status == "queued"
    assert_enqueued(worker: DownloadWorker, args: %{"download_id" => download.id})

    assert :ok = run_download(download)

    download = Repo.get!(Download, download.id)
    assert download.status == "done"
    assert download.progress == 100.0

    video = Videos.get_video!(download.video_id)
    assert video.title == "Fake video abc"
    assert video.uploader == "Fake Uploader"
    assert video.upload_date == ~D[2024-01-31]
    assert video.file_path == "downloads/Fake video abc [abc].mp4"
    assert video.thumbnail_path == "downloads/Fake video abc [abc].jpg"
    assert video.playback == "direct"
    assert video.metadata["view_count"] == 1234
    refute Map.has_key?(video.metadata, "formats")
    assert Enum.map(video.categories, & &1.id) == [category.id]
    assert [%{lang: "es", auto: false}] = video.subtitles
    assert File.exists?(Paths.grid_thumb(video.id))

    # Searchable by subtitle text.
    assert [%{id: id}] = Archive.Search.search("ornitorrinco")
    assert id == video.id
  end

  test "subtitle languages follow the setting" do
    info = %{"language" => "es-419"}
    assert Archive.YtDlp.sub_langs(info, "original_plus_en") == "es(-.*)?,en(-.*)?,-live_chat"
    assert Archive.YtDlp.sub_langs(info, "en") == "en(-.*)?,-live_chat"
    assert Archive.YtDlp.sub_langs(%{}, "original") == "en(-.*)?,-live_chat"
    assert Archive.YtDlp.sub_langs(info, "none") == nil
  end

  test "a playlist queues one download per new entry", %{library: library} do
    video_fixture(library, %{extractor_key: "Youtube", remote_id: "fake1"})

    {:ok, download} = Downloads.enqueue_url("https://www.youtube.com/playlist?list=x", library)
    assert :ok = run_resolve(download)

    download = Repo.get!(Download, download.id)
    assert download.status == "done"
    assert download.note == "1 queued, 1 already archived"

    assert [%Download{kind: "video", url: "https://www.youtube.com/watch?v=fake2"}] =
             Repo.all(from d in Download, where: d.id != ^download.id)
  end

  test "a channel expands inline tabs and queues URL-only tabs as new resolves", %{
    library: library
  } do
    {:ok, download} = Downloads.enqueue_url("https://www.youtube.com/@fake/channel", library)
    assert :ok = run_resolve(download)

    others = Repo.all(from d in Download, where: d.id != ^download.id, order_by: d.id)

    assert [
             %Download{kind: "resolve", url: "https://www.youtube.com/@fake/playlists"},
             %Download{kind: "video", url: "https://www.youtube.com/watch?v=ch1"}
           ] = Enum.sort_by(others, & &1.kind)

    assert Repo.get!(Download, download.id).note =~ "1 sub-playlist(s) queued"
  end

  test "already archived videos are skipped", %{library: library} do
    existing = video_fixture(library, %{extractor_key: "Youtube", remote_id: "dup"})
    {:ok, download} = Downloads.enqueue_url("https://www.youtube.com/watch?v=dup", library)

    assert :ok = run_resolve(download)
    download = Repo.get!(Download, download.id)
    assert download.status == "skipped"
    assert download.video_id == existing.id
  end

  test "errors are shown and permanent failures are not retried", %{library: library} do
    {:ok, download} = Downloads.enqueue_url("https://example.com/unavailable", library)
    assert {:cancel, message} = run_resolve(download)
    assert message =~ "This video is unavailable"

    download = Repo.get!(Download, download.id)
    assert download.status == "failed"
    assert download.error =~ "unavailable"

    # Retrying from the UI queues a new job.
    download = Downloads.retry(download)
    assert download.status == "queued"
    assert_enqueued(worker: ResolveWorker, args: %{"download_id" => download.id})
  end

  test "outdated-extractor errors are retried", %{library: library} do
    {:ok, download} = Downloads.enqueue_url("https://example.com/outdated", library)
    download = Downloads.convert_to_video(download, "x")

    assert {:error, _} =
             perform_job(DownloadWorker, %{"download_id" => download.id},
               attempt: 1,
               max_attempts: 3
             )

    assert Repo.get!(Download, download.id).status == "queued"
    assert Repo.get!(Download, download.id).note =~ "yt-dlp update"
  end

  test "settings are persisted and validated" do
    assert {:ok, changed} = Settings.save_form(%{"download_concurrency" => "4"})
    assert :download_concurrency in changed
    assert Settings.get(:download_concurrency) == 4

    assert {:error, changeset} = Settings.save_form(%{"download_concurrency" => "99"})
    refute changeset.valid?

    assert {:error, changeset} = Settings.save_form(%{"storage_dir" => "relative/path"})
    assert errors_on(changeset).storage_dir == ["must be an absolute path"]
  end
end
