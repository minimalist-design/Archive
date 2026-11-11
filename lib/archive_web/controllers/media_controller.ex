defmodule ArchiveWeb.MediaController do
  @moduledoc """
  Serves video files (with HTTP Range support for seeking), thumbnails,
  subtitles and the on-the-fly HLS stream. Everything is looked up by
  database id.
  """
  use ArchiveWeb, :controller

  alias Archive.{Paths, Videos}
  alias Archive.Media.{Probe, Thumbs, TranscodeSession}

  @placeholder """
  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 9"><rect width="16" height="9" fill="#888" fill-opacity="0.18"/><path d="M6.5 3v3l2.6-1.5z" fill="#888" fill-opacity="0.6"/></svg>
  """

  def file(conn, %{"id" => id}) do
    with_video(conn, id, fn video ->
      path = Paths.absolute(video.file_path)
      send_ranged(conn, path, Probe.mime_type(path))
    end)
  end

  def thumb(conn, %{"id" => id}) do
    with_video(conn, id, fn video ->
      case Thumbs.ensure(video) do
        {:ok, path} ->
          conn
          |> put_resp_header("cache-control", "public, max-age=86400")
          |> put_resp_content_type("image/jpeg", nil)
          |> send_file(200, path)

        _ ->
          placeholder(conn)
      end
    end)
  end

  def thumb_full(conn, %{"id" => id}) do
    with_video(conn, id, fn video ->
      path = video.thumbnail_path && Paths.absolute(video.thumbnail_path)

      if path && File.regular?(path) do
        conn
        |> put_resp_header("cache-control", "public, max-age=86400")
        |> put_resp_content_type(MIME.from_path(path), nil)
        |> send_file(200, path)
      else
        redirect(conn, to: ~p"/media/videos/#{video.id}/thumb")
      end
    end)
  end

  def subtitle(conn, %{"id" => id}) do
    with {int_id, ""} <- Integer.parse(id),
         %{} = subtitle <- Archive.Repo.get(Archive.Videos.Subtitle, int_id),
         path = Paths.absolute(subtitle.path),
         true <- File.regular?(path) do
      conn
      |> put_resp_content_type("text/vtt")
      |> send_file(200, path)
    else
      _ -> not_found(conn)
    end
  end

  def hls_playlist(conn, %{"id" => id}) do
    with_video(conn, id, fn video ->
      duration = video.duration || probe_duration(video)

      if duration && duration > 0 do
        conn
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_content_type("application/vnd.apple.mpegurl", nil)
        |> send_resp(200, TranscodeSession.playlist(duration))
      else
        send_resp(conn, 422, "unknown duration")
      end
    end)
  end

  def hls_segment(conn, %{"id" => id, "segment" => segment}) do
    with_video(conn, id, fn video ->
      video = %{video | duration: video.duration || probe_duration(video)}

      with [index_str] <- Regex.run(~r/^(\d+)\.ts$/, segment, capture: :all_but_first),
           {index, ""} <- Integer.parse(index_str),
           {:ok, path} <- TranscodeSession.segment(video, index) do
        conn
        |> put_resp_content_type("video/mp2t", nil)
        |> send_file(200, path)
      else
        _ -> not_found(conn)
      end
    end)
  end

  # --- helpers ---------------------------------------------------------------------

  defp with_video(conn, id, fun) do
    case Integer.parse(to_string(id)) do
      {int_id, ""} ->
        case Videos.get_video(int_id) do
          nil -> not_found(conn)
          video -> fun.(video)
        end

      _ ->
        not_found(conn)
    end
  end

  defp probe_duration(video) do
    case Probe.probe(Paths.absolute(video.file_path)) do
      {:ok, %{duration: d}} when is_number(d) -> d
      _ -> nil
    end
  end

  defp placeholder(conn) do
    conn
    |> put_resp_content_type("image/svg+xml", nil)
    |> send_resp(200, @placeholder)
  end

  defp not_found(conn), do: send_resp(conn, 404, "Not found")

  @doc false
  def send_ranged(conn, path, mime) do
    case File.stat(path) do
      {:ok, %{size: size, type: :regular}} ->
        conn =
          conn
          |> put_resp_header("accept-ranges", "bytes")
          |> put_resp_content_type(mime, nil)

        case get_req_header(conn, "range") do
          ["bytes=" <> spec] ->
            case parse_range(spec, size) do
              {:ok, first, last} ->
                conn
                |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
                |> send_file(206, path, first, last - first + 1)

              :full ->
                send_file(conn, 200, path)

              :error ->
                conn
                |> put_resp_header("content-range", "bytes */#{size}")
                |> send_resp(416, "")
            end

          _ ->
            send_file(conn, 200, path)
        end

      _ ->
        not_found(conn)
    end
  end

  @doc false
  # Single ranges only; multi-range requests get the whole file.
  def parse_range(spec, size) do
    cond do
      String.contains?(spec, ",") ->
        :full

      true ->
        case String.split(String.trim(spec), "-", parts: 2) do
          ["", suffix] ->
            with {n, ""} <- Integer.parse(suffix), true <- n > 0 and size > 0 do
              {:ok, max(size - n, 0), size - 1}
            else
              _ -> :error
            end

          [first, ""] ->
            with {f, ""} <- Integer.parse(first), true <- f < size do
              {:ok, f, size - 1}
            else
              _ -> :error
            end

          [first, last] ->
            with {f, ""} <- Integer.parse(first),
                 {l, ""} <- Integer.parse(last),
                 true <- f <= l and f < size do
              {:ok, f, min(l, size - 1)}
            else
              _ -> :error
            end

          _ ->
            :error
        end
    end
  end
end
