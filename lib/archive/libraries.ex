defmodule Archive.Libraries do
  @moduledoc "Libraries (playlist-like collections) and their categories."

  import Ecto.Query

  alias Archive.{Events, Files, Paths, Repo}
  alias Archive.Libraries.{Category, Library}
  alias Archive.Videos
  alias Archive.Videos.Video

  # --- libraries --------------------------------------------------------------

  @doc "All libraries ordered by name, with `video_count` populated."
  def list_libraries do
    counts =
      from(v in Video,
        group_by: v.library_id,
        select: %{library_id: v.library_id, n: count(v.id)}
      )

    from(l in Library,
      left_join: c in subquery(counts),
      on: c.library_id == l.id,
      order_by: [asc: fragment("lower(?)", l.name)],
      select: %{l | video_count: coalesce(c.n, 0)}
    )
    |> Repo.all()
  end

  def get_library!(id), do: Repo.get!(Library, id)

  def get_library_by_slug(slug), do: Repo.get_by(Library, slug: slug)

  def get_library_by_slug!(slug), do: Repo.get_by!(Library, slug: slug)

  def count_videos(%Library{id: id}) do
    Repo.aggregate(from(v in Video, where: v.library_id == ^id), :count)
  end

  def change_library(%Library{} = library, attrs \\ %{}) do
    Library.changeset(library, attrs)
  end

  def create_library(attrs) do
    changeset = Library.changeset(%Library{}, attrs)

    changeset =
      case Ecto.Changeset.get_field(changeset, :name) do
        name when is_binary(name) and name != "" ->
          Ecto.Changeset.put_change(changeset, :slug, unique_slug(name, nil))

        _ ->
          changeset
      end

    with {:ok, library} <- Repo.insert(changeset) do
      _ = File.mkdir_p(Paths.library_dir(library))
      Events.libraries_changed()
      {:ok, library}
    end
  end

  @doc """
  Updates a library. Renaming it also renames its folder on disk and rewrites
  the stored file paths of its videos.
  """
  def update_library(%Library{} = library, attrs) do
    changeset = Library.changeset(library, attrs)
    new_name = Ecto.Changeset.get_change(changeset, :name)

    changeset =
      if new_name && changeset.valid?,
        do: Ecto.Changeset.put_change(changeset, :slug, unique_slug(new_name, library.id)),
        else: changeset

    new_slug = Ecto.Changeset.get_change(changeset, :slug)

    cond do
      not changeset.valid? ->
        {:error, %{changeset | action: :update}}

      new_slug && new_slug != library.slug ->
        rename_library(library, changeset, new_slug)

      true ->
        with {:ok, library} <- Repo.update(changeset) do
          Events.libraries_changed()
          {:ok, library}
        end
    end
  end

  defp rename_library(library, changeset, new_slug) do
    old_dir = Paths.library_dir(library)
    new_dir = Paths.library_dir(%{slug: new_slug})

    moved? =
      cond do
        not File.exists?(old_dir) -> File.mkdir_p(new_dir) == :ok and false
        File.exists?(new_dir) -> :conflict
        true -> File.rename(old_dir, new_dir) == :ok
      end

    if moved? == :conflict do
      {:error,
       changeset
       |> Ecto.Changeset.add_error(:name, "a folder named %{slug} already exists", slug: new_slug)
       |> Map.put(:action, :update)}
    else
      result =
        Repo.transaction(fn ->
          updated = Repo.update!(changeset)
          rewrite_paths(library.id, library.slug, new_slug)
          updated
        end)

      case result do
        {:ok, library} ->
          Events.libraries_changed()
          {:ok, library}

        error ->
          if moved?, do: File.rename(new_dir, old_dir)
          error
      end
    end
  end

  defp rewrite_paths(library_id, old_slug, new_slug) do
    old_prefix = old_slug <> "/"
    new_prefix = new_slug <> "/"
    # SQLite's substr/length count code points.
    len = old_prefix |> String.codepoints() |> length()

    for column <- ~w(file_path info_json_path thumbnail_path) do
      Repo.query!(
        "UPDATE videos SET #{column} = ?1 || substr(#{column}, ?2) " <>
          "WHERE library_id = ?3 AND substr(#{column}, 1, ?4) = ?5",
        [new_prefix, len + 1, library_id, len, old_prefix]
      )
    end

    Repo.query!(
      "UPDATE subtitles SET path = ?1 || substr(path, ?2) " <>
        "WHERE video_id IN (SELECT id FROM videos WHERE library_id = ?3) " <>
        "AND substr(path, 1, ?4) = ?5",
      [new_prefix, len + 1, library_id, len, old_prefix]
    )
  end

  @doc "Deletes a library and its videos; optionally removes its folder from disk."
  def delete_library(%Library{} = library, opts \\ []) do
    video_ids = Repo.all(from v in Video, where: v.library_id == ^library.id, select: v.id)

    result =
      Repo.transaction(fn ->
        Videos.delete_fts(video_ids)
        Repo.delete!(library)
      end)

    with {:ok, library} <- result do
      Enum.each(video_ids, &Files.rm(Paths.grid_thumb(&1)))

      if opts[:delete_files] do
        dir = Paths.library_dir(library)
        # Never delete anything outside the storage dir.
        if Path.dirname(Path.expand(dir)) == Path.expand(Paths.storage_dir()),
          do: File.rm_rf(dir)
      end

      Events.libraries_changed()
      {:ok, library}
    end
  end

  def touch_synced(%Library{} = library) do
    library
    |> Ecto.Changeset.change(last_synced_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  defp unique_slug(name, own_id) do
    base = Files.slugify(name)

    taken? = fn slug ->
      query = from(l in Library, where: l.slug == ^slug)
      query = if own_id, do: where(query, [l], l.id != ^own_id), else: query
      Repo.exists?(query)
    end

    [base | Enum.map(2..1000, &"#{base}-#{&1}")]
    |> Enum.find(&(not taken?.(&1)))
  end

  # --- categories ----------------------------------------------------------------

  def list_categories(%Library{id: id}), do: list_categories(id)

  def list_categories(library_id) do
    from(c in Category,
      where: c.library_id == ^library_id,
      order_by: [asc: c.position, asc: c.id]
    )
    |> Repo.all()
  end

  def get_category!(id), do: Repo.get!(Category, id)

  def change_category(%Category{} = category, attrs \\ %{}),
    do: Category.changeset(category, attrs)

  def create_category(%Library{id: library_id}, attrs) do
    position =
      Repo.one(from c in Category, where: c.library_id == ^library_id, select: max(c.position)) ||
        -1

    %Category{library_id: library_id, position: position + 1}
    |> Category.changeset(attrs)
    |> Repo.insert()
    |> broadcast_category()
  end

  def rename_category(%Category{} = category, name) do
    category
    |> Category.changeset(%{name: name})
    |> Repo.update()
    |> broadcast_category()
  end

  def delete_category(%Category{} = category) do
    category |> Repo.delete() |> broadcast_category()
  end

  @doc "Moves a category one step up (-1) or down (+1)."
  def move_category(%Category{} = category, direction) when direction in [-1, 1] do
    categories = list_categories(category.library_id)
    index = Enum.find_index(categories, &(&1.id == category.id))
    target = index + direction

    if target >= 0 and target < length(categories) do
      reordered =
        categories
        |> List.delete_at(index)
        |> List.insert_at(target, category)

      Repo.transaction(fn ->
        reordered
        |> Enum.with_index()
        |> Enum.each(fn {c, i} ->
          from(x in Category, where: x.id == ^c.id) |> Repo.update_all(set: [position: i])
        end)
      end)

      Events.libraries_changed()
    end

    :ok
  end

  defp broadcast_category({:ok, _} = result) do
    Events.libraries_changed()
    result
  end

  defp broadcast_category(error), do: error
end
