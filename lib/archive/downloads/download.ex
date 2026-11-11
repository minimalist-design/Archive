defmodule Archive.Downloads.Download do
  @moduledoc """
  A unit of work shown on the Downloads page.

  Kinds: `resolve` (expand a URL/playlist into videos), `video` (download one
  video), `import` (import one existing file).
  """
  use Ecto.Schema

  @statuses ~w(queued running done failed skipped cancelled)
  def statuses, do: @statuses

  schema "downloads" do
    field :url, :string
    field :kind, :string
    field :status, :string, default: "queued"
    field :category_ids, {:array, :integer}, default: []
    field :oban_job_id, :integer
    field :title, :string
    field :progress, :float
    field :speed, :float
    field :eta, :integer
    field :downloaded_bytes, :integer
    field :total_bytes, :integer
    field :error, :string
    field :note, :string
    field :attempt, :integer, default: 0
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    belongs_to :library, Archive.Libraries.Library
    belongs_to :video, Archive.Videos.Video

    timestamps(type: :utc_datetime)
  end

  def active?(%__MODULE__{status: s}), do: s in ["queued", "running"]
end
