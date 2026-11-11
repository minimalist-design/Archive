defmodule Archive.Files do
  @moduledoc "Filesystem helpers: safe names, slugs and cross-device moves."

  @doc """
  Moves `src` to `dest`, creating parent directories. Falls back to
  copy + size check + delete when a rename is not possible (e.g. across
  filesystems).
  """
  def move(src, dest) do
    File.mkdir_p!(Path.dirname(dest))

    case File.rename(src, dest) do
      :ok ->
        :ok

      {:error, :exdev} ->
        copy_and_delete(src, dest)

      {:error, reason} ->
        # Some filesystems report other errors for cross-device renames.
        if File.exists?(src) and not File.exists?(dest),
          do: copy_and_delete(src, dest),
          else: {:error, reason}
    end
  end

  defp copy_and_delete(src, dest) do
    if File.dir?(src), do: copy_dir_and_delete(src, dest), else: copy_file_and_delete(src, dest)
  end

  defp copy_dir_and_delete(src, dest) do
    case File.cp_r(src, dest) do
      {:ok, _} ->
        if tree_size(src) == tree_size(dest) do
          File.rm_rf!(src)
          :ok
        else
          File.rm_rf(dest)
          {:error, :size_mismatch}
        end

      {:error, reason, _file} ->
        File.rm_rf(dest)
        {:error, reason}
    end
  end

  defp tree_size(dir) do
    Path.wildcard(Path.join(dir, "**"), match_dot: true)
    |> Enum.reduce(0, fn path, acc ->
      case File.stat(path) do
        {:ok, %{type: :regular, size: size}} -> acc + size
        _ -> acc
      end
    end)
  end

  defp copy_file_and_delete(src, dest) do
    with {:ok, _} <- File.copy(src, dest),
         {:ok, %{size: size}} <- File.stat(src),
         {:ok, %{size: ^size}} <- File.stat(dest) do
      File.rm(src)
    else
      {:ok, %{size: _}} ->
        File.rm(dest)
        {:error, :size_mismatch}

      error ->
        error
    end
  end

  @doc """
  Returns `path` if nothing exists there, otherwise `name (2).ext`,
  `name (3).ext`… The `taken` function can add extra conflict checks.
  """
  def unique_path(path, taken \\ fn _ -> false end) do
    if not File.exists?(path) and not taken.(path) do
      path
    else
      ext = Path.extname(path)
      base = Path.rootname(path)

      Stream.iterate(2, &(&1 + 1))
      |> Stream.map(&"#{base} (#{&1})#{ext}")
      |> Enum.find(&(not File.exists?(&1) and not taken.(&1)))
    end
  end

  @doc """
  Returns `dir` if nothing exists there, otherwise `dir (2)`, `dir (3)`…
  (unlike `unique_path/2`, dots in the name are not treated as an extension).
  """
  def unique_dir(dir) do
    if File.exists?(dir) do
      Stream.iterate(2, &(&1 + 1))
      |> Stream.map(&"#{dir} (#{&1})")
      |> Enum.find(&(not File.exists?(&1)))
    else
      dir
    end
  end

  @doc """
  Makes a string safe to use as a file or folder name on common filesystems
  (also Windows/Samba shares), limited to `max_bytes`.
  """
  def safe_name(name, max_bytes \\ 150) do
    name
    |> String.replace(~r/[\x00-\x1f\x7f]/u, "")
    |> String.replace(~r{[/\\:*?"<>|]}u, "_")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.trim_leading(".")
    |> truncate_bytes(max_bytes)
    |> String.trim()
    |> case do
      "" -> "untitled"
      safe -> safe
    end
  end

  @doc "Truncates to at most `max` bytes without splitting a UTF-8 character."
  def truncate_bytes(string, max) when byte_size(string) <= max, do: string

  def truncate_bytes(string, max) do
    string
    |> String.graphemes()
    |> Enum.reduce_while("", fn g, acc ->
      if byte_size(acc) + byte_size(g) > max, do: {:halt, acc}, else: {:cont, acc <> g}
    end)
  end

  @doc "URL- and folder-friendly slug."
  def slugify(name) do
    slug =
      name
      |> String.normalize(:nfd)
      |> String.replace(~r/\p{Mn}/u, "")
      |> String.downcase()
      |> String.replace(~r/[^\p{L}\p{N}]+/u, "-")
      |> String.trim("-")
      |> truncate_bytes(80)
      |> String.trim("-")

    if slug == "", do: "library", else: slug
  end

  @doc "Deletes a file if present, ignoring missing files."
  def rm(nil), do: :ok

  def rm(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end
end
