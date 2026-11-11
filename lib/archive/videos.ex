defmodule Archive.Videos do
  @moduledoc "Archived videos: queries, ingest, organization and deletion."

  import Ecto.Query

  alias Archive.{Events, Files, Layout, Paths, Repo, Search}
  alias Archive.Libraries.{Category, Library}
  alias Archive.Media.Vtt
  alias Archive.Videos.{Subtitle, Video}

  @page_size 48

  # --- reading -------------------------------------------------------------------

  def get_video!(id) do
    Video
    |> Repo.get!(id)
    |> Repo.preload([:library, :categories, :subtitles])
  end

  def get_video(id), do: Repo.get(Video, id)

  def get_subtitle!(id), do: Repo.get!(Subtitle, id)

  def find_by_remote(extractor_key, remote_id)
      when is_nil(extractor_key) or is_nil(remote_id),
      do: nil

  def find_by_remote(extractor_key, remote_id) do
    Repo.one(
      from v in Video,
        where: v.extractor_key == ^extractor_key and v.remote_id == ^remote_id,
        preload: :library
    )
  end

  @doc "Returns the subset of `remote_ids` already archived for an extractor."
  def existing_remote_ids(nil, _remote_ids), do: MapSet.new()
  def existing_remote_ids(_extractor_key, []), do: MapSet.new()

  def existing_remote_ids(extractor_key, remote_ids) do
    remote_ids
    |> Enum.chunk_every(500)
    |> Enum.flat_map(fn chunk ->
      Repo.all(
        from v in Video,
          where: v.extractor_key == ^extractor_key and v.remote_id in ^chunk,
          select: v.remote_id
      )
    end)
    |> MapSet.new()
  end

  @sorts ~w(added_desc added_asc uploaded_desc uploaded_asc title_asc title_desc duration_desc duration_asc)
  def sorts, do: @sorts

  @doc """
  Keyset-paginated videos of a library.

  Options: `:category_id`, `:sort` (one of `sorts/0`), `:query` (FTS search
  within the library), `:after` (the last video of the previous page),
  `:limit`.
  """
  def list_library_videos(library_id, opts \\ []) do
    {field, dir} = parse_sort(Keyword.get(opts, :sort, "added_desc"))
    limit = Keyword.get(opts, :limit, @page_size)
    key = sort_key(field)

    query =
      from(v in Video,
        where: v.library_id == ^library_id,
        order_by: ^[{dir, key}, {dir, dynamic([v], v.id)}],
        limit: ^limit
      )
      |> select_merge(^%{sort_key: key})
      |> filter_category(opts[:category_id])
      |> filter_query(opts[:query])
      |> after_cursor(opts[:after], key, dir)

    Repo.all(query)
  end

  defp parse_sort(sort) do
    case sort do
      "added_asc" -> {:inserted_at, :asc}
      "uploaded_desc" -> {:upload_date, :desc}
      "uploaded_asc" -> {:upload_date, :asc}
      "title_asc" -> {:title, :asc}
      "title_desc" -> {:title, :desc}
      "duration_desc" -> {:duration, :desc}
      "duration_asc" -> {:duration, :asc}
      _ -> {:inserted_at, :desc}
    end
  end

  # All sort keys are raw SQL expressions so the value read back for the
  # cursor compares exactly like the stored data (no type casting).
  defp sort_key(:inserted_at), do: dynamic([v], fragment("(?)", v.inserted_at))
  defp sort_key(:upload_date), do: dynamic([v], fragment("coalesce(?, '')", v.upload_date))
  defp sort_key(:title), do: dynamic([v], fragment("lower(?)", v.title))
  defp sort_key(:duration), do: dynamic([v], fragment("coalesce(?, 0)", v.duration))

  defp filter_category(query, nil), do: query

  defp filter_category(query, category_id) do
    from v in query,
      join: vc in "video_categories",
      on: vc.video_id == v.id and vc.category_id == ^category_id
  end

  defp filter_query(query, q) when q in [nil, ""], do: query

  defp filter_query(query, q) do
    case Search.match_expression(q) do
      nil ->
        query

      match ->
        from v in query,
          where: v.id in fragment("SELECT rowid FROM videos_fts WHERE videos_fts MATCH ?", ^match)
    end
  end

  defp after_cursor(query, nil, _key, _dir), do: query

  defp after_cursor(query, %Video{id: id, sort_key: value}, key, :desc) do
    where(query, [v], ^dynamic([v], ^key < ^value or (^key == ^value and v.id < ^id)))
  end

  defp after_cursor(query, %Video{id: id, sort_key: value}, key, :asc) do
    where(query, [v], ^dynamic([v], ^key > ^value or (^key == ^value and v.id > ^id)))
  end

  def page_size, do: @page_size

  @doc "Latest videos per library for the home page shelves."
  def shelves(libraries, per_library \\ 12) do
    libraries
    |> Enum.map(fn library ->
      videos =
        Repo.all(
          from v in Video,
            where: v.library_id == ^library.id,
            order_by: [desc: v.inserted_at, desc: v.id],
            limit: ^per_library
        )

      {library, videos}
    end)
    |> Enum.reject(fn {_library, videos} -> videos == [] end)
  end

  @doc "Other videos of the same library (for the video page)."
  def related(%Video{} = video, limit \\ 12) do
    Repo.all(
      from v in Video,
        where: v.library_id == ^video.library_id and v.id != ^video.id,
        order_by: [desc: v.inserted_at, desc: v.id],
        limit: ^limit
    )
  end

  # --- ingest --------------------------------------------------------------------

  @doc """
  Creates a video with its categories and subtitles and indexes it for search.

  `subtitles` is a list of `%{lang: , auto: , path: }` with paths relative to
  the storage dir.
  """
  def create_video(%Library{} = library, attrs, opts \\ []) do
    category_ids = Keyword.get(opts, :category_ids, [])
    subtitles = Keyword.get(opts, :subtitles, [])

    result =
      Repo.transaction(fn ->
        categories = categories_for(library.id, category_ids)

        video =
          %Video{library_id: library.id}
          |> Video.ingest_changeset(attrs)
          |> Ecto.Changeset.put_assoc(:categories, categories)
          |> Repo.insert()
          |> case do
            {:ok, video} -> video
            {:error, changeset} -> Repo.rollback(changeset)
          end

        now = DateTime.utc_now(:second)

        subs =
          Enum.map(subtitles, fn s ->
            %{
              video_id: video.id,
              lang: s.lang,
              auto: s.auto,
              path: s.path,
              inserted_at: now,
              updated_at: now
            }
          end)

        if subs != [], do: Repo.insert_all(Subtitle, subs)

        video = Repo.preload(video, [:subtitles, :library], force: true)
        index(video)
        video
      end)

    with {:ok, video} <- result do
      Events.broadcast("videos", {:video_added, video})
      {:ok, video}
    end
  end

  defp categories_for(_library_id, []), do: []

  defp categories_for(library_id, ids) do
    Repo.all(from c in Category, where: c.library_id == ^library_id and c.id in ^ids)
  end

  # --- full-text index ---------------------------------------------------------------

  @max_subtitle_chars 300_000

  @doc "(Re)indexes a video in the FTS table."
  def index(%Video{} = video) do
    video = Repo.preload(video, :subtitles)

    subtitles =
      video.subtitles
      |> Enum.map(fn s -> Vtt.file_to_text(Paths.absolute(s.path)) end)
      |> Enum.join("\n")
      |> String.slice(0, @max_subtitle_chars)

    Repo.query!("DELETE FROM videos_fts WHERE rowid = ?1", [video.id])

    Repo.query!(
      "INSERT INTO videos_fts(rowid, title, description, tags, subtitles) VALUES (?1, ?2, ?3, ?4, ?5)",
      [
        video.id,
        video.title,
        video.description || "",
        Enum.join(video.tags || [], " "),
        subtitles
      ]
    )

    :ok
  end

  def delete_fts([]), do: :ok

  def delete_fts(ids) when is_list(ids) do
    ids
    |> Enum.chunk_every(500)
    |> Enum.each(fn chunk ->
      placeholders = Enum.map_join(1..length(chunk), ",", &"?#{&1}")
      Repo.query!("DELETE FROM videos_fts WHERE rowid IN (#{placeholders})", chunk)
    end)
  end

  # --- organization --------------------------------------------------------------

  def update_title(%Video{} = video, title) do
    with {:ok, video} <- video |> Video.edit_changeset(%{title: title}) |> Repo.update() do
      index(video)
      Events.broadcast("videos", {:video_updated, video})
      {:ok, video}
    end
  end

  @doc "Replaces the categories of a video (ids must belong to its library)."
  def set_categories(%Video{} = video, category_ids) do
    video = Repo.preload(video, :categories)
    categories = categories_for(video.library_id, Enum.map(category_ids, &to_int/1))

    with {:ok, video} <-
           video
           |> Ecto.Changeset.change()
           |> Ecto.Changeset.put_assoc(:categories, categories)
           |> Repo.update() do
      Events.broadcast("videos", {:video_updated, video})
      {:ok, video}
    end
  end

  @doc "Adds or removes a category on many videos at once."
  def bulk_categorize(video_ids, category_id, action) when action in [:add, :remove] do
    category = Repo.get!(Category, category_id)

    ids =
      Repo.all(
        from v in Video,
          where: v.id in ^video_ids and v.library_id == ^category.library_id,
          select: v.id
      )

    case action do
      :add ->
        rows = Enum.map(ids, &%{video_id: &1, category_id: category.id})
        Repo.insert_all("video_categories", rows, on_conflict: :nothing)

      :remove ->
        Repo.delete_all(
          from vc in "video_categories",
            where: vc.category_id == ^category.id and vc.video_id in ^ids
        )
    end

    Events.broadcast("videos", {:videos_changed, category.library_id})
    {:ok, length(ids)}
  end

  @doc """
  Moves a video to another library by moving its folder (with everything in
  it) into the target library folder. Its categories are dropped because
  categories are scoped per library.
  """
  def move_to_library(%Video{} = video, %Library{} = target) do
    video = Repo.preload(video, [:subtitles, :categories, :library])

    with false <- video.library_id == target.id,
         {:ok, video} <- Layout.ensure_own_folder(video) do
      video = Repo.preload(video, [:subtitles, :categories], force: true)
      old_folder = Path.dirname(video.file_path)
      src_dir = Paths.absolute(old_folder)

      dest_dir =
        Files.unique_dir(Path.join(Paths.library_dir(target), Path.basename(old_folder)))

      new_folder = Paths.relative(dest_dir)
      rebase = fn rel -> rel && Path.join(new_folder, Path.relative_to(rel, old_folder)) end

      case Files.move(src_dir, dest_dir) do
        :ok ->
          Repo.transaction(fn ->
            video
            |> Ecto.Changeset.change(
              library_id: target.id,
              file_path: rebase.(video.file_path),
              info_json_path: rebase.(video.info_json_path),
              thumbnail_path: rebase.(video.thumbnail_path)
            )
            |> Ecto.Changeset.put_assoc(:categories, [])
            |> Repo.update!()

            for s <- video.subtitles do
              s |> Ecto.Changeset.change(path: rebase.(s.path)) |> Repo.update!()
            end
          end)

          video = get_video!(video.id)
          Events.broadcast("videos", {:video_updated, video})
          Events.libraries_changed()
          {:ok, video}

        {:error, reason} ->
          {:error, reason}
      end
    else
      true -> {:ok, video}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Deletes a video. With `delete_files: true` its files are removed too."
  def delete_video(%Video{} = video, opts \\ []) do
    video = Repo.preload(video, :subtitles)

    result =
      Repo.transaction(fn ->
        delete_fts([video.id])
        Repo.delete!(video)
      end)

    with {:ok, _} <- result do
      Files.rm(Paths.grid_thumb(video.id))
      Archive.Media.TranscodeSession.stop(video.id)

      if opts[:delete_files], do: delete_files(video)

      Events.broadcast("videos", {:video_deleted, video})
      Events.libraries_changed()
      {:ok, video}
    end
  end

  # Videos in their own folder: remove the folder (everything in it belongs
  # to the video). Legacy flat videos: remove the known files one by one.
  defp delete_files(video) do
    dir = Layout.video_dir(video)
    library_dir = Path.join(Paths.storage_dir(), hd(Path.split(video.file_path)))

    if Layout.own_folder?(video) and Path.dirname(Path.expand(dir)) == Path.expand(library_dir) do
      File.rm_rf(dir)
    else
      video |> Layout.relative_files() |> Enum.each(&Files.rm(Paths.absolute(&1)))
    end
  end

  @doc "Marks videos whose file vanished as missing (and found ones as ready)."
  def verify_files do
    from(v in Video, select: {v.id, v.file_path, v.status})
    |> Repo.all()
    |> Enum.reduce(0, fn {id, path, status}, changed ->
      new_status = if File.exists?(Paths.absolute(path)), do: "ready", else: "missing"

      if new_status != status do
        from(v in Video, where: v.id == ^id) |> Repo.update_all(set: [status: new_status])
        changed + 1
      else
        changed
      end
    end)
  end

  defp to_int(v) when is_integer(v), do: v
  defp to_int(v) when is_binary(v), do: String.to_integer(v)
end
