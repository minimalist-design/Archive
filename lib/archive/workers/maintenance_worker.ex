defmodule Archive.Workers.MaintenanceWorker do
  @moduledoc """
  Daily housekeeping: flags videos whose file disappeared, removes stale
  transcode sessions and temp files.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  require Logger
  alias Archive.{Paths, Videos}

  @impl Oban.Worker
  def perform(_job) do
    changed = Videos.verify_files()
    if changed > 0, do: Logger.info("maintenance: #{changed} video(s) changed file status")

    clean_dir(Paths.tmp_dir(), 24 * 3600)
    clean_dir(Paths.transcode_dir(), 6 * 3600)
    :ok
  end

  defp clean_dir(dir, max_age_s) do
    now = System.os_time(:second)

    case File.ls(dir) do
      {:ok, names} ->
        for name <- names do
          path = Path.join(dir, name)

          case File.stat(path, time: :posix) do
            {:ok, %{mtime: mtime}} when now - mtime > max_age_s -> File.rm_rf(path)
            _ -> :ok
          end
        end

      _ ->
        :ok
    end
  end
end
