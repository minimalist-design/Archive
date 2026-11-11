defmodule Archive.Settings.Entry do
  @moduledoc "A single persisted setting (key → JSON-wrapped value)."
  use Ecto.Schema

  @primary_key {:key, :string, autogenerate: false}
  schema "settings" do
    field :value, :map
    timestamps(type: :utc_datetime)
  end
end
