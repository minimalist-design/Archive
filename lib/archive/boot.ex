defmodule Archive.Boot do
  @moduledoc """
  Synchronous start-up steps run after the repo/migrations and before the job
  queues: create directories and recover jobs interrupted by a shutdown.
  """

  require Logger

  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :run, []}, restart: :temporary}
  end

  def run do
    Archive.Paths.ensure_dirs!()

    unless Application.get_env(:archive, Oban)[:testing] == :manual do
      Archive.Downloads.recover_interrupted()
      migrate_layout()
    end

    :ignore
  end

  # Videos archived before per-video folders existed are moved into their own
  # folder. Never blocks start-up.
  defp migrate_layout do
    case Archive.Layout.migrate_flat() do
      {0, 0} -> :ok
      {ok, failed} -> Logger.info("moved #{ok} video(s) into their own folders, #{failed} failed")
    end
  rescue
    error -> Logger.error("layout migration failed: #{Exception.message(error)}")
  end
end
