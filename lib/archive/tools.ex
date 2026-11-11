defmodule Archive.Tools do
  @moduledoc "Locations of the external programs the archive uses."

  alias Archive.Paths

  defp config(key), do: Keyword.get(Application.get_env(:archive, :tools, []), key)

  @doc "Whether the app downloads and updates yt-dlp/deno itself."
  def managed?, do: config(:manage_tools) != false

  def ytdlp_path, do: config(:ytdlp) || Path.join(Paths.bin_dir(), "yt-dlp")
  def deno_path, do: config(:deno) || Path.join(Paths.bin_dir(), "deno")

  def ffmpeg, do: config(:ffmpeg) || System.find_executable("ffmpeg") || "ffmpeg"
  def ffprobe, do: config(:ffprobe) || System.find_executable("ffprobe") || "ffprobe"

  @doc """
  The yt-dlp binary to run: the managed one if installed, otherwise one found
  on PATH.
  """
  def ytdlp do
    path = ytdlp_path()

    cond do
      File.exists?(path) -> {:ok, path}
      exe = System.find_executable("yt-dlp") -> {:ok, exe}
      true -> {:error, :ytdlp_not_installed}
    end
  end

  @doc "Extra yt-dlp arguments that enable the JavaScript runtime (for YouTube)."
  def js_runtime_args do
    deno = deno_path()

    cond do
      File.exists?(deno) -> ["--js-runtimes", "deno:" <> deno]
      exe = System.find_executable("deno") -> ["--js-runtimes", "deno:" <> exe]
      exe = System.find_executable("node") -> ["--js-runtimes", "node:" <> exe]
      true -> []
    end
  end
end
