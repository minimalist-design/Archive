defmodule Archive.Search do
  @moduledoc """
  Live full-text search over title, description, tags and subtitle text using
  SQLite FTS5 with bm25 ranking.
  """

  import Ecto.Query
  alias Archive.Repo
  alias Archive.Videos.Video

  # bm25 column weights: title 10, description 2, tags 5, subtitles 1

  @doc """
  Builds a safe FTS5 MATCH expression from free-form user input. Every word is
  quoted (so FTS syntax characters are inert) and prefix-matched; all words
  must match. Returns `nil` when there is nothing to search for.
  """
  def match_expression(input) when is_binary(input) do
    tokens =
      ~r/[\p{L}\p{N}]+/u
      |> Regex.scan(input)
      |> List.flatten()
      |> Enum.take(12)

    case tokens do
      [] -> nil
      tokens -> Enum.map_join(tokens, " ", &~s("#{&1}"*))
    end
  end

  def match_expression(_), do: nil

  @doc "Searches all videos; best matches first."
  def search(input, opts \\ []) do
    limit = Keyword.get(opts, :limit, 60)

    case match_expression(input) do
      nil ->
        []

      match ->
        from(v in Video,
          join:
            f in fragment(
              "SELECT rowid AS id, bm25(videos_fts, 10.0, 2.0, 5.0, 1.0) AS rank FROM videos_fts WHERE videos_fts MATCH ?",
              ^match
            ),
          on: f.id == v.id,
          order_by: [asc: f.rank, desc: v.inserted_at],
          limit: ^limit,
          preload: :library
        )
        |> Repo.all()
    end
  end
end
