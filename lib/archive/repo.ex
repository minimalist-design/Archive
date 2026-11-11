defmodule Archive.Repo do
  use Ecto.Repo,
    otp_app: :archive,
    adapter: Ecto.Adapters.SQLite3
end
