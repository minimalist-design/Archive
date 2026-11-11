defmodule Archive.Videos.Subtitle do
  @moduledoc "A WebVTT subtitle file belonging to a video."
  use Ecto.Schema

  schema "subtitles" do
    field :lang, :string
    field :auto, :boolean, default: false
    field :path, :string
    belongs_to :video, Archive.Videos.Video

    timestamps(type: :utc_datetime)
  end
end
