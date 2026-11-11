defmodule ArchiveWeb.ImportLive do
  @moduledoc "Scan a server folder for existing videos and import (move) them into a library."
  use ArchiveWeb, :live_view

  alias Archive.{Downloads, Importer, Libraries}

  @impl true
  def mount(_params, _session, socket) do
    library_id = socket.assigns.nav_libraries |> List.first() |> then(&(&1 && to_string(&1.id)))

    {:ok,
     socket
     |> assign(
       page_title: "Import",
       form:
         to_form(%{"path" => "", "library_id" => library_id || "", "category_ids" => []},
           as: :import
         ),
       categories: [],
       entries: nil,
       selected: MapSet.new(),
       scan_error: nil,
       scanning: false
     )
     |> load_categories(library_id)}
  end

  @impl true
  def handle_event("change", %{"import" => params}, socket) do
    params =
      Map.update(params, "category_ids", [], &Enum.reject(List.wrap(&1), fn v -> v == "" end))

    {:noreply,
     socket
     |> assign(form: to_form(params, as: :import))
     |> load_categories(params["library_id"])}
  end

  def handle_event("scan", %{"import" => params}, socket) do
    params =
      Map.update(params, "category_ids", [], &Enum.reject(List.wrap(&1), fn v -> v == "" end))

    path = String.trim(params["path"] || "")
    socket = assign(socket, form: to_form(params, as: :import))

    if path == "" do
      {:noreply, assign(socket, scan_error: "Enter a folder path on the server.")}
    else
      send(self(), {:scan, path})
      {:noreply, assign(socket, scanning: true, scan_error: nil)}
    end
  end

  def handle_event("toggle", %{"path" => path}, socket) do
    selected = socket.assigns.selected

    selected =
      if MapSet.member?(selected, path),
        do: MapSet.delete(selected, path),
        else: MapSet.put(selected, path)

    {:noreply, assign(socket, selected: selected)}
  end

  def handle_event("select_all", _params, socket) do
    {:noreply, assign(socket, selected: importable_paths(socket.assigns.entries))}
  end

  def handle_event("select_none", _params, socket) do
    {:noreply, assign(socket, selected: MapSet.new())}
  end

  def handle_event("import", _params, socket) do
    params = socket.assigns.form.params

    with {library_id, ""} <- Integer.parse(params["library_id"] || ""),
         library when not is_nil(library) <-
           Archive.Repo.get(Archive.Libraries.Library, library_id) do
      paths = MapSet.to_list(socket.assigns.selected) |> Enum.sort()
      Enum.each(paths, &Downloads.enqueue_import(&1, library, params["category_ids"] || []))

      {:noreply,
       socket
       |> put_flash(:info, "Importing #{length(paths)} file(s) into “#{library.name}”.")
       |> push_navigate(to: ~p"/downloads")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Choose a library first.")}
    end
  end

  @impl true
  def handle_info({:scan, path}, socket) do
    case Importer.scan(path) do
      {:ok, entries} ->
        {:noreply,
         assign(socket,
           entries: entries,
           selected: importable_paths(entries),
           scanning: false
         )}

      {:error, message} ->
        {:noreply, assign(socket, scan_error: message, entries: nil, scanning: false)}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp importable_paths(nil), do: MapSet.new()

  defp importable_paths(entries) do
    entries |> Enum.reject(& &1.duplicate) |> Enum.map(& &1.path) |> MapSet.new()
  end

  defp load_categories(socket, library_id) do
    categories =
      case Integer.parse(to_string(library_id || "")) do
        {id, ""} -> Libraries.list_categories(id)
        _ -> []
      end

    assign(socket, :categories, categories)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav_libraries={@nav_libraries}
      active_downloads={@active_downloads}
      search_query={@search_query}
      active={:import}
    >
      <div class="mx-auto max-w-5xl">
        <h1 class="text-2xl font-bold tracking-tight">Import existing files</h1>
        <p class="mt-1 max-w-3xl text-sm text-base-content/60">
          Scan a folder on the server for videos. Files are <strong>moved</strong>
          into the library folder.
          Metadata comes from a matching <code>.info.json</code>
          when present, otherwise from YouTube if the
          filename contains a video id, otherwise the filename becomes the title.
        </p>

        <div :if={@nav_libraries == []} class="alert alert-warning mt-6">
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <span>Create a library first (the + next to “Libraries” in the sidebar).</span>
        </div>

        <.form
          for={@form}
          id="import-form"
          phx-change="change"
          phx-submit="scan"
          class="mt-6 grid gap-x-4 rounded-2xl border border-base-300 p-5 sm:grid-cols-[1fr_16rem_auto] sm:items-end"
        >
          <.input
            field={@form[:path]}
            type="text"
            label="Folder on the server"
            placeholder="/home/me/Downloads/videos"
            autocomplete="off"
          />
          <.input
            field={@form[:library_id]}
            type="select"
            label="Into library"
            options={Enum.map(@nav_libraries, &{&1.name, &1.id})}
          />
          <button class="btn btn-primary mb-2" phx-disable-with="Scanning…" disabled={@scanning}>
            <.icon name="hero-magnifying-glass" class="size-4" /> Scan
          </button>
          <div :if={@categories != []} class="sm:col-span-3">
            <p class="mb-2 text-sm font-medium">Categories</p>
            <input type="hidden" name="import[category_ids][]" value="" />
            <div class="flex flex-wrap gap-2">
              <label
                :for={category <- @categories}
                class={[
                  "cursor-pointer select-none rounded-full border px-3 py-1 text-sm transition",
                  if(to_string(category.id) in (@form[:category_ids].value || []),
                    do: "border-primary bg-primary/10 text-primary",
                    else: "border-base-300 hover:bg-base-200"
                  )
                ]}
              >
                <input
                  type="checkbox"
                  class="hidden"
                  name="import[category_ids][]"
                  value={category.id}
                  checked={to_string(category.id) in (@form[:category_ids].value || [])}
                />
                {category.name}
              </label>
            </div>
          </div>
        </.form>

        <p :if={@scan_error} class="mt-4 flex items-center gap-2 text-sm text-error">
          <.icon name="hero-exclamation-circle" class="size-4" /> {@scan_error}
        </p>

        <div :if={@scanning} class="mt-10 flex justify-center">
          <span class="loading loading-spinner loading-lg text-primary"></span>
        </div>

        <section :if={@entries && !@scanning} id="scan-results" class="mt-8">
          <div class="mb-3 flex flex-wrap items-center justify-between gap-3">
            <p class="text-sm">
              <span class="font-semibold">{length(@entries)}</span>
              video file(s) found, <span class="font-semibold">{MapSet.size(@selected)}</span>
              selected
            </p>
            <div class="flex gap-2">
              <button phx-click="select_all" class="btn btn-ghost btn-sm">Select all</button>
              <button phx-click="select_none" class="btn btn-ghost btn-sm">Select none</button>
              <button
                id="start-import"
                phx-click="import"
                class="btn btn-primary btn-sm"
                disabled={MapSet.size(@selected) == 0 or @nav_libraries == []}
              >
                <.icon name="hero-folder-arrow-down" class="size-4" />
                Import {MapSet.size(@selected)} file(s)
              </button>
            </div>
          </div>

          <div class="overflow-x-auto rounded-2xl border border-base-300">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th class="w-8"></th>
                  <th>File</th>
                  <th>Title</th>
                  <th>Metadata</th>
                  <th class="text-right">Size</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={entry <- @entries} class={[entry.duplicate && "opacity-50"]}>
                  <td>
                    <input
                      type="checkbox"
                      class="checkbox checkbox-sm"
                      checked={MapSet.member?(@selected, entry.path)}
                      phx-click="toggle"
                      phx-value-path={entry.path}
                    />
                  </td>
                  <td class="max-w-xs truncate font-mono text-xs" title={entry.path}>{entry.name}</td>
                  <td class="max-w-xs truncate" title={entry.title}>{entry.title}</td>
                  <td class="whitespace-nowrap text-xs">
                    <span :if={entry.duplicate} class="badge badge-sm badge-warning">{entry.duplicate}</span>
                    <span
                      :if={!entry.duplicate && entry.source == :info_json}
                      class="badge badge-sm badge-success"
                    >info.json</span>
                    <span
                      :if={!entry.duplicate && entry.source == :youtube_id}
                      class="badge badge-sm badge-info"
                    >YouTube {entry.remote_id}</span>
                    <span
                      :if={!entry.duplicate && entry.source == :filename}
                      class="badge badge-sm badge-ghost"
                    >filename</span>
                    <span :if={entry.has_thumbnail} class="ml-1 text-base-content/50">thumb</span>
                    <span :if={entry.subtitle_count > 0} class="ml-1 text-base-content/50">{entry.subtitle_count} subs</span>
                  </td>
                  <td class="whitespace-nowrap text-right text-xs tabular-nums">
                    {format_bytes(entry.size)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
