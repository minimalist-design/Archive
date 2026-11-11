defmodule Archive.Layout do
  @moduledoc """
  On-disk layout: every video lives in its own folder inside its library
  folder, with all related files next to it:

      <storage>/<library-slug>/<Title [id]>/<Title [id]>.webm
                                           /<Title [id]>.info.json
                                           /<Title [id]>.jpg
                                           /<Title [id]>.en.vtt

  The folder of a video is always `Path.dirname(video.file_path)`. Videos
  archived before this layout existed sit directly in the library folder
  (`slug/file`); `migrate_flat/0` moves them into their own folders.
  """

  import Ecto.Query
  require Logger

  alias Archive.{Files, Paths, Repo}
  alias Archive.Libraries.Library
  alias Archive.Videos.{Subtitle, Video}

  @doc "Absolute path of the video's folder."
  def video_dir(%Video{file_path: path}), do: Paths.absolute(Path.dirname(path))

  @doc """
  True when the video sits in its own folder (`slug/<folder>/<file>`), false
  for the legacy flat layout (`slug/<file>`).
  """
  def own_folder?(%Video{file_path: path}) do
    length(Path.split(path)) == 3
  end

  @doc "All files of a video, relative to the storage dir."
  def relative_files(%Video{} = video) do
    video = Repo.preload(video, :subtitles)

    [
      video.file_path,
      video.info_json_path,
      video.thumbnail_path | Enum.map(video.subtitles, & &1.path)
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc "A fresh, unused folder for a new video in `library`, named after `base`."
  def new_dir(library, base) do
    Files.unique_dir(Path.join(Paths.library_dir(library), Files.safe_name(base)))
  end

  @doc """
  Moves every video still in the flat layout into its own folder. Safe to run
  repeatedly. Returns `{migrated, failed}`.
  """
  def migrate_flat do
    from(v in Video,
      where: fragment("instr(substr(?, instr(?, '/') + 1), '/') = 0", v.file_path, v.file_path)
    )
    |> Repo.all()
    |> Enum.reduce({0, 0}, fn video, {ok, failed} ->
      case ensure_own_folder(video) do
        {:ok, _} ->
          {ok + 1, failed}

        {:error, reason} ->
          Logger.warning(
            "could not move video #{video.id} into its own folder: #{inspect(reason)}"
          )

          {ok, failed + 1}
      end
    end)
  end

  @doc "Moves a single flat video (and its sidecars) into its own folder."
  def ensure_own_folder(%Video{} = video) do
    video = Repo.preload(video, [:subtitles, :library], force: true)

    if own_folder?(video) do
      {:ok, video}
    else
      do_move_into_folder(video)
    end
  end

  defp do_move_into_folder(video) do
    base = video.file_path |> Path.basename() |> Path.rootname()
    dir = new_dir(%Library{slug: video.library.slug}, base)
    folder = Paths.relative(dir)
    into = fn rel -> rel && Path.join(folder, Path.basename(rel)) end

    moves = for rel <- relative_files(video), do: {rel, into.(rel)}

    case move_all(moves) do
      {:ok, moved} ->
        result =
          Repo.transaction(fn ->
            video
            |> Ecto.Changeset.change(
              file_path: into.(video.file_path),
              info_json_path: into.(video.info_json_path),
              thumbnail_path: into.(video.thumbnail_path)
            )
            |> Repo.update!()

            for s <- video.subtitles do
              from(x in Subtitle, where: x.id == ^s.id)
              |> Repo.update_all(set: [path: into.(s.path)])
            end
          end)

        case result do
          {:ok, _} ->
            {:ok, Repo.get!(Video, video.id)}

          error ->
            undo(moved)
            File.rmdir(dir)
            error
        end

      {:error, reason} ->
        File.rmdir(dir)
        {:error, reason}
    end
  end

  # Moves files one by one; the video file itself must succeed, missing
  # sidecars are tolerated. On failure everything already moved goes back.
  defp move_all([{main_from, _} | _] = moves) do
    Enum.reduce_while(moves, {:ok, []}, fn {from, to}, {:ok, done} ->
      src = Paths.absolute(from)

      cond do
        from != main_from and not File.exists?(src) ->
          {:cont, {:ok, done}}

        true ->
          case Files.move(src, Paths.absolute(to)) do
            :ok ->
              {:cont, {:ok, [{from, to} | done]}}

            {:error, reason} ->
              undo(done)
              {:halt, {:error, {from, reason}}}
          end
      end
    end)
  end

  defp undo(moved) do
    for {from, to} <- moved, do: Files.move(Paths.absolute(to), Paths.absolute(from))
    :ok
  end
end
