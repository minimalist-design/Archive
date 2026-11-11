defmodule ArchiveWeb.LibraryLive do
  @moduledoc """
  A library: category filter chips, sort, in-library search and an
  infinite-scrolling grid with bulk categorize/move actions.
  """
  use ArchiveWeb, :live_view

  alias Archive.{Downloads, Libraries, Videos}

  @sort_labels [
    {"Date added (newest)", "added_desc"},
    {"Date added (oldest)", "added_asc"},
    {"Upload date (newest)", "uploaded_desc"},
    {"Upload date (oldest)", "uploaded_asc"},
    {"Title (A–Z)", "title_asc"},
    {"Title (Z–A)", "title_desc"},
    {"Longest", "duration_desc"},
    {"Shortest", "duration_asc"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       library: nil,
       categories: [],
       category_id: nil,
       sort: "added_desc",
       lq: "",
       last: nil,
       end_of_list?: false,
       count: 0,
       select_mode: false,
       selected: MapSet.new(),
       modal: nil,
       library_form: nil,
       category_form: nil,
       editing_category: nil,
       delete_files: false
     )
     |> stream_configure(:videos, dom_id: &"videos-#{&1.id}")
     |> stream(:videos, [])}
  end

  @impl true
  def handle_params(%{"slug" => slug} = params, _uri, socket) do
    case Libraries.get_library_by_slug(slug) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Library not found.")
         |> push_navigate(to: ~p"/")}

      library ->
        categories = Libraries.list_categories(library)

        category_id =
          case Integer.parse(params["category"] || "") do
            {id, ""} -> if Enum.any?(categories, &(&1.id == id)), do: id
            _ -> nil
          end

        sort = if params["sort"] in Videos.sorts(), do: params["sort"], else: "added_desc"

        {:noreply,
         socket
         |> assign(
           library: library,
           categories: categories,
           category_id: category_id,
           sort: sort,
           lq: params["q"] || "",
           page_title: library.name,
           count: Libraries.count_videos(library),
           selected: MapSet.new()
         )
         |> reset_videos()}
    end
  end

  defp reset_videos(socket) do
    socket
    |> assign(last: nil, end_of_list?: false)
    |> stream(:videos, [], reset: true)
    |> load_page()
  end

  defp load_page(%{assigns: %{end_of_list?: true}} = socket), do: socket

  defp load_page(socket) do
    %{library: library, category_id: category_id, sort: sort, lq: lq, last: last} = socket.assigns

    videos =
      Videos.list_library_videos(library.id,
        category_id: category_id,
        sort: sort,
        query: lq,
        after: last
      )

    socket
    |> assign(
      last: List.last(videos) || last,
      end_of_list?: length(videos) < Videos.page_size()
    )
    |> stream(:videos, videos, at: -1)
  end

  defp self_path(socket, overrides) do
    a = socket.assigns

    query =
      [
        category: Keyword.get(overrides, :category, a.category_id),
        sort: Keyword.get(overrides, :sort, a.sort),
        q: Keyword.get(overrides, :q, a.lq)
      ]
      |> Enum.reject(fn {k, v} -> v in [nil, ""] or (k == :sort and v == "added_desc") end)

    slug = Keyword.get(overrides, :slug, a.library.slug)
    if query == [], do: ~p"/libraries/#{slug}", else: ~p"/libraries/#{slug}?#{query}"
  end

  # --- events: browsing ---------------------------------------------------------

  @impl true
  def handle_event("load_more", _params, socket), do: {:noreply, load_page(socket)}

  def handle_event("filter_category", %{"id" => id}, socket) do
    category = if id == "", do: nil, else: String.to_integer(id)
    {:noreply, push_patch(socket, to: self_path(socket, category: category))}
  end

  def handle_event("sort", %{"sort" => sort}, socket) do
    {:noreply, push_patch(socket, to: self_path(socket, sort: sort))}
  end

  def handle_event("library_search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: self_path(socket, q: String.trim(q)), replace: true)}
  end

  # --- events: selection & bulk actions --------------------------------------------

  def handle_event("toggle_select_mode", _params, socket) do
    socket = assign(socket, select_mode: !socket.assigns.select_mode, selected: MapSet.new())
    {:noreply, reset_videos(socket)}
  end

  def handle_event("toggle_select", %{"id" => id}, socket) do
    id = String.to_integer(id)
    selected = socket.assigns.selected

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    socket = assign(socket, :selected, selected)

    socket =
      case Videos.get_video(id) do
        nil -> socket
        video -> stream_insert(socket, :videos, video)
      end

    {:noreply, socket}
  end

  def handle_event("bulk_category", %{"action" => action, "category_id" => category_id}, socket)
      when action in ["add", "remove"] and category_id != "" do
    ids = MapSet.to_list(socket.assigns.selected)
    category = Enum.find(socket.assigns.categories, &(to_string(&1.id) == category_id))

    if ids != [] and category do
      {:ok, n} = Videos.bulk_categorize(ids, category.id, String.to_existing_atom(action))
      verb = if action == "add", do: "added to", else: "removed from"

      {:noreply,
       socket
       |> put_flash(:info, "#{n} video(s) #{verb} “#{category.name}”.")
       |> assign(selected: MapSet.new())
       |> reset_videos()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("bulk_category", _params, socket), do: {:noreply, socket}

  def handle_event("bulk_move", %{"library_id" => library_id}, socket) when library_id != "" do
    target = Libraries.get_library!(String.to_integer(library_id))
    ids = MapSet.to_list(socket.assigns.selected)

    {moved, failed} =
      ids
      |> Enum.map(&Videos.get_video/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Videos.move_to_library(&1, target))
      |> Enum.split_with(&match?({:ok, _}, &1))

    socket =
      socket
      |> put_flash(
        if(failed == [], do: :info, else: :error),
        "Moved #{length(moved)} video(s) to “#{target.name}”" <>
          if(failed == [], do: ".", else: "; #{length(failed)} failed.")
      )
      |> assign(selected: MapSet.new(), count: Libraries.count_videos(socket.assigns.library))
      |> reset_videos()

    {:noreply, socket}
  end

  def handle_event("bulk_move", _params, socket), do: {:noreply, socket}

  def handle_event("clear_selection", _params, socket) do
    {:noreply, socket |> assign(selected: MapSet.new()) |> reset_videos()}
  end

  # --- events: library management --------------------------------------------------

  def handle_event("sync", _params, socket) do
    case Downloads.sync_library(socket.assigns.library) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:library, Libraries.get_library!(socket.assigns.library.id))
         |> put_flash(:info, "Checking the source for new videos…")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "This library has no source URL.")}
    end
  end

  def handle_event("open_modal", %{"modal" => "edit"}, socket) do
    form = to_form(Libraries.change_library(socket.assigns.library))
    {:noreply, assign(socket, modal: :edit, library_form: form)}
  end

  def handle_event("open_modal", %{"modal" => "delete"}, socket) do
    {:noreply, assign(socket, modal: :delete, delete_files: false)}
  end

  def handle_event("open_modal", %{"modal" => "categories"}, socket) do
    {:noreply,
     assign(socket,
       modal: :categories,
       category_form: new_category_form(),
       editing_category: nil
     )}
  end

  def handle_event("close_modal", _params, socket), do: {:noreply, assign(socket, modal: nil)}

  def handle_event("validate_library", %{"library" => params}, socket) do
    form =
      socket.assigns.library
      |> Libraries.change_library(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, library_form: form)}
  end

  def handle_event("save_library", %{"library" => params}, socket) do
    case Libraries.update_library(socket.assigns.library, params) do
      {:ok, library} ->
        {:noreply,
         socket
         |> assign(modal: nil, library: library)
         |> put_flash(:info, "Library updated.")
         |> push_patch(to: self_path(socket, slug: library.slug))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, library_form: to_form(changeset))}
    end
  end

  def handle_event("toggle_delete_files", params, socket) do
    {:noreply, assign(socket, delete_files: params["delete_files"] == "true")}
  end

  def handle_event("delete_library", params, socket) do
    delete_files = params["delete_files"] == "true"
    {:ok, library} = Libraries.delete_library(socket.assigns.library, delete_files: delete_files)

    {:noreply,
     socket
     |> put_flash(
       :info,
       "Deleted “#{library.name}”" <>
         if(delete_files, do: " and its files.", else: ". Files were kept on disk.")
     )
     |> push_navigate(to: ~p"/")}
  end

  # categories

  def handle_event("create_category", %{"category" => params}, socket) do
    case Libraries.create_category(socket.assigns.library, params) do
      {:ok, _} ->
        {:noreply,
         assign(socket,
           categories: Libraries.list_categories(socket.assigns.library),
           category_form: new_category_form()
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, category_form: to_form(changeset))}
    end
  end

  def handle_event("edit_category", %{"id" => id}, socket) do
    {:noreply, assign(socket, editing_category: String.to_integer(id))}
  end

  def handle_event("rename_category", %{"category_id" => id, "name" => name}, socket) do
    category = Libraries.get_category!(String.to_integer(id))

    socket =
      case Libraries.rename_category(category, name) do
        {:ok, _} -> assign(socket, editing_category: nil)
        {:error, _} -> put_flash(socket, :error, "That name is empty or already used.")
      end

    {:noreply, assign(socket, categories: Libraries.list_categories(socket.assigns.library))}
  end

  def handle_event("move_category", %{"id" => id, "dir" => dir}, socket) do
    category = Libraries.get_category!(String.to_integer(id))
    Libraries.move_category(category, if(dir == "up", do: -1, else: 1))
    {:noreply, assign(socket, categories: Libraries.list_categories(socket.assigns.library))}
  end

  def handle_event("delete_category", %{"id" => id}, socket) do
    id = String.to_integer(id)
    {:ok, _} = Libraries.delete_category(Libraries.get_category!(id))

    socket = assign(socket, categories: Libraries.list_categories(socket.assigns.library))

    if socket.assigns.category_id == id,
      do: {:noreply, push_patch(socket, to: self_path(socket, category: nil))},
      else: {:noreply, socket}
  end

  defp new_category_form do
    to_form(Libraries.change_category(%Archive.Libraries.Category{}))
  end

  # --- live updates ---------------------------------------------------------------

  @impl true
  def handle_info({:video_added, video}, socket) do
    a = socket.assigns

    if a.library && video.library_id == a.library.id do
      socket = assign(socket, :count, a.count + 1)

      # New videos only show up immediately in the default, unfiltered view.
      if a.sort == "added_desc" and a.category_id == nil and a.lq == "" do
        {:noreply, stream_insert(socket, :videos, video, at: 0)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:video_deleted, video}, socket) do
    if socket.assigns.library && video.library_id == socket.assigns.library.id do
      {:noreply,
       socket
       |> assign(:count, max(socket.assigns.count - 1, 0))
       |> stream_delete(:videos, video)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:video_updated, video}, socket) do
    if socket.assigns.library && video.library_id != socket.assigns.library.id do
      {:noreply, stream_delete(socket, :videos, video)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:videos_changed, library_id}, socket) do
    if (socket.assigns.library && socket.assigns.library.id == library_id) and
         socket.assigns.category_id do
      {:noreply, reset_videos(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:libraries_changed}, socket) do
    case socket.assigns.library &&
           Archive.Repo.get(Archive.Libraries.Library, socket.assigns.library.id) do
      nil ->
        {:noreply, socket}

      library ->
        {:noreply,
         assign(socket,
           library: library,
           categories: Libraries.list_categories(library),
           count: Libraries.count_videos(library)
         )}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- render -----------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :sort_labels, @sort_labels)

    ~H"""
    <Layouts.app
      flash={@flash}
      nav_libraries={@nav_libraries}
      active_downloads={@active_downloads}
      search_query={@search_query}
      active={@library && {:library, @library.id}}
      add_library_id={@library && @library.id}
    >
      <div :if={@library} id="library-page">
        <header class="mb-5 flex flex-wrap items-start justify-between gap-4">
          <div class="min-w-0">
            <h1 class="text-2xl font-bold tracking-tight" id="library-name">{@library.name}</h1>
            <p class="mt-1 text-sm text-base-content/60">
              {@count} {if @count == 1, do: "video", else: "videos"}
              <span :if={@library.source_url}>
                ·
                <a href={@library.source_url} target="_blank" rel="noopener" class="hover:underline">source</a>
                <span :if={@library.last_synced_at}>· synced {time_ago(@library.last_synced_at)}</span>
              </span>
            </p>
            <p :if={@library.description} class="mt-2 max-w-3xl text-sm text-base-content/80">
              {@library.description}
            </p>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <button
              :if={@library.source_url}
              id="sync-library"
              class="btn btn-sm btn-soft btn-primary rounded-full"
              phx-click="sync"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Sync now
            </button>
            <button
              class="btn btn-sm btn-ghost rounded-full"
              phx-click="open"
              phx-value-library_id={@library.id}
              phx-target="#add-video"
            >
              <.icon name="hero-plus" class="size-4" /> Add
            </button>
            <button
              id="toggle-select-mode"
              class={[
                "btn btn-sm rounded-full",
                if(@select_mode, do: "btn-neutral", else: "btn-ghost")
              ]}
              phx-click="toggle_select_mode"
            >
              <.icon name="hero-check-circle" class="size-4" />
              {if @select_mode, do: "Done", else: "Select"}
            </button>
            <div class="dropdown dropdown-end">
              <div
                tabindex="0"
                role="button"
                class="btn btn-sm btn-ghost btn-circle"
                aria-label="More"
              >
                <.icon name="hero-ellipsis-vertical" class="size-5" />
              </div>
              <ul
                tabindex="0"
                class="menu dropdown-content z-30 mt-1 w-52 rounded-box bg-base-100 p-2 shadow-lg ring-1 ring-base-300"
              >
                <li>
                  <a id="edit-library" phx-click="open_modal" phx-value-modal="edit"><.icon
                    name="hero-pencil-square"
                    class="size-4"
                  /> Edit library</a>
                </li>
                <li>
                  <a id="manage-categories" phx-click="open_modal" phx-value-modal="categories"><.icon
                    name="hero-tag"
                    class="size-4"
                  /> Manage categories</a>
                </li>
                <li>
                  <a
                    id="delete-library"
                    phx-click="open_modal"
                    phx-value-modal="delete"
                    class="text-error"
                  ><.icon name="hero-trash" class="size-4" /> Delete library</a>
                </li>
              </ul>
            </div>
          </div>
        </header>

        <div class="sticky top-14 z-20 -mx-4 mb-5 flex flex-wrap items-center gap-3 bg-base-100/90 px-4 py-2.5 backdrop-blur-md sm:-mx-6 sm:px-6">
          <div id="category-chips" class="scrollbar-none flex min-w-0 flex-1 gap-2 overflow-x-auto">
            <button
              phx-click="filter_category"
              phx-value-id=""
              class={chip_class(@category_id == nil)}
            >
              All
            </button>
            <button
              :for={category <- @categories}
              id={"chip-#{category.id}"}
              phx-click="filter_category"
              phx-value-id={category.id}
              class={chip_class(@category_id == category.id)}
            >
              {category.name}
            </button>
            <button
              phx-click="open_modal"
              phx-value-modal="categories"
              class="shrink-0 rounded-lg px-2.5 py-1.5 text-sm text-base-content/60 hover:bg-base-200 hover:text-base-content"
              title="Manage categories"
            >
              <.icon name="hero-plus-mini" class="size-4" />
              <span :if={@categories == []}>Add category</span>
            </button>
          </div>
          <form
            id="library-search"
            phx-change="library_search"
            phx-submit="library_search"
            class="w-full sm:w-56"
          >
            <input
              type="search"
              name="q"
              value={@lq}
              phx-debounce="250"
              placeholder="Filter this library"
              autocomplete="off"
              class="h-9 w-full rounded-lg border border-base-300 bg-base-100 px-3 text-sm outline-none focus:border-primary/60 focus:ring-4 focus:ring-primary/10"
            />
          </form>
          <form id="library-sort" phx-change="sort">
            <select
              name="sort"
              class="h-9 rounded-lg border border-base-300 bg-base-100 px-2 text-sm outline-none focus:border-primary/60"
            >
              <option :for={{label, value} <- @sort_labels} value={value} selected={value == @sort}>
                {label}
              </option>
            </select>
          </form>
        </div>

        <div
          id="library-videos"
          phx-update="stream"
          phx-viewport-bottom={!@end_of_list? && "load_more"}
          class={grid_class()}
        >
          <div id="library-empty" class="col-span-full hidden only:block">
            <.empty_state
              :if={@lq != "" or @category_id}
              icon="hero-funnel"
              title="Nothing here"
              subtitle="No videos match this filter."
            />
            <.empty_state
              :if={@lq == "" and is_nil(@category_id)}
              icon="hero-rectangle-stack"
              title="This library is empty"
              subtitle="Add a video or playlist URL, or import existing files into it."
            />
          </div>
          <.video_card
            :for={{dom_id, video} <- @streams.videos}
            id={dom_id}
            video={video}
            selectable={@select_mode}
            selected={MapSet.member?(@selected, video.id)}
          />
        </div>
        <div :if={!@end_of_list?} class="flex justify-center py-10 text-base-content/40">
          <span class="loading loading-dots loading-md"></span>
        </div>

        <%!-- bulk action bar --%>
        <div
          :if={@select_mode and MapSet.size(@selected) > 0}
          id="bulk-actions"
          class="fixed inset-x-0 bottom-4 z-40 mx-auto flex w-fit max-w-[calc(100%-2rem)] flex-wrap items-center gap-2 rounded-2xl bg-neutral px-4 py-3 text-neutral-content shadow-2xl"
        >
          <span class="mr-2 text-sm font-semibold">{MapSet.size(@selected)} selected</span>
          <form
            :if={@categories != []}
            id="bulk-category-form"
            phx-submit="bulk_category"
            class="flex items-center gap-1"
          >
            <select
              name="category_id"
              class="h-8 rounded-lg bg-neutral-content/10 px-2 text-sm text-neutral-content"
            >
              <option value="">Category…</option>
              <option :for={c <- @categories} value={c.id}>{c.name}</option>
            </select>
            <button name="action" value="add" class="btn btn-xs btn-primary">Add</button>
            <button name="action" value="remove" class="btn btn-xs btn-ghost">Remove</button>
          </form>
          <form id="bulk-move-form" phx-submit="bulk_move" class="flex items-center gap-1">
            <select
              name="library_id"
              class="h-8 rounded-lg bg-neutral-content/10 px-2 text-sm text-neutral-content"
            >
              <option value="">Move to…</option>
              <option :for={l <- @nav_libraries} :if={l.id != @library.id} value={l.id}>
                {l.name}
              </option>
            </select>
            <button class="btn btn-xs btn-ghost">Move</button>
          </form>
          <button phx-click="clear_selection" class="btn btn-xs btn-ghost">Clear</button>
        </div>

        <%!-- modals --%>
        <.modal
          :if={@modal == :edit}
          id="edit-library-modal"
          on_close="close_modal"
          title="Edit library"
        >
          <.form
            for={@library_form}
            id="edit-library-form"
            phx-change="validate_library"
            phx-submit="save_library"
          >
            <.input field={@library_form[:name]} type="text" label="Name" required />
            <.input field={@library_form[:description]} type="textarea" label="Description" rows="2" />
            <.input
              field={@library_form[:source_url]}
              type="url"
              label="Source playlist/channel URL"
              placeholder="https://…"
            />
            <p class="-mt-1 text-xs text-base-content/50">
              Renaming the library also renames its folder on disk.
            </p>
            <div class="mt-6 flex justify-end gap-2">
              <button type="button" class="btn btn-ghost" phx-click="close_modal">Cancel</button>
              <button class="btn btn-primary" phx-disable-with="Saving…">Save</button>
            </div>
          </.form>
        </.modal>

        <.modal
          :if={@modal == :delete}
          id="delete-library-modal"
          on_close="close_modal"
          title="Delete library?"
        >
          <form id="delete-library-form" phx-change="toggle_delete_files" phx-submit="delete_library">
            <p class="text-sm text-base-content/70">
              “{@library.name}” and its {@count} video(s) will be removed from the archive.
            </p>
            <label class="mt-4 flex cursor-pointer items-start gap-3 rounded-xl border border-base-300 p-3">
              <input type="hidden" name="delete_files" value="false" />
              <input
                type="checkbox"
                name="delete_files"
                value="true"
                checked={@delete_files}
                class="checkbox checkbox-error mt-0.5"
              />
              <span class="text-sm">
                <span class="font-medium">Also delete files from disk</span>
                <span class="block text-base-content/60">Removes the folder
                <code class="text-xs">{@library.slug}/</code>
                with all videos, thumbnails and subtitles.</span>
              </span>
            </label>
            <div class="mt-6 flex justify-end gap-2">
              <button type="button" class="btn btn-ghost" phx-click="close_modal">Cancel</button>
              <button class="btn btn-error" phx-disable-with="Deleting…">
                {if @delete_files, do: "Delete library and files", else: "Delete library"}
              </button>
            </div>
          </form>
        </.modal>

        <.modal
          :if={@modal == :categories}
          id="categories-modal"
          on_close="close_modal"
          title="Categories"
        >
          <p class="mb-4 text-sm text-base-content/60">
            Categories belong to this library. A video can be in several of them.
          </p>
          <ul id="category-list" class="divide-y divide-base-300 rounded-xl border border-base-300">
            <li
              :for={{category, i} <- Enum.with_index(@categories)}
              id={"category-#{category.id}"}
              class="flex items-center gap-2 px-3 py-2"
            >
              <%= if @editing_category == category.id do %>
                <form
                  id={"rename-category-#{category.id}"}
                  phx-submit="rename_category"
                  class="flex flex-1 gap-2"
                >
                  <input type="hidden" name="category_id" value={category.id} />
                  <input
                    name="name"
                    value={category.name}
                    class="input input-sm flex-1"
                    phx-mounted={JS.focus()}
                  />
                  <button class="btn btn-sm btn-primary">Save</button>
                </form>
              <% else %>
                <span class="flex-1 truncate text-sm">{category.name}</span>
                <button
                  class="btn btn-ghost btn-xs btn-square"
                  disabled={i == 0}
                  phx-click="move_category"
                  phx-value-id={category.id}
                  phx-value-dir="up"
                  aria-label="Move up"
                >
                  <.icon name="hero-chevron-up-mini" class="size-4" />
                </button>
                <button
                  class="btn btn-ghost btn-xs btn-square"
                  disabled={i == length(@categories) - 1}
                  phx-click="move_category"
                  phx-value-id={category.id}
                  phx-value-dir="down"
                  aria-label="Move down"
                >
                  <.icon name="hero-chevron-down-mini" class="size-4" />
                </button>
                <button
                  class="btn btn-ghost btn-xs btn-square"
                  phx-click="edit_category"
                  phx-value-id={category.id}
                  aria-label="Rename"
                >
                  <.icon name="hero-pencil-mini" class="size-4" />
                </button>
                <button
                  class="btn btn-ghost btn-xs btn-square text-error"
                  phx-click="delete_category"
                  phx-value-id={category.id}
                  data-confirm={"Delete category “#{category.name}”? Videos stay in the library."}
                  aria-label="Delete"
                >
                  <.icon name="hero-trash-mini" class="size-4" />
                </button>
              <% end %>
            </li>
            <li :if={@categories == []} class="px-3 py-3 text-sm text-base-content/50">
              No categories yet.
            </li>
          </ul>
          <.form
            for={@category_form}
            id="new-category-form"
            phx-submit="create_category"
            class="mt-4 flex items-start gap-2"
          >
            <div class="flex-1">
              <.input field={@category_form[:name]} type="text" placeholder="New category name" />
            </div>
            <button class="btn btn-primary mt-1">Add</button>
          </.form>
        </.modal>
      </div>
    </Layouts.app>
    """
  end

  defp chip_class(active?) do
    [
      "shrink-0 rounded-lg px-3 py-1.5 text-sm font-medium transition",
      if(active?,
        do: "bg-base-content text-base-100",
        else: "bg-base-200 text-base-content hover:bg-base-300"
      )
    ]
  end
end
