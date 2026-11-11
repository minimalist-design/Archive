defmodule Archive.Paths do
  @moduledoc """
  Filesystem locations used by the archive.

  * The **data dir** holds app-internal state: managed tool binaries, the
    transcode cache, grid thumbnails and temp files.
  * The **storage dir** holds the archive itself: one folder per library with
    the video files and their sidecars. All paths stored in the database are
    relative to it.
  """

  alias Archive.Settings

  def data_dir, do: Application.fetch_env!(:archive, :data_dir)
  def bin_dir, do: Path.join(data_dir(), "bin")
  def thumbs_dir, do: Path.join(data_dir(), "thumbs")
  def transcode_dir, do: Path.join(data_dir(), "transcode")
  def tmp_dir, do: Path.join(data_dir(), "tmp")

  def storage_dir do
    case Settings.get(:storage_dir) do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> Application.fetch_env!(:archive, :default_storage_dir)
    end
  end

  @doc "Absolute path for a path stored relative to the storage dir."
  def absolute(nil), do: nil
  def absolute(relative), do: Path.join(storage_dir(), relative)

  @doc "Path relative to the storage dir (expects a path inside it)."
  def relative(absolute) do
    Path.relative_to(Path.expand(absolute), Path.expand(storage_dir()))
  end

  def library_dir(%{slug: slug}), do: Path.join(storage_dir(), slug)

  def grid_thumb(video_id), do: Path.join(thumbs_dir(), "#{video_id}.jpg")

  @doc "Creates the directories the app needs."
  def ensure_dirs! do
    for dir <- [data_dir(), bin_dir(), thumbs_dir(), transcode_dir(), tmp_dir()] do
      File.mkdir_p!(dir)
    end

    _ = File.mkdir_p(storage_dir())
    :ok
  end

  @doc "A unique temporary path inside the data dir."
  def tmp_path(prefix) do
    File.mkdir_p!(tmp_dir())
    Path.join(tmp_dir(), "#{prefix}-#{System.unique_integer([:positive])}")
  end
end
