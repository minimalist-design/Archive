defmodule Archive.Tools.Runner do
  @moduledoc """
  Runs external programs (yt-dlp, ffmpeg, ffprobe) under MuonTrap, which makes
  sure the OS process is killed if the owning Elixir process dies (job cancel,
  shutdown, crash).

  stdout is streamed line by line to an optional callback and/or collected;
  stderr is written to a temp file whose tail is returned on failure.
  """

  require Logger
  alias Archive.Tools.LineCollector

  @stderr_tail_lines 25

  @type result :: {:ok, binary()} | {:error, {:exit, integer(), binary()}}

  @doc """
  Options:
    * `:on_line` – `fn line -> ... end` called for every stdout line
    * `:collect` – keep stdout and return it (default `true`)
    * `:timeout` – milliseconds (default: none)
    * `:cd`, `:env`
  """
  @spec run(String.t(), [String.t()], keyword()) :: result
  def run(executable, args, opts \\ []) do
    stderr_path = Archive.Paths.tmp_path("stderr")
    collector = LineCollector.new(opts[:on_line], keep: Keyword.get(opts, :collect, true))

    cmd_opts =
      [
        into: collector,
        env: [{"ARCHIVE_STDERR", stderr_path} | Keyword.get(opts, :env, [])],
        delay_to_sigkill: 2_000
      ]
      |> maybe_put(:cd, opts[:cd])
      |> maybe_put(:timeout, opts[:timeout])

    Logger.debug("run: #{executable} #{Enum.join(args, " ")}")

    # `exec` replaces the shell, so MuonTrap supervises the program itself.
    script = ~S(exec "$0" "$@" 2>"$ARCHIVE_STDERR")

    try do
      {collector, status} = MuonTrap.cmd("/bin/sh", ["-c", script, executable | args], cmd_opts)
      output = LineCollector.finish(collector)

      case status do
        0 -> {:ok, output}
        {:error, :timeout} -> {:error, {:exit, :timeout, stderr_tail(stderr_path)}}
        code -> {:error, {:exit, code, stderr_tail(stderr_path)}}
      end
    after
      File.rm(stderr_path)
    end
  end

  @doc "Like `run/3` but decodes stdout as JSON."
  def run_json(executable, args, opts \\ []) do
    with {:ok, output} <- run(executable, args, opts) do
      case Jason.decode(output) do
        {:ok, json} -> {:ok, json}
        {:error, _} -> {:error, {:exit, 0, "could not parse JSON output"}}
      end
    end
  end

  def format_error({:exit, code, stderr}) do
    stderr = String.trim(stderr)
    if stderr == "", do: "exited with status #{inspect(code)}", else: stderr
  end

  def format_error(other), do: inspect(other)

  defp stderr_tail(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split(~r/\r\n|\n|\r/, trim: true)
        |> Enum.take(-@stderr_tail_lines)
        |> Enum.join("\n")

      _ ->
        ""
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
