defmodule Archive.Workers.UpdateToolsWorker do
  @moduledoc "Hourly cron tick: updates yt-dlp/deno when the configured interval has elapsed."
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  @impl Oban.Worker
  def perform(_job) do
    Archive.Tools.Manager.update_if_due()
  end
end
