defmodule Archive.Settings do
  @moduledoc """
  Persistent application settings stored in the `settings` table.

  Values are cached in `:persistent_term` and the cache is invalidated on every
  write. Unknown keys are rejected; defaults live in `defaults/0`.
  """

  import Ecto.Query
  alias Archive.Repo
  alias Archive.Settings.{Entry, Form}

  @cache_key {__MODULE__, :cache}

  @defaults %{
    storage_dir: nil,
    download_concurrency: 2,
    subtitle_mode: "original_plus_en",
    ytdlp_channel: "stable",
    ytdlp_update_interval_hours: 24,
    transcode_max_height: 1080,
    transcode_preset: "veryfast",
    max_transcode_sessions: 2,
    extra_ytdlp_args: "",
    # Internal state, not editable from the form.
    tools_state: %{}
  }

  @keys Map.keys(@defaults)

  def defaults, do: @defaults

  @doc "Returns all settings merged over defaults."
  def all do
    if cache?() do
      case :persistent_term.get(@cache_key, nil) do
        nil ->
          settings = load()
          :persistent_term.put(@cache_key, settings)
          settings

        settings ->
          settings
      end
    else
      load()
    end
  end

  def get(key) when key in @keys, do: Map.fetch!(all(), key)

  @doc "Persists one setting."
  def put(key, value) when key in @keys do
    now = DateTime.utc_now(:second)

    Repo.insert!(
      %Entry{key: Atom.to_string(key), value: %{"v" => value}, inserted_at: now, updated_at: now},
      on_conflict: [set: [value: %{"v" => value}, updated_at: now]],
      conflict_target: :key
    )

    invalidate()
    :ok
  end

  @doc "Persists several settings at once."
  def put_many(map) do
    Repo.transaction(fn -> Enum.each(map, fn {k, v} -> put(k, v) end) end)
    invalidate()
    :ok
  end

  def invalidate do
    :persistent_term.erase(@cache_key)
    :ok
  end

  @doc "Changeset for the editable settings form."
  def change_form(attrs \\ %{}, opts \\ []) do
    Form.changeset(Form.from_settings(all()), attrs, opts)
  end

  @doc """
  Validates and saves the settings form. Returns `{:ok, changed_keys}` or
  `{:error, changeset}`.
  """
  def save_form(attrs) do
    changeset = change_form(attrs, check_fs: true)

    case Ecto.Changeset.apply_action(changeset, :update) do
      {:ok, form} ->
        changes = Map.take(Map.from_struct(form), Map.keys(changeset.changes))
        put_many(changes)
        {:ok, Map.keys(changes)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # --- internal tool state helpers -------------------------------------------

  def tool_state(tool) do
    Map.get(get(:tools_state), to_string(tool), %{})
  end

  def put_tool_state(tool, attrs) do
    state = get(:tools_state)
    merged = Map.merge(Map.get(state, to_string(tool), %{}), stringify(attrs))
    put(:tools_state, Map.put(state, to_string(tool), merged))
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp load do
    stored =
      from(e in Entry, select: {e.key, e.value})
      |> Repo.all()
      |> Enum.reduce(%{}, fn {key, %{"v" => value}}, acc ->
        case Enum.find(@keys, &(Atom.to_string(&1) == key)) do
          nil -> acc
          atom -> Map.put(acc, atom, value)
        end
      end)

    Map.merge(@defaults, stored)
  rescue
    # Table may not exist yet (e.g. before migrations ran).
    _ in [Exqlite.Error, DBConnection.ConnectionError] -> @defaults
  end

  defp cache?, do: Application.get_env(:archive, :settings_cache, true)
end
