defmodule Archive.Media.Thumbs do
  @moduledoc """
  Grid thumbnails: small (480 px wide) JPEGs cached in the data dir, generated
  from the full-size thumbnail sidecar or, failing that, from a video frame.
  """

  alias Archive.{Paths, Tools}
  alias Archive.Tools.Runner

  @width 480

  @doc "Generates the grid thumbnail for a video. Returns `:ok` or `{:error, _}`."
  def generate(video) do
    dest = Paths.grid_thumb(video.id)
    File.mkdir_p!(Path.dirname(dest))

    source = video.thumbnail_path && Paths.absolute(video.thumbnail_path)

    if source && File.exists?(source) do
      scale(source, dest)
    else
      from_frame(Paths.absolute(video.file_path), video.duration, dest)
    end
  end

  @doc "Ensures the grid thumbnail exists (used lazily when serving)."
  def ensure(video) do
    path = Paths.grid_thumb(video.id)

    cond do
      File.exists?(path) -> {:ok, path}
      generate(video) == :ok -> {:ok, path}
      true -> :error
    end
  end

  defp scale(source, dest) do
    args =
      ["-y", "-v", "error", "-i", source, "-vf", "scale=#{@width}:-2", "-frames:v", "1"] ++
        ["-q:v", "4", dest]

    case Runner.run(Tools.ffmpeg(), args, timeout: 60_000, collect: false) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc "Extracts a frame at 10% of the duration as a full-size JPEG."
  def extract_frame(video_path, duration, dest) do
    at = if is_number(duration) and duration > 0, do: duration * 0.1, else: 5

    args =
      ["-y", "-v", "error", "-ss", to_string(at), "-i", video_path] ++
        ["-frames:v", "1", "-q:v", "3", dest]

    # Seeking past the end (wrong duration metadata, very short videos) yields
    # no frame: fall back to the first frame.
    with {:ok, _} <- Runner.run(Tools.ffmpeg(), args, timeout: 120_000, collect: false),
         true <- File.exists?(dest) do
      :ok
    else
      _ -> retry_first_frame(video_path, dest)
    end
  end

  defp retry_first_frame(video_path, dest) do
    args = ["-y", "-v", "error", "-i", video_path, "-frames:v", "1", "-q:v", "3", dest]

    case Runner.run(Tools.ffmpeg(), args, timeout: 120_000, collect: false) do
      {:ok, _} -> if File.exists?(dest), do: :ok, else: {:error, :no_frame}
      error -> error
    end
  end

  defp from_frame(video_path, duration, dest) do
    tmp = Paths.tmp_path("frame") <> ".jpg"

    try do
      with :ok <- extract_frame(video_path, duration, tmp) do
        scale(tmp, dest)
      end
    after
      File.rm(tmp)
    end
  end
end
