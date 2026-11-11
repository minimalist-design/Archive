defmodule Archive.Fixtures do
  @moduledoc "Test helpers for creating libraries, videos and files."

  alias Archive.{Libraries, Paths, Videos}

  @fixtures Path.expand("fixtures", __DIR__)

  def fixture_path(name), do: Path.join(@fixtures, name)

  @doc "Empties the test storage and data directories."
  def clean_dirs! do
    File.rm_rf!(Paths.storage_dir())
    File.rm_rf!(Paths.data_dir())
    Paths.ensure_dirs!()
    :ok
  end

  def library_fixture(attrs \\ %{}) do
    {:ok, library} =
      attrs
      |> Enum.into(%{name: "Library #{System.unique_integer([:positive])}"})
      |> Libraries.create_library()

    library
  end

  def category_fixture(library, name) do
    {:ok, category} = Libraries.create_category(library, %{name: name})
    category
  end

  @doc """
  Creates a video record. With `with_file: true` the sample video is copied
  into the library folder.
  """
  def video_fixture(library, attrs \\ %{}, opts \\ []) do
    n = System.unique_integer([:positive])
    base = Map.get(attrs, :base, "Video #{n} [id#{n}]")
    rel = Path.join(library.slug, base <> ".mp4")

    if opts[:with_file] do
      File.mkdir_p!(Paths.library_dir(library))
      File.cp!(fixture_path("sample.mp4"), Paths.absolute(rel))
    end

    attrs =
      attrs
      |> Map.delete(:base)
      |> Enum.into(%{
        extractor_key: "Youtube",
        remote_id: "id#{n}",
        title: "Video #{n}",
        file_path: rel,
        duration: 60,
        playback: "direct"
      })

    {:ok, video} =
      Videos.create_video(library, attrs,
        category_ids: Keyword.get(opts, :category_ids, []),
        subtitles: Keyword.get(opts, :subtitles, [])
      )

    video
  end
end
