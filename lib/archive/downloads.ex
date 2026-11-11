defmodule Archive.Downloads do
  @moduledoc """
  The download/import queue. Each `Download` row tracks one Oban job and is
  what the Downloads page shows (progress, errors, retry, cancel).
  """

  import Ecto.Query
  require Logger

  alias Archive.{Events, Libraries, Repo}
  alias Archive.Downloads.Download
  alias Archive.Libraries.Library
  alias Archive.Workers.{DownloadWorker, ImportWorker, ResolveWorker}

  # --- enqueueing ----------------------------------------------------------------

  @doc """
  Queues a URL (single video, playlist or channel) for download into a library.
  """
  def enqueue_url(url, %Library{} = library, category_ids \\ []) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        create_and_enqueue(%{
          url: url,
          kind: "resolve",
          library_id: library.id,
          category_ids: valid_category_ids(library, category_ids),
          title: url
        })

      _ ->
        {:error, :invalid_url}
    end
  end

  @doc "Re-checks a library's source URL and queues videos not yet archived."
  def sync_library(%Library{source_url: url} = library) when is_binary(url) and url != "" do
    with {:ok, download} <-
           create_and_enqueue(%{
             url: url,
             kind: "resolve",
             library_id: library.id,
             title: "Sync: #{library.name}",
             note: "sync"
           }) do
      Libraries.touch_synced(library)
      {:ok, download}
    end
  end

  def sync_library(_library), do: {:error, :no_source_url}

  @doc "Queues a nested playlist URL found while resolving another one."
  def enqueue_resolve(url, library_id, category_ids, title) do
    create_and_enqueue(%{
      url: url,
      kind: "resolve",
      library_id: library_id,
      category_ids: category_ids,
      title: title || url
    })
  end

  @doc "Queues the import of an existing file into a library."
  def enqueue_import(path, %Library{} = library, category_ids \\ []) do
    create_and_enqueue(%{
      url: path,
      kind: "import",
      library_id: library.id,
      category_ids: valid_category_ids(library, category_ids),
      title: Path.basename(path)
    })
  end

  @doc """
  Inserts many `video` downloads (from a resolved playlist) and their jobs.
  `entries` are maps with `:url` and `:title`.
  """
  def enqueue_videos(entries, library_id, category_ids) do
    now = DateTime.utc_now(:second)

    Repo.transaction(fn ->
      Enum.map(entries, fn entry ->
        download =
          Repo.insert!(%Download{
            url: entry.url,
            kind: "video",
            status: "queued",
            library_id: library_id,
            category_ids: category_ids,
            title: entry.title || entry.url,
            inserted_at: now,
            updated_at: now
          })

        attach_job(download)
      end)
    end)
    |> tap(fn _ -> Events.broadcast("downloads", {:downloads_changed}) end)
  end

  @doc "Turns a resolve download into a single-video download and queues it."
  def convert_to_video(%Download{} = download, title) do
    download
    |> Ecto.Changeset.change(kind: "video", status: "queued", title: title || download.title)
    |> Repo.update!()
    |> attach_job()
    |> broadcast()
  end

  defp create_and_enqueue(attrs) do
    result =
      Repo.transaction(fn ->
        %Download{}
        |> Ecto.Changeset.change(attrs)
        |> Repo.insert!()
        |> attach_job()
      end)

    with {:ok, download} <- result do
      Events.broadcast("downloads", {:downloads_changed})
      {:ok, download}
    end
  end

  defp attach_job(%Download{} = download) do
    job = Oban.insert!(worker_for(download.kind).new(%{"download_id" => download.id}))
    download |> Ecto.Changeset.change(oban_job_id: job.id) |> Repo.update!()
  end

  defp worker_for("resolve"), do: ResolveWorker
  defp worker_for("video"), do: DownloadWorker
  defp worker_for("import"), do: ImportWorker

  defp valid_category_ids(%Library{id: library_id}, ids) do
    ids = ids |> List.wrap() |> Enum.map(&to_int/1) |> Enum.reject(&is_nil/1)
    valid = Libraries.list_categories(library_id) |> Enum.map(& &1.id) |> MapSet.new()
    Enum.filter(ids, &MapSet.member?(valid, &1))
  end

  defp to_int(v) when is_integer(v), do: v

  defp to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, ""} -> i
      _ -> nil
    end
  end

  defp to_int(_), do: nil

  # --- reading -----------------------------------------------------------------------

  def get_download!(id), do: Repo.get!(Download, id) |> Repo.preload(:library)
  def get_download(id), do: Repo.get(Download, id)

  @doc "Downloads grouped for the Downloads page."
  def list_grouped(finished_limit \\ 100) do
    active =
      from(d in Download,
        where: d.status in ["queued", "running"],
        order_by: [
          desc: fragment("CASE ? WHEN 'running' THEN 1 ELSE 0 END", d.status),
          asc: d.id
        ],
        preload: :library
      )
      |> Repo.all()

    failed =
      from(d in Download,
        where: d.status == "failed",
        order_by: [desc: d.updated_at],
        preload: :library
      )
      |> Repo.all()

    finished =
      from(d in Download,
        where: d.status in ["done", "skipped", "cancelled"],
        order_by: [desc: d.updated_at, desc: d.id],
        limit: ^finished_limit,
        preload: :library
      )
      |> Repo.all()

    %{
      running: Enum.filter(active, &(&1.status == "running")),
      queued: Enum.filter(active, &(&1.status == "queued")),
      failed: failed,
      finished: finished
    }
  end

  def active_count do
    Repo.aggregate(from(d in Download, where: d.status in ["queued", "running"]), :count)
  end

  # --- state changes (used by workers) ---------------------------------------------------

  def mark_running(%Download{} = d, attempt) do
    change_row(d,
      status: "running",
      attempt: attempt,
      started_at: DateTime.utc_now(:second),
      error: nil,
      progress: nil,
      speed: nil,
      eta: nil
    )
  end

  def mark_done(%Download{} = d, fields \\ []) do
    change_row(
      d,
      Keyword.merge(
        [status: "done", finished_at: DateTime.utc_now(:second), progress: 100.0, note: nil],
        fields
      )
    )
  end

  def mark_skipped(%Download{} = d, note, fields \\ []) do
    change_row(
      d,
      [status: "skipped", note: note, finished_at: DateTime.utc_now(:second)] ++ fields
    )
  end

  def mark_failed(%Download{} = d, error, opts \\ []) do
    status = if opts[:retrying], do: "queued", else: "failed"
    change_row(d, status: status, error: error, speed: nil, eta: nil, note: opts[:note])
  end

  def update_progress(%Download{} = d, fields), do: change_row(d, fields)

  def set_title(%Download{} = d, title) when is_binary(title), do: change_row(d, title: title)
  def set_title(d, _), do: d

  defp change_row(%Download{} = d, fields) do
    d
    |> Ecto.Changeset.change(fields)
    |> Repo.update!()
    |> broadcast()
  end

  defp broadcast(%Download{} = d) do
    Events.broadcast("downloads", {:download_updated, d})
    d
  end

  # --- user actions --------------------------------------------------------------------

  @doc "Retries a failed/cancelled download with a fresh job."
  def retry(%Download{} = d) do
    d
    |> Ecto.Changeset.change(status: "queued", error: nil, note: nil, progress: nil)
    |> Repo.update!()
    |> attach_job()
    |> broadcast()
  end

  def retry_all_failed do
    from(d in Download, where: d.status == "failed")
    |> Repo.all()
    |> Enum.each(&retry/1)
  end

  @doc "Cancels a queued or running download (kills the running process)."
  def cancel(%Download{} = d) do
    if d.oban_job_id, do: Oban.cancel_job(d.oban_job_id)

    change_row(d,
      status: "cancelled",
      speed: nil,
      eta: nil,
      finished_at: DateTime.utc_now(:second)
    )
  end

  def clear_finished do
    from(d in Download, where: d.status in ["done", "skipped", "cancelled"]) |> Repo.delete_all()
    Events.broadcast("downloads", {:downloads_changed})
  end

  def delete(%Download{} = d) do
    if Download.active?(d) and d.oban_job_id, do: Oban.cancel_job(d.oban_job_id)
    Repo.delete!(d)
    Events.broadcast("downloads", {:downloads_changed})
  end

  @doc """
  Called at boot (before queues start): jobs that were executing when the app
  stopped are made available again, and their rows are shown as queued.
  """
  def recover_interrupted do
    Repo.query!("UPDATE oban_jobs SET state = 'available' WHERE state = 'executing'")

    from(d in Download, where: d.status == "running")
    |> Repo.update_all(set: [status: "queued", speed: nil, eta: nil])

    :ok
  rescue
    error ->
      Logger.warning("could not recover interrupted jobs: #{Exception.message(error)}")
      :ok
  end
end
