defmodule Archive.Workers.ResolveWorker do
  @moduledoc """
  Expands a submitted URL. A single video turns into a `video` download; a
  playlist/channel turns into one `video` download per entry that isn't
  archived yet.
  """
  use Oban.Worker, queue: :resolve, max_attempts: 2

  alias Archive.{Downloads, Videos, YtDlp}
  alias Archive.Tools.{Manager, Runner}

  @max_depth 2

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"download_id" => id}, attempt: attempt, max_attempts: max}) do
    case Downloads.get_download(id) do
      nil ->
        {:cancel, "download #{id} no longer exists"}

      %{status: status} when status in ["cancelled", "done"] ->
        :ok

      download ->
        download = Downloads.mark_running(download, attempt)

        case YtDlp.flat_info(download.url) do
          {:ok, info} ->
            handle_info(download, info)

          {:error, {:exit, _, stderr} = error} ->
            message = Runner.format_error(error)
            retrying = attempt < max and Manager.outdated_error?(stderr)
            if retrying, do: Manager.update_after_failure()
            Downloads.mark_failed(download, message, retrying: retrying)
            if retrying, do: {:error, message}, else: {:cancel, message}

          {:error, reason} ->
            Downloads.mark_failed(download, inspect(reason))
            {:cancel, inspect(reason)}
        end
    end
  end

  defp handle_info(download, %{"_type" => type} = info)
       when type in ["playlist", "multi_video"] do
    {nested, entries} = info |> collect_entries(0) |> Enum.split_with(& &1.playlist?)
    sync? = download.note == "sync"

    # Playlists/tabs referenced only by URL (e.g. a channel's "Playlists" tab)
    # are expanded by their own resolve jobs.
    for entry <- Enum.uniq_by(nested, & &1.url) do
      Downloads.enqueue_resolve(
        entry.url,
        download.library_id,
        download.category_ids,
        entry.title
      )
    end

    # Dedupe per extractor so lookups hit the unique index.
    existing =
      entries
      |> Enum.reject(&(is_nil(&1.extractor_key) or is_nil(&1.id)))
      |> Enum.group_by(& &1.extractor_key, & &1.id)
      |> Map.new(fn {key, ids} -> {key, Videos.existing_remote_ids(key, ids)} end)

    new_entries =
      entries
      |> Enum.uniq_by(& &1.url)
      |> Enum.reject(fn e ->
        e.id != nil and MapSet.member?(Map.get(existing, e.extractor_key, MapSet.new()), e.id)
      end)

    {:ok, _} = Downloads.enqueue_videos(new_entries, download.library_id, download.category_ids)

    skipped = length(entries) - length(new_entries)
    title = info["title"] || download.title

    title = if sync?, do: download.title, else: "Playlist: #{title}"

    note =
      "#{length(new_entries)} queued, #{skipped} already archived" <>
        if(nested == [], do: "", else: ", #{length(nested)} sub-playlist(s) queued")

    Downloads.mark_done(download, title: title, note: note)

    :ok
  end

  defp handle_info(download, info) do
    title = info["title"]

    # Single video: dedupe early so we don't download twice.
    case Videos.find_by_remote(info["extractor_key"], info["id"]) do
      nil ->
        Downloads.convert_to_video(download, title)
        :ok

      existing ->
        Downloads.mark_skipped(download, "already archived in #{existing.library.name}",
          title: title,
          video_id: existing.id
        )

        :ok
    end
  end

  defp collect_entries(%{"entries" => entries}, depth) when is_list(entries) do
    Enum.flat_map(entries, fn
      nil ->
        []

      %{"entries" => _} = nested when depth < @max_depth ->
        collect_entries(nested, depth + 1)

      entry ->
        url = entry["url"] || entry["webpage_url"]

        if is_binary(url) do
          [
            %{
              url: absolute_url(url, entry),
              title: entry["title"],
              id: entry["id"],
              extractor_key: entry["ie_key"] || entry["extractor_key"],
              playlist?:
                entry["_type"] == "playlist" or
                  entry["ie_key"] in ["YoutubeTab", "YoutubePlaylist"]
            }
          ]
        else
          []
        end
    end)
  end

  defp collect_entries(_info, _depth), do: []

  # Some extractors return bare ids as entry urls.
  defp absolute_url(url, entry) do
    if String.starts_with?(url, ["http://", "https://"]) do
      url
    else
      entry["webpage_url"] || url
    end
  end
end
