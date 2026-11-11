defmodule Archive.Media.Vtt do
  @moduledoc """
  Converts subtitle files to plain text for the search index, and SRT to
  WebVTT for imports.
  """

  @doc "Plain text of a subtitle file, or an empty string if unreadable."
  def file_to_text(path) do
    case File.read(path) do
      {:ok, content} -> to_text(content)
      {:error, _} -> ""
    end
  end

  @doc """
  Strips headers, cue identifiers, timings and inline tags. Consecutive
  duplicate lines are removed; auto-generated YouTube captions repeat each line
  as they "roll".
  """
  def to_text(content) do
    content
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.reduce({[], nil, :body}, &reduce_line/2)
    |> then(fn {lines, _, _} -> lines end)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp reduce_line(line, {acc, last, state}) do
    line = String.trim(line)

    cond do
      # Header and metadata blocks (WEBVTT, STYLE, NOTE, REGION) until a blank line.
      String.starts_with?(line, ["WEBVTT", "STYLE", "NOTE", "REGION", "Kind:", "Language:"]) ->
        {acc, last, :skip_block}

      line == "" ->
        {acc, last, :body}

      state == :skip_block ->
        {acc, last, :skip_block}

      String.contains?(line, "-->") ->
        {acc, last, :body}

      Regex.match?(~r/^\d+$/, line) ->
        {acc, last, :body}

      true ->
        text =
          line
          |> String.replace(~r/<[^>]*>/, "")
          |> decode_entities()
          |> String.trim()

        cond do
          text == "" -> {acc, last, :body}
          text == last -> {acc, last, :body}
          seen_recently?(acc, text) -> {acc, text, :body}
          true -> {[text | acc], text, :body}
        end
    end
  end

  defp seen_recently?(acc, text), do: text in Enum.take(acc, 3)

  defp decode_entities(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
  end

  @doc "Converts SRT content to WebVTT."
  def srt_to_vtt(content) do
    body =
      content
      |> String.replace("\r\n", "\n")
      |> String.replace(~r/^\x{FEFF}/u, "")
      |> String.replace(~r/(\d{2}:\d{2}:\d{2}),(\d{3})/, "\\1.\\2")

    "WEBVTT\n\n" <> body
  end
end
