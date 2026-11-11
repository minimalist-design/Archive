defmodule Archive.Workers.ImportWorker do
  @moduledoc "Imports one existing file (see `Archive.Importer`)."
  use Oban.Worker, queue: :imports, max_attempts: 1

  alias Archive.{Downloads, Importer, Repo}
  alias Archive.Libraries.Library

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"download_id" => id}, attempt: attempt}) do
    with %{} = download <- Downloads.get_download(id),
         false <- download.status in ["cancelled", "done", "skipped"],
         %{} = library <- download.library_id && Repo.get(Library, download.library_id) do
      download = Downloads.mark_running(download, attempt)

      case Importer.import_file(download.url, library, download.category_ids) do
        {:ok, video, note} ->
          Downloads.mark_done(download, video_id: video.id, title: video.title, note: note)
          :ok

        {:skipped, note, video_id} ->
          Downloads.mark_skipped(download, note, video_id: video_id)
          :ok

        {:error, message} ->
          Downloads.mark_failed(download, message)
          {:cancel, message}
      end
    else
      nil -> {:cancel, "download or library no longer exists"}
      true -> :ok
    end
  end
end
