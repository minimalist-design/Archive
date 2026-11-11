defmodule Archive.Importer do
  @moduledoc """
  Imports video files that already exist on the server.

  Metadata comes from (in order):

    1. a `<name>.info.json` sidecar (any yt-dlp supported site),
    2. a YouTube id found in the filename, looked up with yt-dlp,
    3. the cleaned-up filename as title.

  Files and their sidecars are **moved** into the library folder.
  """

  import Ecto.Query
  require Logger

  alias Archive.{Files, Ingest, Paths, Repo, Videos, YtDlp}
  alias Archive.Media.Vtt
  alias Archive.Videos.Video

  @video_exts ~w(.mp4 .mkv .webm .mov .m4v .avi .flv .ts .wmv .mpg .mpeg .3gp .ogv)
  @max_scan 5_000

  def video_extensions, do: @video_exts

  # --- scanning -----------------------------------------------------------------

  @doc """
  Lists importable video files under `dir` (recursively) with what was
  detected for each. Returns `{:ok, entries}` or `{:error, message}`.
  """
  def scan(dir) do
    dir = Path.expand(String.trim(dir))

    cond do
      not File.dir?(dir) ->
        {:error, "#{dir} is not a directory"}

      true ->
        files = dir |> walk([]) |> Enum.take(@max_scan) |> Enum.sort()
        tracked = tracked_paths(files)
        {:ok, Enum.map(files, &describe(&1, tracked))}
    end
  end

  defp walk(dir, acc) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.reduce(names, acc, fn name, acc ->
          path = Path.join(dir, name)

          cond do
            String.starts_with?(name, ".") -> acc
            File.dir?(path) -> walk(path, acc)
            String.downcase(Path.extname(name)) in @video_exts -> [path | acc]
            true -> acc
          end
        end)

      {:error, _} ->
        acc
    end
  end

  # Files already inside the storage dir that belong to an archived video.
  defp tracked_paths(files) do
    storage = Path.expand(Paths.storage_dir()) <> "/"

    rels =
      for f <- files, String.starts_with?(f, storage), do: String.replace_prefix(f, storage, "")

    rels
    |> Enum.chunk_every(500)
    |> Enum.flat_map(fn chunk ->
      Repo.all(from v in Video, where: v.file_path in ^chunk, select: v.file_path)
    end)
    |> Enum.map(&(storage <> &1))
    |> MapSet.new()
  end

  defp describe(path, tracked) do
    name = Path.basename(path)
    sidecars = Ingest.sidecars(path)
    info = Ingest.read_info_json(sidecars.info_json)
    youtube_id = if info, do: nil, else: detect_youtube_id(name)

    {source, title} =
      cond do
        info -> {:info_json, info["title"] || clean_title(name)}
        youtube_id -> {:youtube_id, clean_title(name)}
        true -> {:filename, clean_title(name)}
      end

    duplicate =
      cond do
        MapSet.member?(tracked, path) ->
          "already in the archive"

        info && Videos.find_by_remote(info["extractor_key"], info["id"]) ->
          "already archived"

        youtube_id && Videos.find_by_remote("Youtube", youtube_id) ->
          "already archived"

        true ->
          nil
      end

    size =
      case File.stat(path) do
        {:ok, %{size: size}} -> size
        _ -> nil
      end

    %{
      path: path,
      name: name,
      size: size,
      title: title,
      source: source,
      remote_id: (info && info["id"]) || youtube_id,
      has_thumbnail: sidecars.thumbnail != nil,
      subtitle_count: length(sidecars.subtitles),
      duplicate: duplicate
    }
  end

  # --- filename heuristics -------------------------------------------------------

  @id ~S"[A-Za-z0-9_-]{11}"

  @doc """
  Finds a YouTube video id in a filename:

    * `Title [dQw4w9WgXcQ].mp4` (yt-dlp default)
    * `Title-dQw4w9WgXcQ.mp4` (old youtube-dl default)
    * a standalone 11-character token that looks random enough
  """
  def detect_youtube_id(filename) do
    base = Path.rootname(Path.basename(filename))

    bracketed = Regex.run(~r/\[(#{@id})\]/, base, capture: :all_but_first)
    dashed = Regex.run(~r/-(#{@id})$/, base, capture: :all_but_first)

    standalone =
      Regex.scan(~r/(?:^|[\s.()\[\]])(#{@id})(?=$|[\s.()\[\]])/, base, capture: :all_but_first)
      |> List.flatten()

    cond do
      bracketed -> hd(bracketed)
      dashed && random_looking?(hd(dashed)) -> hd(dashed)
      true -> Enum.find(standalone, &random_looking?/1)
    end
  end

  # Real ids are random base64url strings: they almost always contain digits
  # or several uppercase letters mixed with lowercase ones. Words like
  # "video-final" or "Masterpiece" don't qualify.
  defp random_looking?(token) do
    upper = length(Regex.scan(~r/[A-Z]/, token))
    lower = length(Regex.scan(~r/[a-z]/, token))
    digits = length(Regex.scan(~r/[0-9]/, token))

    cond do
      digits == 11 -> false
      digits > 0 and (upper > 0 or lower > 0) -> true
      upper >= 2 and lower >= 2 -> true
      true -> false
    end
  end

  @junk ~r/^(?:\d{3,4}p|4k|8k|uhd|hd|hdr|sdr|x26[45]|h\.?26[45]|hevc|av1|vp9|aac|ac3|opus|webrip|web-?dl|bluray|brrip|hdtv|dvdrip|\d{2,3}fps|60fps)$/i

  @doc """
  Turns a filename into a human readable title. With `strip_id: false` a
  detected video id is kept (used when the id turned out not to be one).
  """
  def clean_title(filename, opts \\ []) do
    base = Path.rootname(Path.basename(filename))
    id = if Keyword.get(opts, :strip_id, true), do: detect_youtube_id(filename)

    base =
      if id do
        base
        |> String.replace("[#{id}]", "")
        |> String.replace(~r/-#{Regex.escape(id)}$/, "")
        |> String.replace(~r/(^|[\s.()\[\]])#{Regex.escape(id)}(?=$|[\s.()\[\]])/, "\\1")
      else
        base
      end

    # Remove bracketed groups that only contain technical junk.
    base =
      Regex.replace(~r/[\[(]([^\])]*)[\])]/, base, fn whole, inner ->
        parts = String.split(inner, ~r/[\s,._]+/, trim: true)
        if parts != [] and Enum.all?(parts, &Regex.match?(@junk, &1)), do: "", else: whole
      end)

    # Scene-style names ("Some.Video.Name.2020", "My_Clip.Name") use dots as
    # separators; dots in names that have real spaces are kept ("Mr. Smith").
    scene_style? = not String.contains?(String.trim(base), " ")
    base = String.replace(base, "_", " ")
    base = if scene_style?, do: String.replace(base, ".", " "), else: base

    base
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.trim(" -_.")
    |> case do
      "" -> Path.rootname(Path.basename(filename))
      title -> title
    end
  end

  # --- importing a file ------------------------------------------------------------

  @doc """
  Imports one file into `library`. Returns `{:ok, video}`,
  `{:skipped, note, video_id}` or `{:error, message}`.
  """
  def import_file(path, library, category_ids \\ []) do
    with :ok <- check_exists(path),
         sidecars = Ingest.sidecars(path),
         {info, lookup_note} = metadata(path, sidecars),
         :ok <- check_duplicate(path, info) do
      do_import(path, library, category_ids, sidecars, info, lookup_note)
    end
  end

  defp check_exists(path) do
    if File.regular?(path), do: :ok, else: {:error, "file not found: #{path}"}
  end

  defp metadata(path, sidecars) do
    case Ingest.read_info_json(sidecars.info_json) do
      %{} = info ->
        {info, nil}

      nil ->
        case detect_youtube_id(path) do
          nil ->
            {nil, nil}

          id ->
            case YtDlp.extract_info("https://www.youtube.com/watch?v=#{id}") do
              {:ok, %{"id" => ^id} = info} ->
                {Map.put(info, "_archive_fetched", true), nil}

              _ ->
                {%{"_archive_title" => clean_title(path, strip_id: false)},
                 "no metadata found for YouTube id #{id}"}
            end
        end
    end
  end

  defp check_duplicate(path, info) do
    storage = Path.expand(Paths.storage_dir()) <> "/"
    expanded = Path.expand(path)

    tracked =
      String.starts_with?(expanded, storage) &&
        Repo.one(
          from v in Video,
            where: v.file_path == ^String.replace_prefix(expanded, storage, ""),
            select: v.id
        )

    cond do
      tracked ->
        {:skipped, "already in the archive", tracked}

      video = info && Videos.find_by_remote(info["extractor_key"], info["id"]) ->
        {:skipped, "already archived in library ##{video.library_id}", video.id}

      true ->
        :ok
    end
  end

  defp do_import(path, library, category_ids, sidecars, info, lookup_note) do
    lib_dir = Paths.library_dir(library)
    File.mkdir_p!(lib_dir)

    {fallback_title, info} =
      case info do
        %{"_archive_title" => title} -> {title, nil}
        info -> {clean_title(path), info}
      end

    ext = String.downcase(Path.extname(path))

    base =
      case info do
        %{"id" => id} = info when is_binary(id) ->
          Files.safe_name(info["title"] || fallback_title) <> " [#{Files.safe_name(id, 60)}]"

        _ ->
          Files.safe_name(fallback_title)
      end

    dest = Files.unique_path(Path.join(lib_dir, base <> ext))
    new_base = Path.rootname(dest)
    old_base = Path.rootname(path)

    case Files.move(path, dest) do
      :ok ->
        moved_sidecars = move_sidecars(sidecars, old_base, new_base)

        result =
          finish_import(
            library,
            dest,
            new_base,
            info,
            moved_sidecars,
            category_ids,
            fallback_title
          )

        case result do
          {:ok, video} ->
            {:ok, video, lookup_note}

          {:error, reason} ->
            # Put the main file back where it was so nothing is lost.
            Files.move(dest, path)
            {:error, format_error(reason)}
        end

      {:error, reason} ->
        {:error, "could not move file: #{inspect(reason)}"}
    end
  end

  defp move_sidecars(sidecars, old_base, new_base) do
    move = fn src ->
      dest = new_base <> String.replace_prefix(src, old_base, "")

      case Files.move(src, dest) do
        :ok -> dest
        _ -> nil
      end
    end

    subtitles =
      sidecars.subtitles
      |> Enum.map(fn s -> %{s | path: move.(s.path)} end)
      |> Enum.reject(&is_nil(&1.path))
      |> Enum.map(&ensure_vtt/1)
      |> Enum.reject(&is_nil(&1.path))

    %{
      info_json: sidecars.info_json && move.(sidecars.info_json),
      thumbnail: sidecars.thumbnail && move.(sidecars.thumbnail),
      subtitles: subtitles
    }
  end

  defp ensure_vtt(%{path: path} = sub) do
    if Path.extname(path) == ".srt" do
      vtt = Path.rootname(path) <> ".vtt"

      with {:ok, content} <- File.read(path),
           :ok <- File.write(vtt, Vtt.srt_to_vtt(content)) do
        File.rm(path)
        %{sub | path: vtt}
      else
        _ -> sub
      end
    else
      sub
    end
  end

  defp finish_import(library, dest, new_base, info, sidecars, category_ids, fallback_title) do
    sidecars =
      if info && info["_archive_fetched"] do
        fetch_remote_sidecars(dest, new_base, Map.delete(info, "_archive_fetched"), sidecars)
      else
        sidecars
      end

    info = info && Map.delete(info, "_archive_fetched")

    Ingest.create(library, dest, info,
      info_json: sidecars.info_json,
      thumbnail: sidecars.thumbnail,
      subtitles:
        Ingest.tag_auto_subtitles(
          Enum.map(sidecars.subtitles, &Map.take(&1, [:lang, :path])),
          info
        ),
      category_ids: category_ids,
      title: fallback_title
    )
  end

  # The file was identified by its YouTube id: save the metadata next to it and
  # fetch the thumbnail and subtitles that are missing locally.
  defp fetch_remote_sidecars(dest, new_base, info, sidecars) do
    info_json = new_base <> ".info.json"
    File.write!(info_json, Jason.encode!(info))

    need_thumb = sidecars.thumbnail == nil
    need_subs = sidecars.subtitles == []

    if need_thumb or need_subs do
      sub_langs = if need_subs, do: YtDlp.sub_langs(info), else: nil

      case YtDlp.fetch_sidecars(info_json, new_base, sub_langs) do
        {:ok, _} ->
          :ok

        {:error, error} ->
          Logger.warning("could not fetch thumbnail/subtitles: #{inspect(error)}")
      end
    end

    fresh = Ingest.sidecars(dest)

    %{
      info_json: info_json,
      thumbnail: sidecars.thumbnail || fresh.thumbnail,
      subtitles: if(need_subs, do: fresh.subtitles, else: sidecars.subtitles)
    }
  end

  defp format_error(%Ecto.Changeset{} = cs), do: inspect(cs.errors)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
