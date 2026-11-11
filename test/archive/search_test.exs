defmodule Archive.SearchTest do
  use Archive.DataCase, async: false

  import Archive.Fixtures
  alias Archive.{Paths, Search}

  setup do
    clean_dirs!()
    :ok
  end

  describe "match_expression/1" do
    test "quotes and prefix-matches every word" do
      assert Search.match_expression("hello wor") == ~s("hello"* "wor"*)
    end

    test "neutralizes FTS syntax" do
      assert Search.match_expression(~s(a" OR title:x -NOT*)) ==
               ~s("a"* "OR"* "title"* "x"* "NOT"*)
    end

    test "keeps unicode letters" do
      assert Search.match_expression("canción niño") == ~s("canción"* "niño"*)
    end

    test "returns nil for empty input" do
      assert Search.match_expression("  ") == nil
      assert Search.match_expression("!!") == nil
      assert Search.match_expression(nil) == nil
    end
  end

  describe "search/2" do
    test "finds videos by title, description, tags and subtitles, title first" do
      library = library_fixture()
      by_title = video_fixture(library, %{title: "Penguin documentary"})
      by_desc = video_fixture(library, %{title: "Nature", description: "all about penguins"})
      by_tag = video_fixture(library, %{title: "Birds", tags: ["penguin"]})
      _other = video_fixture(library, %{title: "Cooking"})

      ids = Search.search("penguin") |> Enum.map(& &1.id)
      assert hd(ids) == by_title.id
      assert MapSet.new(ids) == MapSet.new([by_title.id, by_desc.id, by_tag.id])
    end

    test "matches text that only appears in subtitles, ignoring accents" do
      library = library_fixture()
      File.mkdir_p!(Paths.library_dir(library))
      vtt = Path.join(library.slug, "subs.es.vtt")

      File.write!(
        Paths.absolute(vtt),
        "WEBVTT\n\n00:00.000 --> 00:01.000\nEl ornitorrinco nadó\n"
      )

      video =
        video_fixture(library, %{title: "Clip"},
          subtitles: [%{lang: "es", auto: false, path: vtt}]
        )

      assert [%{id: id}] = Search.search("ornitorr")
      assert id == video.id
      assert [%{id: ^id}] = Search.search("nado")
    end

    test "requires all words to match" do
      library = library_fixture()
      video_fixture(library, %{title: "Red car"})
      video_fixture(library, %{title: "Red bike"})

      assert [%{title: "Red car"}] = Search.search("red car")
    end
  end
end
