defmodule Archive.Libraries.Library do
  @moduledoc "A library: a playlist-like collection of videos with its own folder."
  use Ecto.Schema
  import Ecto.Changeset

  schema "libraries" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :source_url, :string
    field :last_synced_at, :utc_datetime
    field :video_count, :integer, virtual: true, default: 0

    has_many :categories, Archive.Libraries.Category, preload_order: [asc: :position, asc: :id]
    has_many :videos, Archive.Videos.Video

    timestamps(type: :utc_datetime)
  end

  def changeset(library, attrs) do
    library
    |> cast(attrs, [:name, :description, :source_url])
    |> update_change(:name, &String.trim/1)
    |> update_change(:source_url, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 120)
    |> validate_url(:source_url)
    |> unique_constraint(:slug)
  end

  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn _, url ->
      case URI.parse(url) do
        %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
          []

        _ ->
          [{field, "must be an http(s) URL"}]
      end
    end)
  end
end
