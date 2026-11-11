defmodule Archive.YtDlp do
  @moduledoc "Builds and runs yt-dlp commands."

  alias Archive.{Settings, Tools}
  alias Archive.Tools.Runner

  @progress_prefix "ARCHIVE-PROGRESS "
  @file_prefix "ARCHIVE-FILE "

  @doc "Full metadata for a single video (`-J --no-playlist`)."
  def extract_info(url, opts \\ []) do
    run_json(
      ["-J", "--no-playlist", "--no-warnings"] ++ Keyword.get(opts, :args, []) ++ ["--", url]
    )
  end

  @doc "Flat listing of a URL: a single video's info or a playlist's entries."
  def flat_info(url) do
    run_json(["-J", "--flat-playlist", "--no-warnings", "--", url])
  end

  @doc """
  Downloads a video described by an info JSON file into `output_dir`.

  `on_progress` receives maps with `:downloaded_bytes`, `:total_bytes`,
  `:speed`, `:eta`, `:status`. Returns `{:ok, final_file_path, warning}`
  where `warning` is `nil` or the error output of a non-fatal problem (e.g. a
  subtitle track that could not be fetched).
  """
  def download(info_json_path, output_dir, sub_langs, on_progress) do
    template = Path.join(output_dir, "%(title).150B [%(id)s].%(ext)s")

    subtitle_args =
      case sub_langs do
        nil ->
          []

        langs ->
          ~w(--write-subs --write-auto-subs --convert-subs vtt --sub-langs) ++ [langs]
      end

    args =
      [
        "--load-info-json",
        info_json_path,
        "-f",
        "bv*+ba/b",
        "-o",
        template,
        "--windows-filenames",
        "--no-overwrites",
        "--write-info-json",
        "--write-thumbnail",
        "--convert-thumbnails",
        "jpg",
        "--newline",
        "--progress-delta",
        "1",
        "--progress-template",
        "download:" <> @progress_prefix <> "%(progress)j",
        "--print",
        "after_move:" <> @file_prefix <> "%(filepath)s",
        "--no-simulate",
        "--no-playlist",
        # Subtitle/thumbnail failures (e.g. HTTP 429 on captions) must not
        # abort the video download; real failures are detected below.
        "--ignore-errors"
      ] ++ subtitle_args

    parent = self()
    ref = make_ref()

    on_line = fn line ->
      cond do
        String.starts_with?(line, @progress_prefix) ->
          with {:ok, %{} = p} <- Jason.decode(String.replace_prefix(line, @progress_prefix, "")) do
            on_progress.(%{
              status: p["status"],
              downloaded_bytes: p["downloaded_bytes"],
              total_bytes: p["total_bytes"] || p["total_bytes_estimate"],
              speed: p["speed"],
              eta: p["eta"],
              filename: p["filename"]
            })
          end

        String.starts_with?(line, @file_prefix) ->
          send(parent, {ref, :file, String.replace_prefix(line, @file_prefix, "")})

        true ->
          :ok
      end
    end

    result = run(args, on_line: on_line, collect: false)

    file =
      receive do
        {^ref, :file, path} -> path
      after
        0 -> nil
      end

    case {result, file} do
      {{:ok, _}, file} when is_binary(file) ->
        {:ok, file, nil}

      {{:ok, _}, nil} ->
        {:error, {:exit, 0, "yt-dlp did not report the output file"}}

      {{:error, {:exit, _code, stderr}}, file} when is_binary(file) ->
        if File.regular?(file), do: {:ok, file, stderr}, else: result

      {error, _} ->
        error
    end
  end

  @doc """
  Fetches only the thumbnail and subtitles for a known video (used by imports
  that identified a video id). Files are written as `<base>.*`.
  """
  def fetch_sidecars(info_json_path, base_path, sub_langs) do
    subtitle_args =
      if sub_langs,
        do: ~w(--write-subs --write-auto-subs --convert-subs vtt --sub-langs) ++ [sub_langs],
        else: []

    args =
      [
        "--load-info-json",
        info_json_path,
        "--skip-download",
        "--ignore-errors",
        "--write-thumbnail",
        "--convert-thumbnails",
        "jpg",
        "-o",
        String.replace(base_path, "%", "%%") <> ".%(ext)s"
      ] ++ subtitle_args

    run(args, collect: false)
  end

  @doc """
  The `--sub-langs` value for a video according to the subtitle setting, or
  `nil` when subtitles are disabled.
  """
  def sub_langs(info, mode \\ Settings.get(:subtitle_mode)) do
    original =
      case info && info["language"] do
        lang when is_binary(lang) and lang != "" -> lang |> String.split(["-", "_"]) |> hd()
        _ -> nil
      end

    langs =
      case mode do
        "none" -> []
        "en" -> ["en"]
        "original" -> [original || "en"]
        _ -> Enum.uniq(Enum.reject([original, "en"], &is_nil/1))
      end

    case langs do
      [] -> nil
      langs -> Enum.map_join(langs, ",", &(Regex.escape(&1) <> "(-.*)?")) <> ",-live_chat"
    end
  end

  defp run_json(args) do
    with {:ok, bin} <- Tools.ytdlp() do
      Runner.run_json(bin, common_args() ++ args, timeout: 600_000)
    end
  end

  defp run(args, opts) do
    with {:ok, bin} <- Tools.ytdlp() do
      Runner.run(bin, common_args() ++ args, opts)
    end
  end

  defp common_args do
    extra =
      case Settings.get(:extra_ytdlp_args) do
        args when is_binary(args) and args != "" -> OptionParser.split(args)
        _ -> []
      end

    ["--ignore-config", "--no-color"] ++ Tools.js_runtime_args() ++ extra
  end
end
