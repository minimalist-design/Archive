defmodule Archive.Media.VttTest do
  use ExUnit.Case, async: true
  alias Archive.Media.Vtt

  test "extracts text, dropping headers, timings, tags and rolling duplicates" do
    vtt = """
    WEBVTT
    Kind: captions
    Language: en

    00:00:00.000 --> 00:00:02.000 align:start position:0%
    hello<00:00:00.500><c> world</c>

    00:00:02.000 --> 00:00:02.010
    hello world

    00:00:02.010 --> 00:00:04.000
    hello world
    second &amp; line

    NOTE this is a comment

    3
    00:00:04.000 --> 00:00:05.000
    third line
    """

    assert Vtt.to_text(vtt) == "hello world\nsecond & line\nthird line"
  end

  test "converts srt to vtt" do
    srt = "1\r\n00:00:01,500 --> 00:00:02,000\r\nHi\r\n"
    assert Vtt.srt_to_vtt(srt) == "WEBVTT\n\n1\n00:00:01.500 --> 00:00:02.000\nHi\n"
  end
end
