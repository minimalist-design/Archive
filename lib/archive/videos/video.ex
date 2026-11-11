defmodule Archive.Videos.Video do
  @moduledoc "An archived video file plus its metadata."
  use Ecto.Schema
  import Ecto.Changeset

  schema "videos" do
    field :extractor_key, :string
    field :remote_id, :string
    field :webpage_url, :string
    field :title, :string
    field :description, :string
    field :uploader, :string
    field :channel, :string
    field :upload_date, :date
    field :duration, :integer
    field :tags, {:array, :string}, default: []
    field :language, :string
    field :width, :integer
    field :height, :integer
    field :fps, :float
    field :vcodec, :string
    field :acodec, :string
    field :container, :string
    field :filesize, :integer
    field :file_path, :string
    field :info_json_path, :string
    field :thumbnail_path, :string
    field :playback, :string, default: "direct"
    field :status, :string, default: "ready"
    field :metadata, :map, default: %{}
    field :downloaded_at, :utc_datetime

    # Populated by keyset-paginated queries.
    field :sort_key, :any, virtual: true

    belongs_to :library, Archive.Libraries.Library
    has_many :subtitles, Archive.Videos.Subtitle, preload_order: [asc: :lang]

    many_to_many :categories, Archive.Libraries.Category,
      join_through: "video_categories",
      on_replace: :delete,
      preload_order: [asc: :position, asc: :id]

    timestamps(type: :utc_datetime)
  end

  @fields [
    :extractor_key,
    :remote_id,
    :webpage_url,
    :title,
    :description,
    :uploader,
    :channel,
    :upload_date,
    :duration,
    :tags,
    :language,
    :width,
    :height,
    :fps,
    :vcodec,
    :acodec,
    :container,
    :filesize,
    :file_path,
    :info_json_path,
    :thumbnail_path,
    :playback,
    :status,
    :metadata,
    :downloaded_at
  ]

  @doc "Changeset used by the ingest pipeline (all fields are system-provided)."
  def ingest_changeset(video, attrs) do
    video
    |> cast(attrs, @fields)
    |> validate_required([:extractor_key, :title, :file_path])
    |> validate_inclusion(:playback, ~w(direct transcode))
    |> validate_inclusion(:status, ~w(ready missing))
    |> unique_constraint([:extractor_key, :remote_id],
      name: :videos_extractor_key_remote_id_index,
      message: "is already archived"
    )
  end

  @doc "Changeset for user edits on the video page."
  def edit_changeset(video, attrs) do
    video
    |> cast(attrs, [:title])
    |> validate_required([:title])
  end

  def display_uploader(%__MODULE__{uploader: u, channel: c}), do: u || c
end
