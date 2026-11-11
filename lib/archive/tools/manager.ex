defmodule Archive.Tools.Manager do
  @moduledoc """
  Installs and keeps the external tools up to date:

    * **yt-dlp** – the official standalone binary, downloaded from GitHub
      releases (verified against `SHA2-256SUMS`) into `<data>/bin/yt-dlp` and
      updated with `yt-dlp --update-to <channel>`.
    * **deno** – JavaScript runtime yt-dlp needs for full YouTube support,
      downloaded into `<data>/bin/deno` (verified against its `.sha256sum`)
      and updated with `deno upgrade`.

  Updates run on a schedule (`Archive.Workers.UpdateToolsWorker`), on demand
  from the Settings page, and after downloads fail with errors that usually
  mean the extractor is outdated (rate limited).
  """

  use GenServer
  require Logger

  alias Archive.{Events, Paths, Settings, Tools}
  alias Archive.Tools.Runner

  @ytdlp_release "https://github.com/yt-dlp/yt-dlp/releases/latest/download/"
  @deno_release "https://github.com/denoland/deno/releases/latest/download/"
  @failure_update_cooldown_s 3600

  # --- API -----------------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Current status of the managed tools (versions, last update…)."
  def status do
    %{
      busy: busy?(),
      managed: Tools.managed?(),
      ytdlp:
        Map.merge(Settings.tool_state(:ytdlp), %{
          "path" => current_ytdlp_path(),
          "managed_binary" => File.exists?(Tools.ytdlp_path())
        }),
      deno:
        Map.merge(Settings.tool_state(:deno), %{
          "path" => (File.exists?(Tools.deno_path()) && Tools.deno_path()) || nil
        }),
      js_runtime: Tools.js_runtime_args() |> List.last()
    }
  end

  @doc "Starts an update in the background (no-op if one is running)."
  def update_now, do: GenServer.cast(__MODULE__, {:update, :manual})

  @doc "Runs an update if the configured interval has elapsed."
  def update_if_due do
    hours = Settings.get(:ytdlp_update_interval_hours)

    due? =
      case Settings.tool_state(:ytdlp)["last_check_at"] do
        nil ->
          true

        iso ->
          case DateTime.from_iso8601(iso) do
            {:ok, at, _} -> DateTime.diff(DateTime.utc_now(), at) >= hours * 3600
            _ -> true
          end
      end

    if due?, do: GenServer.cast(__MODULE__, {:update, :scheduled})
    :ok
  end

  @doc """
  Called when a download failed with an error that suggests an outdated
  extractor. Updates at most once per hour.
  """
  def update_after_failure do
    if Tools.managed?(), do: GenServer.cast(__MODULE__, :update_after_failure)
    :ok
  end

  def busy?, do: GenServer.call(__MODULE__, :busy?)

  @doc "yt-dlp error output that typically gets fixed by updating yt-dlp."
  def outdated_error?(stderr) do
    String.contains?(stderr, [
      "Unable to extract",
      "please report this issue",
      "Please report this issue",
      "nsig extraction failed",
      "Signature extraction failed",
      "Some formats may be missing",
      "Requested format is not available",
      "No supported JavaScript runtime"
    ])
  end

  # --- GenServer -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    if Tools.managed?(), do: send(self(), :ensure_installed)
    {:ok, %{task: nil, last_failure_update: nil}}
  end

  @impl true
  def handle_call(:busy?, _from, state), do: {:reply, state.task != nil, state}

  @impl true
  def handle_cast({:update, reason}, state), do: {:noreply, start_task(state, {:update, reason})}

  def handle_cast(:update_after_failure, state) do
    now = System.monotonic_time(:second)

    if state.last_failure_update == nil or
         now - state.last_failure_update > @failure_update_cooldown_s do
      Logger.info("yt-dlp failure looks like an outdated extractor; updating yt-dlp")
      {:noreply, %{start_task(state, {:update, :failure}) | last_failure_update: now}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:ensure_installed, state), do: {:noreply, start_task(state, :ensure_installed)}

  def handle_info({ref, _result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Events.broadcast("tools", {:tools_changed})
    {:noreply, %{state | task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.error("tool maintenance task crashed: #{inspect(reason)}")
    Events.broadcast("tools", {:tools_changed})
    {:noreply, %{state | task: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_task(%{task: nil} = state, action) do
    Events.broadcast("tools", {:tools_changed})
    task = Task.Supervisor.async_nolink(Archive.TaskSupervisor, fn -> perform(action) end)
    %{state | task: task}
  end

  defp start_task(state, _action), do: state

  # --- work ----------------------------------------------------------------------

  defp perform(:ensure_installed) do
    File.mkdir_p!(Paths.bin_dir())

    unless File.exists?(Tools.ytdlp_path()), do: record(:ytdlp, install_ytdlp())
    unless File.exists?(Tools.deno_path()), do: record(:deno, install_deno())

    refresh_versions()
  end

  defp perform({:update, reason}) do
    Logger.info("updating tools (#{reason})")

    if Tools.managed?() do
      unless File.exists?(Tools.ytdlp_path()), do: record(:ytdlp, install_ytdlp())
      unless File.exists?(Tools.deno_path()), do: record(:deno, install_deno())
    end

    pause_downloads(fn ->
      if File.exists?(Tools.ytdlp_path()), do: record(:ytdlp, update_ytdlp())
      if Tools.managed?() and File.exists?(Tools.deno_path()), do: record(:deno, update_deno())
    end)

    refresh_versions()
  end

  defp pause_downloads(fun) do
    _ = safe_oban(fn -> Oban.pause_queue(queue: :downloads) end)

    try do
      fun.()
    after
      _ = safe_oban(fn -> Oban.resume_queue(queue: :downloads) end)
    end
  end

  defp safe_oban(fun) do
    fun.()
  rescue
    _ -> :error
  end

  defp record(tool, result) do
    now = DateTime.utc_now(:second) |> DateTime.to_iso8601()

    {status, message} =
      case result do
        {:ok, message} -> {"ok", message}
        {:error, message} -> {"error", to_string(message)}
      end

    if status == "error", do: Logger.warning("#{tool}: #{message}")

    Settings.put_tool_state(tool, %{
      last_check_at: now,
      last_status: status,
      last_message: String.slice(message, 0, 2000)
    })
  end

  defp refresh_versions do
    with {:ok, path} <- Tools.ytdlp(),
         {:ok, out} <- Runner.run(path, ["--version"], timeout: 30_000) do
      Settings.put_tool_state(:ytdlp, %{version: String.trim(out)})
    end

    deno = Tools.deno_path()

    with true <- File.exists?(deno),
         {:ok, out} <- Runner.run(deno, ["--version"], timeout: 30_000) do
      version = out |> String.split("\n") |> List.first() |> String.trim()
      Settings.put_tool_state(:deno, %{version: version})
    end

    :ok
  end

  defp current_ytdlp_path do
    case Tools.ytdlp() do
      {:ok, path} -> path
      _ -> nil
    end
  end

  # yt-dlp ------------------------------------------------------------------------

  defp ytdlp_asset do
    arch = :erlang.system_info(:system_architecture) |> to_string()

    cond do
      String.starts_with?(arch, "aarch64") -> "yt-dlp_linux_aarch64"
      String.starts_with?(arch, "armv7") -> "yt-dlp_linux_armv7l"
      true -> "yt-dlp_linux"
    end
  end

  defp install_ytdlp do
    asset = ytdlp_asset()

    with {:ok, sums} <- fetch_text(@ytdlp_release <> "SHA2-256SUMS"),
         {:ok, expected} <- find_checksum(sums, asset),
         {:ok, tmp} <- download(@ytdlp_release <> asset),
         :ok <- verify(tmp, expected),
         :ok <- install_binary(tmp, Tools.ytdlp_path()) do
      {:ok, "installed #{asset}"}
    else
      {:error, reason} -> {:error, "yt-dlp install failed: #{format(reason)}"}
    end
  end

  defp update_ytdlp do
    channel = Settings.get(:ytdlp_channel)

    case Runner.run(Tools.ytdlp_path(), ["--update-to", channel], timeout: 300_000) do
      {:ok, out} ->
        {:ok, out |> String.trim() |> String.split("\n") |> List.last() || "up to date"}

      {:error, error} ->
        {:error, "yt-dlp update failed: " <> Runner.format_error(error)}
    end
  end

  # deno ------------------------------------------------------------------------

  defp deno_asset do
    arch = :erlang.system_info(:system_architecture) |> to_string()

    if String.starts_with?(arch, "aarch64"),
      do: "deno-aarch64-unknown-linux-gnu.zip",
      else: "deno-x86_64-unknown-linux-gnu.zip"
  end

  defp install_deno do
    asset = deno_asset()

    with {:ok, sum} <- fetch_text(@deno_release <> asset <> ".sha256sum"),
         {:ok, expected} <- first_hash(sum),
         {:ok, zip} <- download(@deno_release <> asset),
         :ok <- verify(zip, expected),
         {:ok, dir} <- unzip(zip),
         :ok <- install_binary(Path.join(dir, "deno"), Tools.deno_path()) do
      File.rm_rf(dir)
      {:ok, "installed #{asset}"}
    else
      {:error, reason} -> {:error, "deno install failed: #{format(reason)}"}
    end
  end

  defp update_deno do
    case Runner.run(Tools.deno_path(), ["upgrade", "stable"],
           timeout: 300_000,
           env: [{"NO_COLOR", "1"}]
         ) do
      {:ok, out} -> {:ok, out |> String.trim() |> String.split("\n") |> List.last() || "ok"}
      {:error, error} -> {:error, "deno upgrade failed: " <> Runner.format_error(error)}
    end
  end

  defp unzip(zip) do
    dir = Paths.tmp_path("deno")
    File.mkdir_p!(dir)

    result =
      case :zip.unzip(String.to_charlist(zip), cwd: String.to_charlist(dir)) do
        {:ok, _files} -> {:ok, dir}
        {:error, reason} -> {:error, {:unzip, reason}}
      end

    File.rm(zip)
    result
  end

  # helpers ---------------------------------------------------------------------

  defp fetch_text(url) do
    case Req.get(url, receive_timeout: 60_000, retry: :transient, max_retries: 2) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, "HTTP #{status} for #{url}"}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end

  defp download(url) do
    tmp = Paths.tmp_path("download")

    case Req.get(url,
           into: File.stream!(tmp),
           receive_timeout: 300_000,
           decode_body: false,
           compressed: false,
           retry: :transient,
           max_retries: 2
         ) do
      {:ok, %Req.Response{status: 200}} ->
        {:ok, tmp}

      {:ok, %Req.Response{status: status}} ->
        File.rm(tmp)
        {:error, "HTTP #{status} for #{url}"}

      {:error, exception} ->
        File.rm(tmp)
        {:error, Exception.message(exception)}
    end
  end

  defp find_checksum(sums, asset) do
    sums
    |> String.split("\n", trim: true)
    |> Enum.find_value({:error, "no checksum for #{asset}"}, fn line ->
      case String.split(line, ~r/\s+\*?/, parts: 2) do
        [hash, ^asset] -> {:ok, String.downcase(hash)}
        _ -> nil
      end
    end)
  end

  defp first_hash(text) do
    case Regex.run(~r/\b([0-9a-fA-F]{64})\b/, text) do
      [_, hash] -> {:ok, String.downcase(hash)}
      _ -> {:error, "could not parse checksum"}
    end
  end

  defp verify(path, expected) do
    actual =
      path
      |> File.stream!(1024 * 1024)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if actual == expected do
      :ok
    else
      File.rm(path)
      {:error, "checksum mismatch"}
    end
  end

  defp install_binary(src, dest) do
    File.mkdir_p!(Path.dirname(dest))
    tmp_dest = dest <> ".new"

    with {:ok, _} <- File.copy(src, tmp_dest),
         :ok <- File.chmod(tmp_dest, 0o755),
         :ok <- File.rename(tmp_dest, dest) do
      File.rm(src)
      :ok
    end
  end

  defp format(reason) when is_binary(reason), do: reason
  defp format(reason), do: inspect(reason)
end
