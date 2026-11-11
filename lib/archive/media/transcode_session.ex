defmodule Archive.Media.TranscodeSession do
  @moduledoc """
  On-the-fly HLS transcoding for files browsers can't play natively.

  The player gets a complete VOD playlist up front (fixed #{6}-second
  segments computed from the duration), so seeking works like a normal video.
  Segments are produced by one ffmpeg process per video:

    * a segment that already exists is served immediately;
    * a segment just ahead of the encoder waits for it;
    * anything else (a seek) restarts ffmpeg at that segment.

  Keyframes are forced on segment boundaries and output timestamps are offset
  to the segment start, so segments from different ffmpeg runs line up.
  Sessions stop after a minute without requests and delete their files.
  """

  use GenServer, restart: :temporary
  require Logger

  alias Archive.{Paths, Settings, Tools}
  alias Archive.Tools.Runner

  @segment_seconds 6
  @lookahead 4
  @idle_timeout_ms 60_000
  @poll_ms 150
  @wait_timeout_ms 90_000

  def segment_seconds, do: @segment_seconds

  # --- playlist -------------------------------------------------------------------

  @doc "The VOD playlist for a video of `duration` seconds."
  def playlist(duration) when is_number(duration) and duration > 0 do
    count = segment_count(duration)

    segments =
      for i <- 0..(count - 1) do
        length =
          if i == count - 1, do: duration - i * @segment_seconds, else: @segment_seconds

        "#EXTINF:#{:erlang.float_to_binary(length / 1, decimals: 6)},\n#{i}.ts\n"
      end

    [
      "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:#{@segment_seconds}\n",
      "#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n",
      segments,
      "#EXT-X-ENDLIST\n"
    ]
    |> IO.iodata_to_binary()
  end

  def segment_count(duration), do: max(1, ceil(duration / @segment_seconds))

  # --- API -----------------------------------------------------------------------

  @doc """
  Returns `{:ok, path}` of segment `index` for `video`, starting or steering
  the transcoder as needed.
  """
  def segment(video, index) do
    with {:ok, pid} <- ensure_started(video) do
      try do
        GenServer.call(pid, {:segment, index}, @wait_timeout_ms)
      catch
        :exit, reason -> {:error, {:session_exit, reason}}
      end
    end
  end

  @doc "Stops the session of a video (if any) and removes its files."
  def stop(video_id) do
    case Registry.lookup(Archive.TranscodeRegistry, video_id) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp ensure_started(video) do
    case Registry.lookup(Archive.TranscodeRegistry, video.id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        evict_if_full()

        case DynamicSupervisor.start_child(Archive.TranscodeSupervisor, {__MODULE__, video}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end
    end
  end

  # Keep at most `max_transcode_sessions` encoders: stop the least recently used.
  defp evict_if_full do
    max = Settings.get(:max_transcode_sessions)

    sessions =
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Archive.TranscodeSupervisor),
          is_pid(pid) do
        last =
          try do
            GenServer.call(pid, :last_access, 1_000)
          catch
            :exit, _ -> 0
          end

        {pid, last}
      end

    if length(sessions) >= max do
      sessions
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.take(length(sessions) - max + 1)
      |> Enum.each(fn {pid, _} -> GenServer.stop(pid, :normal) end)
    end
  catch
    :exit, _ -> :ok
  end

  def start_link(video) do
    GenServer.start_link(__MODULE__, video,
      name: {:via, Registry, {Archive.TranscodeRegistry, video.id}}
    )
  end

  # --- GenServer --------------------------------------------------------------------

  @impl true
  def init(video) do
    Process.flag(:trap_exit, true)
    dir = Path.join(Paths.transcode_dir(), "#{video.id}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    state = %{
      video_id: video.id,
      file: Paths.absolute(video.file_path),
      duration: video.duration,
      count: segment_count(video.duration || 1),
      dir: dir,
      task: nil,
      start: nil,
      waiters: %{},
      last_access: now(),
      poll_ref: nil
    }

    Process.send_after(self(), :idle_check, @idle_timeout_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:last_access, _from, state), do: {:reply, state.last_access, state}

  def handle_call({:segment, index}, from, state) do
    state = %{state | last_access: now()}

    cond do
      index < 0 or index >= state.count ->
        {:reply, {:error, :out_of_range}, state}

      File.exists?(segment_path(state, index)) ->
        # Keep the encoder going while the viewer plays.
        {:reply, {:ok, segment_path(state, index)}, maybe_restart_for_prefetch(state, index)}

      encoder_will_reach?(state, index) ->
        {:noreply, add_waiter(state, index, from)}

      true ->
        state = state |> start_encoder(index) |> add_waiter(index, from)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:poll, state) do
    state = %{state | poll_ref: nil} |> resolve_waiters()
    {:noreply, schedule_poll(state)}
  end

  def handle_info(:idle_check, state) do
    if now() - state.last_access >= @idle_timeout_ms and map_size(state.waiters) == 0 do
      {:stop, :normal, state}
    else
      Process.send_after(self(), :idle_check, 10_000)
      {:noreply, state}
    end
  end

  # Encoder finished (or failed): answer whatever can be answered.
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.warning(
          "transcode of video #{state.video_id} failed: #{Runner.format_error(error)}"
        )
    end

    state = %{state | task: nil} |> resolve_waiters()

    # Waiters left now can't be served by this encoder: restart at the lowest one.
    state =
      case Map.keys(state.waiters) do
        [] ->
          state

        indexes ->
          if result == {:ok, ""},
            do: fail_waiters(state),
            else: retry_or_fail(state, Enum.min(indexes))
      end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _, _reason}, %{task: %Task{ref: ref}} = state) do
    {:noreply, %{state | task: nil} |> resolve_waiters() |> fail_waiters()}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_encoder(state)
    File.rm_rf(state.dir)
    :ok
  end

  # --- internals ---------------------------------------------------------------------

  defp encoder_will_reach?(%{task: nil}, _index), do: false

  defp encoder_will_reach?(state, index) do
    index >= state.start and index <= highest_done(state) + @lookahead
  end

  # If playback is close to where the encoder stopped (e.g. it was restarted
  # elsewhere), resume encoding ahead of the viewer.
  defp maybe_restart_for_prefetch(state, index) do
    next = first_missing_after(state, index)

    cond do
      next == nil ->
        state

      state.task != nil and next >= state.start and next <= highest_done(state) + @lookahead ->
        state

      next - index <= 2 ->
        start_encoder(state, next)

      true ->
        state
    end
  end

  defp first_missing_after(state, index) do
    Enum.find((index + 1)..(state.count - 1)//1, &(not File.exists?(segment_path(state, &1))))
  end

  defp highest_done(%{start: start} = state) do
    Stream.iterate(start, &(&1 + 1))
    |> Enum.find(&(not File.exists?(segment_path(state, &1))))
    |> Kernel.-(1)
  end

  defp add_waiter(state, index, from) do
    waiters = Map.update(state.waiters, index, [from], &[from | &1])
    schedule_poll(%{state | waiters: waiters})
  end

  defp schedule_poll(%{poll_ref: nil, waiters: waiters} = state) when map_size(waiters) > 0 do
    %{state | poll_ref: Process.send_after(self(), :poll, @poll_ms)}
  end

  defp schedule_poll(state), do: state

  defp resolve_waiters(state) do
    {ready, pending} =
      Enum.split_with(state.waiters, fn {index, _} -> File.exists?(segment_path(state, index)) end)

    for {index, froms} <- ready, from <- froms do
      GenServer.reply(from, {:ok, segment_path(state, index)})
    end

    %{state | waiters: Map.new(pending)}
  end

  defp fail_waiters(state) do
    for {_index, froms} <- state.waiters, from <- froms do
      GenServer.reply(from, {:error, :not_produced})
    end

    %{state | waiters: %{}}
  end

  defp retry_or_fail(state, index) do
    if state.start == index, do: fail_waiters(state), else: start_encoder(state, index)
  end

  defp start_encoder(state, index) do
    stop_encoder(state)

    args = ffmpeg_args(state, index)

    task =
      Task.Supervisor.async_nolink(Archive.TaskSupervisor, fn ->
        Runner.run(Tools.ffmpeg(), args, collect: false)
      end)

    Logger.debug("transcode video #{state.video_id}: ffmpeg from segment #{index}")
    %{state | task: task, start: index}
  end

  defp stop_encoder(%{task: nil}), do: :ok

  defp stop_encoder(%{task: task}) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp ffmpeg_args(state, index) do
    offset = index * @segment_seconds
    max_h = Settings.get(:transcode_max_height)
    preset = Settings.get(:transcode_preset)

    ["-hide_banner", "-nostdin", "-v", "error", "-y"] ++
      ["-ss", Integer.to_string(offset), "-i", state.file] ++
      ["-map", "0:v:0?", "-map", "0:a:0?", "-sn", "-dn"] ++
      ["-c:v", "libx264", "-preset", preset, "-crf", "23", "-pix_fmt", "yuv420p"] ++
      ["-vf", "scale=-2:'min(#{max_h},trunc(ih/2)*2)'"] ++
      ["-force_key_frames", "expr:gte(t,n_forced*#{@segment_seconds})", "-sc_threshold", "0"] ++
      ["-c:a", "aac", "-ac", "2", "-b:a", "160k"] ++
      ["-output_ts_offset", Integer.to_string(offset)] ++
      ["-f", "hls", "-hls_time", Integer.to_string(@segment_seconds), "-hls_list_size", "0"] ++
      ["-hls_segment_type", "mpegts", "-hls_flags", "temp_file"] ++
      ["-start_number", Integer.to_string(index)] ++
      ["-hls_segment_filename", Path.join(state.dir, "%d.ts")] ++
      [Path.join(state.dir, "run-#{index}.m3u8")]
  end

  defp segment_path(state, index), do: Path.join(state.dir, "#{index}.ts")

  defp now, do: System.monotonic_time(:millisecond)
end
