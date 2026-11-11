defmodule Archive.Media.Probe do
  @moduledoc "Inspects media files with ffprobe and decides how they can be played."

  alias Archive.Tools
  alias Archive.Tools.Runner

  defstruct [:container, :vcodec, :acodec, :width, :height, :fps, :duration, :size]

  @doc "Probes a file. Returns `{:ok, %Probe{}}` or `{:error, reason}`."
  def probe(path) do
    args = ~w(-v error -print_format json -show_format -show_streams) ++ [path]

    with {:ok, json} <- Runner.run_json(Tools.ffprobe(), args, timeout: 60_000) do
      {:ok, parse(json, path)}
    end
  end

  def parse(json, path \\ "") do
    streams = Map.get(json, "streams", [])
    format = Map.get(json, "format", %{})

    video =
      Enum.find(streams, fn s ->
        s["codec_type"] == "video" and get_in(s, ["disposition", "attached_pic"]) != 1
      end)

    audio = Enum.find(streams, &(&1["codec_type"] == "audio"))

    %__MODULE__{
      container: container(format["format_name"], path),
      vcodec: video && video["codec_name"],
      acodec: audio && audio["codec_name"],
      width: video && video["width"],
      height: video && video["height"],
      fps: video && parse_rate(video["avg_frame_rate"] || video["r_frame_rate"]),
      duration: parse_float(format["duration"] || (video && video["duration"])),
      size: parse_int(format["size"])
    }
  end

  # ffprobe reports e.g. "mov,mp4,m4a,3gp,3g2,mj2" or "matroska,webm"; the file
  # extension disambiguates.
  defp container(nil, path), do: ext(path)

  defp container(names, path) do
    names = String.split(names, ",")
    ext = ext(path)

    cond do
      ext in names -> ext
      ext == "mkv" and "matroska" in names -> "mkv"
      ext in ["m4v", "mov"] and "mov" in names -> ext
      true -> List.first(names)
    end
  end

  defp ext(path), do: path |> Path.extname() |> String.trim_leading(".") |> String.downcase()

  @direct_containers ~w(mp4 m4v mov webm)
  @direct_video ~w(h264 vp8 vp9 av1)
  @direct_audio ~w(aac mp3 opus vorbis flac)

  @doc """
  `"direct"` when common browsers can play the file as-is, otherwise
  `"transcode"` (served through on-the-fly HLS).
  """
  def playback_mode(%__MODULE__{container: c, vcodec: v, acodec: a}) do
    container_ok = c in @direct_containers
    video_ok = v == nil or v in @direct_video
    audio_ok = a == nil or a in @direct_audio
    # webm only carries vp8/vp9/av1 + vorbis/opus, which is always fine.
    if container_ok and video_ok and audio_ok, do: "direct", else: "transcode"
  end

  @doc "MIME type to use when serving the file directly."
  def mime_type(path) do
    case ext(path) do
      "mp4" -> "video/mp4"
      "m4v" -> "video/mp4"
      "mov" -> "video/quicktime"
      "webm" -> "video/webm"
      "mkv" -> "video/x-matroska"
      "avi" -> "video/x-msvideo"
      "flv" -> "video/x-flv"
      "ts" -> "video/mp2t"
      "wmv" -> "video/x-ms-wmv"
      "mpg" -> "video/mpeg"
      "mpeg" -> "video/mpeg"
      "m4a" -> "audio/mp4"
      "mp3" -> "audio/mpeg"
      "opus" -> "audio/ogg"
      "ogg" -> "audio/ogg"
      _ -> "application/octet-stream"
    end
  end

  defp parse_rate(nil), do: nil

  defp parse_rate(rate) do
    case String.split(rate, "/") do
      [n, d] ->
        with {n, _} <- Float.parse(n), {d, _} <- Float.parse(d), true <- d > 0 do
          Float.round(n / d, 3)
        else
          _ -> nil
        end

      _ ->
        parse_float(rate)
    end
  end

  defp parse_float(nil), do: nil
  defp parse_float(v) when is_number(v), do: v / 1

  defp parse_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(v) when is_integer(v), do: v

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, _} -> i
      :error -> nil
    end
  end
end
