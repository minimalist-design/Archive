defmodule Archive.Workers.DownloadWorker do
  @moduledoc """
  Downloads one video with yt-dlp into its library folder and archives it.

  1. `yt-dlp -J` for the full metadata (and an early duplicate check)
  2. download with `--load-info-json`, streaming progress to the Downloads page
  3. probe the file, collect sidecars, create the video, index it

  Errors that typically mean "yt-dlp is outdated" trigger a tool update and a
  retry; other errors fail the download (it can be retried from the UI).
  """
  use Oban.Worker, queue: :downloads, max_attempts: 3

  alias Archive.{Downloads, Ingest, Paths, Repo, Videos, YtDlp}
  alias Archive.Libraries.Library
  alias Archive.Tools.{Manager, Runner}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"download_id" => id}, attempt: attempt, max_attempts: max}) do
    with %{} = download <- Downloads.get_download(id),
         false <- download.status in ["cancelled", "done", "skipped"],
         %{} = library <- download.library_id && Repo.get(Library, download.library_id) do
      download = Downloads.mark_running(download, attempt)
      run(download, library, attempt, max)
    else
      nil -> {:cancel, "download or library no longer exists"}
      true -> :ok
    end
  end

  defp run(download, library, attempt, max) do
    with {:ok, info} <- YtDlp.extract_info(download.url),
         :ok <- check_info(info),
         download = Downloads.set_title(download, info["title"]),
         :ok <- check_duplicate(download, info),
         {:ok, file, warning} <- fetch(download, library, info),
         {:ok, video} <- archive(download, library, file, info) do
      Downloads.mark_done(download,
        video_id: video.id,
        speed: nil,
        eta: nil,
        note: warning && "finished with warnings",
        error: warning
      )

      :ok
    else
      {:skipped, note, video_id} ->
        Downloads.mark_skipped(download, note, video_id: video_id)
        :ok

      {:error, {:exit, _code, stderr} = error} ->
        fail(download, Runner.format_error(error), stderr, attempt, max)

      {:error, %Ecto.Changeset{} = changeset} ->
        message = changeset_error(changeset)
        Downloads.mark_failed(download, message)
        {:cancel, message}

      {:error, reason} ->
        message = if is_binary(reason), do: reason, else: inspect(reason)
        Downloads.mark_failed(download, message)
        {:cancel, message}
    end
  end

  defp check_info(%{"_type" => type}) when type in ["playlist", "multi_video"],
    do: {:error, "URL is a playlist, not a single video"}

  defp check_info(%{"is_live" => true}), do: {:error, "live streams are not supported"}
  defp check_info(_info), do: :ok

  defp check_duplicate(_download, info) do
    case Videos.find_by_remote(info["extractor_key"], info["id"]) do
      nil -> :ok
      video -> {:skipped, "already archived in #{video.library.name}", video.id}
    end
  end

  defp fetch(download, library, info) do
    dir = Paths.library_dir(library)
    File.mkdir_p!(dir)

    info_path = Paths.tmp_path("info") <> ".json"
    File.write!(info_path, Jason.encode!(info))

    throttle = :counters.new(1, [])

    on_progress = fn p ->
      now = System.monotonic_time(:millisecond)

      if now - :counters.get(throttle, 1) >= 900 or p.status == "finished" do
        :counters.put(throttle, 1, now)

        progress =
          if is_number(p.total_bytes) and p.total_bytes > 0 and is_number(p.downloaded_bytes),
            do: Float.round(p.downloaded_bytes / p.total_bytes * 100, 1),
            else: nil

        Downloads.update_progress(download,
          progress: progress,
          speed: p.speed && p.speed / 1,
          eta: p.eta && round(p.eta),
          downloaded_bytes: p.downloaded_bytes && round(p.downloaded_bytes),
          total_bytes: p.total_bytes && round(p.total_bytes)
        )
      end
    end

    try do
      YtDlp.download(info_path, dir, YtDlp.sub_langs(info), on_progress)
    after
      File.rm(info_path)
    end
  end

  defp archive(download, library, file, info) do
    Downloads.update_progress(download, note: "processing", speed: nil, eta: nil)

    sidecars = Ingest.sidecars(file)
    # The info.json written by yt-dlp is the most complete version.
    info = Ingest.read_info_json(sidecars.info_json) || info

    Ingest.create(library, file, info,
      info_json: sidecars.info_json,
      thumbnail: sidecars.thumbnail,
      subtitles: Ingest.tag_auto_subtitles(sidecars.subtitles, info),
      category_ids: download.category_ids
    )
  end

  defp fail(download, message, stderr, attempt, max) do
    retrying = attempt < max and Manager.outdated_error?(stderr)

    if retrying do
      Manager.update_after_failure()

      Downloads.mark_failed(download, message,
        retrying: true,
        note: "retrying after a yt-dlp update"
      )

      {:error, message}
    else
      Downloads.mark_failed(download, message)
      {:cancel, message}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: 120 * attempt

  defp changeset_error(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field} #{Enum.join(errors, ", ")}" end)
  end
end
