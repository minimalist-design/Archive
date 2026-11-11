defmodule Archive.Settings.Form do
  @moduledoc "Embedded schema backing the Settings page form."
  use Ecto.Schema
  import Ecto.Changeset

  @subtitle_modes ~w(original_plus_en original en none)
  @channels ~w(stable nightly master)
  @presets ~w(ultrafast superfast veryfast faster fast medium)
  @heights [480, 720, 1080, 1440, 2160]

  def subtitle_modes, do: @subtitle_modes
  def channels, do: @channels
  def presets, do: @presets
  def heights, do: @heights

  @primary_key false
  embedded_schema do
    field :storage_dir, :string
    field :download_concurrency, :integer
    field :subtitle_mode, :string
    field :ytdlp_channel, :string
    field :ytdlp_update_interval_hours, :integer
    field :transcode_max_height, :integer
    field :transcode_preset, :string
    field :max_transcode_sessions, :integer
    field :extra_ytdlp_args, :string
  end

  @fields [
    :storage_dir,
    :download_concurrency,
    :subtitle_mode,
    :ytdlp_channel,
    :ytdlp_update_interval_hours,
    :transcode_max_height,
    :transcode_preset,
    :max_transcode_sessions,
    :extra_ytdlp_args
  ]

  def from_settings(settings) do
    struct(__MODULE__, Map.take(settings, @fields))
    |> Map.update!(:storage_dir, fn
      nil -> Archive.Paths.storage_dir()
      dir -> dir
    end)
  end

  @doc """
  Builds the changeset. Pass `check_fs: true` (done on save only) to verify the
  storage directory can be created and written to.
  """
  def changeset(form, attrs, opts \\ []) do
    form
    |> cast(attrs, @fields, empty_values: [nil])
    |> update_change(:storage_dir, &normalize_dir/1)
    |> update_change(:extra_ytdlp_args, &String.trim/1)
    |> validate_required([
      :storage_dir,
      :download_concurrency,
      :subtitle_mode,
      :ytdlp_channel,
      :ytdlp_update_interval_hours,
      :transcode_max_height,
      :transcode_preset,
      :max_transcode_sessions
    ])
    |> validate_number(:download_concurrency,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 8
    )
    |> validate_number(:ytdlp_update_interval_hours,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 24 * 30
    )
    |> validate_number(:max_transcode_sessions,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 8
    )
    |> validate_inclusion(:subtitle_mode, @subtitle_modes)
    |> validate_inclusion(:ytdlp_channel, @channels)
    |> validate_inclusion(:transcode_preset, @presets)
    |> validate_inclusion(:transcode_max_height, @heights)
    |> validate_change(:storage_dir, fn field, dir ->
      cond do
        Path.type(dir) != :absolute -> [{field, "must be an absolute path"}]
        opts[:check_fs] -> validate_storage_dir(field, dir)
        true -> []
      end
    end)
    |> validate_change(:extra_ytdlp_args, &validate_args/2)
  end

  defp normalize_dir(dir) do
    dir = String.trim(dir)

    if String.starts_with?(dir, "~"),
      do: Path.expand(dir),
      else: if(Path.type(dir) == :absolute, do: Path.expand(dir), else: dir)
  end

  defp validate_storage_dir(field, dir) do
    probe = Path.join(dir, ".archive-write-test-#{System.unique_integer([:positive])}")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(probe, "ok"),
         :ok <- File.rm(probe) do
      []
    else
      {:error, reason} -> [{field, "is not writable (#{:file.format_error(reason)})"}]
    end
  end

  defp validate_args(field, args) do
    OptionParser.split(args)
    []
  rescue
    _ -> [{field, "could not be parsed"}]
  end
end
