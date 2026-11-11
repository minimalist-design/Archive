defmodule Archive.Boot do
  @moduledoc """
  Synchronous start-up steps run after the repo/migrations and before the job
  queues: create directories and recover jobs interrupted by a shutdown.
  """

  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :run, []}, restart: :temporary}
  end

  def run do
    Archive.Paths.ensure_dirs!()

    unless Application.get_env(:archive, Oban)[:testing] == :manual do
      Archive.Downloads.recover_interrupted()
    end

    :ignore
  end
end
