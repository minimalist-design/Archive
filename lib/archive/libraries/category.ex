defmodule Archive.Libraries.Category do
  @moduledoc "A category inside a library. Videos can belong to many categories."
  use Ecto.Schema
  import Ecto.Changeset

  schema "categories" do
    field :name, :string
    field :position, :integer, default: 0
    belongs_to :library, Archive.Libraries.Library

    timestamps(type: :utc_datetime)
  end

  def changeset(category, attrs) do
    category
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 60)
    |> unique_constraint([:library_id, :name], message: "already exists in this library")
  end
end
