defmodule ArchiveWeb.MediaControllerTest do
  use ArchiveWeb.ConnCase, async: false

  import Archive.Fixtures
  alias ArchiveWeb.MediaController

  setup do
    clean_dirs!()
    library = library_fixture()
    video = video_fixture(library, %{}, with_file: true)
    %{video: video, size: File.stat!(fixture_path("sample.mp4")).size}
  end

  describe "parse_range/2" do
    test "handles the single-range forms" do
      assert MediaController.parse_range("0-99", 1000) == {:ok, 0, 99}
      assert MediaController.parse_range("500-", 1000) == {:ok, 500, 999}
      assert MediaController.parse_range("-100", 1000) == {:ok, 900, 999}
      assert MediaController.parse_range("900-5000", 1000) == {:ok, 900, 999}
      assert MediaController.parse_range("0-1,5-6", 1000) == :full
      assert MediaController.parse_range("1000-", 1000) == :error
      assert MediaController.parse_range("5-1", 1000) == :error
      assert MediaController.parse_range("abc", 1000) == :error
    end
  end

  test "serves the whole file", %{conn: conn, video: video, size: size} do
    conn = get(conn, ~p"/media/videos/#{video.id}/file")
    assert conn.status == 200
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    assert get_resp_header(conn, "content-type") == ["video/mp4"]
    assert byte_size(conn.resp_body) == size
  end

  test "serves byte ranges", %{conn: conn, video: video, size: size} do
    conn =
      conn |> put_req_header("range", "bytes=10-19") |> get(~p"/media/videos/#{video.id}/file")

    assert conn.status == 206
    assert get_resp_header(conn, "content-range") == ["bytes 10-19/#{size}"]
    assert conn.resp_body == binary_part(File.read!(fixture_path("sample.mp4")), 10, 10)
  end

  test "rejects unsatisfiable ranges", %{conn: conn, video: video, size: size} do
    conn =
      conn |> put_req_header("range", "bytes=#{size}-") |> get(~p"/media/videos/#{video.id}/file")

    assert conn.status == 416
  end

  test "generates and serves the grid thumbnail", %{conn: conn, video: video} do
    conn = get(conn, ~p"/media/videos/#{video.id}/thumb")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
  end

  test "returns 404 for unknown ids", %{conn: conn} do
    assert get(conn, ~p"/media/videos/999999/file").status == 404
    assert get(conn, "/media/videos/abc/file").status == 404
    assert get(conn, ~p"/media/subtitles/999999").status == 404
  end

  test "serves an HLS playlist and transcoded segments", %{conn: conn, video: video} do
    playlist = get(conn, ~p"/media/videos/#{video.id}/hls/index.m3u8")
    assert playlist.status == 200
    assert playlist.resp_body =~ "#EXT-X-PLAYLIST-TYPE:VOD"
    # 60 s duration (from the fixture record) -> 10 segments of 6 s
    assert length(Regex.scan(~r/#EXTINF/, playlist.resp_body)) == 10

    segment = get(build_conn(), ~p"/media/videos/#{video.id}/hls/0.ts")
    assert segment.status == 200
    assert get_resp_header(segment, "content-type") == ["video/mp2t"]
    assert byte_size(segment.resp_body) > 0

    assert get(build_conn(), ~p"/media/videos/#{video.id}/hls/99.ts").status == 404
    Archive.Media.TranscodeSession.stop(video.id)
  end
end
