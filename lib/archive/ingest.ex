defmodule Archive.Ingest do
  @moduledoc """
  Turns a media file on disk (inside the storage dir) plus optional yt-dlp
  metadata and sidecars into an archived `Video`. Shared by downloads and
  imports.
  """

  require Logger

  alias Archive.{Paths, Videos}
  alias Archive.Media.{Probe, Thumbs}

  @metadata_keys ~w(id title fulltitle uploader uploader_id uploader_url channel channel_id
    channel_url channel_follower_count view_count like_count comment_count upload_date
    timestamp release_date release_timestamp duration duration_string categories tags
    age_limit webpage_url original_url extractor extractor_key playlist playlist_id
    playlist_title playlist_index chapters language availability live_status was_live
    resolution format format_note ext width height fps vcodec acodec dynamic_range
    series season season_number episode episode_number track artist album creator
    location display_id)

  @doc """
  Creates the video record.

    * `library` – target library
    * `file` – absolute path of the media file (inside the library folder)
    * `info` – yt-dlp info dict (or `nil` for unidentified local files)
    * `opts` – `:info_json`, `:thumbnail` (absolute paths), `:subtitles`
      (`[%{lang:, auto:, path: absolute}]`), `:category_ids`, `:title`
      (fallback title)
  """
  def create(library, file, info, opts \\ []) do
    probe =
      case Probe.probe(file) do
        {:ok, probe} ->
          probe

        {:error, error} ->
          Logger.warning("ffprobe failed for #{file}: #{inspect(error)}")
          %Probe{container: file |> Path.extname() |> String.trim_leading(".")}
      end

    info = info || %{}

    attrs =
      %{
        extractor_key: info["extractor_key"] || (info["id"] && info["extractor"]) || "local",
        remote_id: info["id"],
        webpage_url: info["webpage_url"] || info["original_url"],
        title: present(info["title"]) || opts[:title] || Path.rootname(Path.basename(file)),
        description: present(info["description"]),
        uploader: present(info["uploader"]) || present(info["creator"]),
        channel: present(info["channel"]),
        upload_date: parse_date(info["upload_date"] || info["release_date"]),
        duration: round_duration(probe.duration || info["duration"]),
        tags: tags(info),
        language: present(info["language"]),
        width: probe.width || info["width"],
        height: probe.height || info["height"],
        fps: probe.fps || info["fps"],
        vcodec: probe.vcodec,
        acodec: probe.acodec,
        container: probe.container,
        filesize: probe.size || file_size(file),
        file_path: Paths.relative(file),
        info_json_path: rel(opts[:info_json]),
        thumbnail_path: rel(opts[:thumbnail]),
        playback: Probe.playback_mode(probe),
        status: "ready",
        metadata: Map.take(info, @metadata_keys),
        downloaded_at: DateTime.utc_now(:second)
      }

    subtitles =
      for s <- Keyword.get(opts, :subtitles, []), do: %{s | path: Paths.relative(s.path)}

    with {:ok, video} <-
           Videos.create_video(library, attrs,
             category_ids: Keyword.get(opts, :category_ids, []),
             subtitles: subtitles
           ) do
      case Thumbs.generate(video) do
        :ok ->
          :ok

        error ->
          Logger.warning("thumbnail generation failed for video #{video.id}: #{inspect(error)}")
      end

      {:ok, video}
    end
  end

  @doc """
  Finds the sidecar files yt-dlp (or another tool) wrote next to `file`:
  `<base>.info.json`, `<base>.{jpg,webp,png}`, `<base>.<lang>.{vtt,srt}`.
  """
  def sidecars(file) do
    dir = Path.dirname(file)
    base = Path.rootname(Path.basename(file))

    files =
      case File.ls(dir) do
        {:ok, names} ->
          Enum.filter(
            names,
            &(String.starts_with?(&1, base <> ".") and &1 != Path.basename(file))
          )

        _ ->
          []
      end

    info_json = Enum.find(files, &(&1 == base <> ".info.json"))

    thumbnail =
      Enum.find_value(~w(jpg jpeg webp png), fn ext ->
        Enum.find(files, &(&1 == "#{base}.#{ext}"))
      end)

    subtitles =
      files
      |> Enum.filter(&(Path.extname(&1) in [".vtt", ".srt"]))
      |> Enum.map(fn name ->
        lang =
          name
          |> String.replace_prefix(base <> ".", "")
          |> Path.rootname()
          |> case do
            "" -> "und"
            lang -> lang
          end

        %{lang: lang, path: Path.join(dir, name)}
      end)

    %{
      info_json: info_json && Path.join(dir, info_json),
      thumbnail: thumbnail && Path.join(dir, thumbnail),
      subtitles: subtitles
    }
  end

  @doc "Marks subtitles as auto-generated when they aren't among the manual ones."
  def tag_auto_subtitles(subtitles, info) do
    manual = info |> Kernel.||(%{}) |> Map.get("subtitles", %{}) |> Kernel.||(%{}) |> Map.keys()
    Enum.map(subtitles, &Map.put(&1, :auto, manual != [] and &1.lang not in manual))
  end

  def read_info_json(nil), do: nil

  def read_info_json(path) do
    with {:ok, content} <- File.read(path),
         {:ok, %{} = info} <- Jason.decode(content) do
      info
    else
      _ -> nil
    end
  end

  defp file_size(file) do
    case File.stat(file) do
      {:ok, %{size: size}} -> size
      _ -> nil
    end
  end

  defp rel(nil), do: nil
  defp rel(path), do: Paths.relative(path)

  defp present(nil), do: nil

  defp present(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      v -> v
    end
  end

  defp present(_), do: nil

  defp tags(info) do
    (List.wrap(info["tags"]) ++ List.wrap(info["categories"]))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.take(100)
  end

  defp parse_date(<<y::binary-size(4), m::binary-size(2), d::binary-size(2)>>) do
    case Date.from_iso8601("#{y}-#{m}-#{d}") do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  defp round_duration(nil), do: nil
  defp round_duration(d) when is_number(d), do: round(d)
  defp round_duration(_), do: nil
end
