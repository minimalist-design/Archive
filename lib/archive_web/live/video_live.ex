defmodule ArchiveWeb.VideoLive do
  @moduledoc "Watch page: player, metadata, categories, move/delete and related videos."
  use ArchiveWeb, :live_view

  alias Archive.{Libraries, Videos}
  alias Archive.Media.Probe

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, modal: nil, delete_files: false, show_full_description: false)}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    with {int_id, ""} <- Integer.parse(id),
         %{} = video <- Videos.get_video(int_id) do
      video = Videos.get_video!(video.id)

      {:noreply,
       socket
       |> assign(
         video: video,
         page_title: video.title,
         categories: Libraries.list_categories(video.library_id),
         related: Videos.related(video),
         modal: nil,
         show_full_description: false
       )}
    else
      _ ->
        # Rendered as a 404 page by phoenix_ecto.
        raise Ecto.NoResultsError, queryable: Archive.Videos.Video
    end
  end

  @impl true
  def handle_event("set_categories", params, socket) do
    ids = params |> Map.get("category_ids", []) |> Enum.reject(&(&1 == ""))
    {:ok, _} = Videos.set_categories(socket.assigns.video, ids)
    {:noreply, assign(socket, video: Videos.get_video!(socket.assigns.video.id))}
  end

  def handle_event("toggle_description", _params, socket) do
    {:noreply, assign(socket, show_full_description: !socket.assigns.show_full_description)}
  end

  def handle_event("open_modal", %{"modal" => modal}, socket)
      when modal in ["delete", "move", "rename"] do
    {:noreply, assign(socket, modal: String.to_existing_atom(modal), delete_files: false)}
  end

  def handle_event("close_modal", _params, socket), do: {:noreply, assign(socket, modal: nil)}

  def handle_event("rename", %{"title" => title}, socket) do
    case Videos.update_title(socket.assigns.video, title) do
      {:ok, _} ->
        video = Videos.get_video!(socket.assigns.video.id)
        {:noreply, assign(socket, video: video, modal: nil, page_title: video.title)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "The title can't be empty.")}
    end
  end

  def handle_event("move", %{"library_id" => library_id}, socket) when library_id != "" do
    target = Libraries.get_library!(String.to_integer(library_id))

    case Videos.move_to_library(socket.assigns.video, target) do
      {:ok, video} ->
        {:noreply,
         socket
         |> assign(
           video: video,
           modal: nil,
           categories: Libraries.list_categories(video.library_id),
           related: Videos.related(video)
         )
         |> put_flash(:info, "Moved to “#{target.name}”.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not move the files: #{inspect(reason)}")}
    end
  end

  def handle_event("move", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_delete_files", params, socket) do
    {:noreply, assign(socket, delete_files: params["delete_files"] == "true")}
  end

  def handle_event("delete", params, socket) do
    video = socket.assigns.video
    delete_files = params["delete_files"] == "true"
    {:ok, _} = Videos.delete_video(video, delete_files: delete_files)

    {:noreply,
     socket
     |> put_flash(
       :info,
       "Deleted “#{video.title}”" <>
         if(delete_files, do: " and its files.", else: ". Files were kept on disk.")
     )
     |> push_navigate(to: ~p"/libraries/#{video.library.slug}")}
  end

  @impl true
  def handle_info({:libraries_changed}, socket) do
    {:noreply,
     assign(socket, categories: Libraries.list_categories(socket.assigns.video.library_id))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav_libraries={@nav_libraries}
      active_downloads={@active_downloads}
      search_query={@search_query}
      active={{:library, @video.library_id}}
      add_library_id={@video.library_id}
    >
      <div class="mx-auto grid max-w-[1700px] gap-6 xl:grid-cols-[minmax(0,1fr)_380px]">
        <div class="min-w-0">
          <div
            id={"player-#{@video.id}"}
            phx-hook="Player"
            phx-update="ignore"
            data-mode={@video.playback}
            data-direct={~p"/media/videos/#{@video.id}/file"}
            data-hls={~p"/media/videos/#{@video.id}/hls/index.m3u8"}
            data-mime={Probe.mime_type(@video.file_path)}
            class="relative overflow-hidden rounded-2xl bg-black shadow-lg"
          >
            <video
              controls
              playsinline
              preload="metadata"
              poster={~p"/media/videos/#{@video.id}/thumb/full"}
              class="aspect-video w-full bg-black"
            >
              <track
                :for={sub <- @video.subtitles}
                kind="subtitles"
                src={~p"/media/subtitles/#{sub.id}"}
                srclang={sub.lang |> String.split("-") |> hd()}
                label={subtitle_label(sub)}
              />
            </video>
            <div
              data-transcode-notice
              hidden
              class="pointer-events-none absolute left-3 top-3 rounded-md bg-black/60 px-2 py-1 text-[11px] font-medium text-white/80"
            >
              Transcoding on the fly
            </div>
          </div>

          <div :if={@video.status == "missing"} class="alert alert-error mt-4">
            <.icon name="hero-exclamation-triangle" class="size-5" />
            The video file is missing from disk ({@video.file_path}).
          </div>

          <h1 id="video-title" class="mt-4 text-xl font-bold leading-snug">{@video.title}</h1>

          <div class="mt-3 flex flex-wrap items-center justify-between gap-3">
            <div class="flex min-w-0 items-center gap-3">
              <div class="grid size-10 shrink-0 place-items-center rounded-full bg-base-200 text-sm font-bold uppercase text-base-content/70">
                {initial(Archive.Videos.Video.display_uploader(@video) || @video.library.name)}
              </div>
              <div class="min-w-0">
                <p class="truncate font-semibold">
                  {Archive.Videos.Video.display_uploader(@video) || "Unknown uploader"}
                </p>
                <.link
                  navigate={~p"/libraries/#{@video.library.slug}"}
                  class="text-xs text-base-content/60 hover:underline"
                >
                  in {@video.library.name}
                </.link>
              </div>
            </div>
            <div class="flex flex-wrap items-center gap-2">
              <a
                :if={@video.webpage_url}
                href={@video.webpage_url}
                target="_blank"
                rel="noopener noreferrer"
                class="btn btn-sm btn-soft rounded-full"
              >
                <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Original
              </a>
              <a
                href={~p"/media/videos/#{@video.id}/file"}
                download
                class="btn btn-sm btn-soft rounded-full"
              >
                <.icon name="hero-arrow-down-tray" class="size-4" /> File
              </a>
              <button
                id="rename-video"
                phx-click="open_modal"
                phx-value-modal="rename"
                class="btn btn-sm btn-soft rounded-full"
              >
                <.icon name="hero-pencil" class="size-4" /> Rename
              </button>
              <button
                id="move-video"
                phx-click="open_modal"
                phx-value-modal="move"
                class="btn btn-sm btn-soft rounded-full"
              >
                <.icon name="hero-arrows-right-left" class="size-4" /> Move
              </button>
              <button
                id="delete-video"
                phx-click="open_modal"
                phx-value-modal="delete"
                class="btn btn-sm btn-soft btn-error rounded-full"
              >
                <.icon name="hero-trash" class="size-4" /> Delete
              </button>
            </div>
          </div>

          <div class="mt-4 rounded-xl bg-base-200/70 p-4 text-sm">
            <p class="flex flex-wrap gap-x-3 gap-y-1 font-semibold">
              <span :if={@video.metadata["view_count"]}>{format_count(@video.metadata["view_count"])} views</span>
              <span :if={@video.upload_date}>{format_date(@video.upload_date)}</span>
              <span class="font-normal text-base-content/60">
                Archived {format_date(@video.downloaded_at || @video.inserted_at)}
              </span>
            </p>
            <div :if={@video.description} class="mt-2">
              <p class={["whitespace-pre-line break-words", !@show_full_description && "line-clamp-3"]}>
                {@video.description}
              </p>
              <button phx-click="toggle_description" class="mt-1 font-semibold hover:underline">
                {if @show_full_description, do: "Show less", else: "Show more"}
              </button>
            </div>
            <div :if={@video.tags != []} class="mt-3 flex flex-wrap gap-1.5">
              <.link
                :for={tag <- Enum.take(@video.tags, 30)}
                navigate={~p"/?#{[q: tag]}"}
                class="rounded-full bg-base-100 px-2.5 py-0.5 text-xs text-base-content/70 hover:text-primary"
              >
                #{tag}
              </.link>
            </div>
            <div class="mt-4 grid grid-cols-2 gap-x-6 gap-y-1 text-xs text-base-content/60 sm:grid-cols-4">
              <p :if={@video.height}>Resolution: {@video.width}×{@video.height}</p>
              <p :if={@video.vcodec}>
                Codecs: {@video.vcodec}{if @video.acodec, do: " / #{@video.acodec}"}
              </p>
              <p>Container: {@video.container}</p>
              <p>Size: {format_bytes(@video.filesize)}</p>
              <p>Playback: {if @video.playback == "direct", do: "direct", else: "transcoded"}</p>
              <p :if={@video.subtitles != []}>
                Subtitles: {Enum.map_join(@video.subtitles, ", ", & &1.lang)}
              </p>
              <p class="col-span-full truncate" title={@video.file_path}>File: {@video.file_path}</p>
            </div>
          </div>

          <section class="mt-4">
            <h2 class="mb-2 text-sm font-semibold">Categories</h2>
            <form
              :if={@categories != []}
              id="video-categories"
              phx-change="set_categories"
              class="flex flex-wrap gap-2"
            >
              <input type="hidden" name="category_ids[]" value="" />
              <label
                :for={category <- @categories}
                class={[
                  "cursor-pointer select-none rounded-full border px-3 py-1 text-sm transition",
                  if(Enum.any?(@video.categories, &(&1.id == category.id)),
                    do: "border-primary bg-primary/10 text-primary",
                    else: "border-base-300 hover:bg-base-200"
                  )
                ]}
              >
                <input
                  type="checkbox"
                  name="category_ids[]"
                  value={category.id}
                  checked={Enum.any?(@video.categories, &(&1.id == category.id))}
                  class="hidden"
                />
                {category.name}
              </label>
            </form>
            <p :if={@categories == []} class="text-sm text-base-content/60">
              This library has no categories yet.
              <.link
                navigate={~p"/libraries/#{@video.library.slug}"}
                class="text-primary hover:underline"
              >Create some on the library page.</.link>
            </p>
          </section>
        </div>

        <aside class="min-w-0">
          <h2 class="mb-3 text-sm font-semibold">More from {@video.library.name}</h2>
          <div id="related-videos" class="space-y-3">
            <.link
              :for={video <- @related}
              id={"related-#{video.id}"}
              navigate={~p"/videos/#{video.id}"}
              class="group flex gap-3"
            >
              <div class="relative aspect-video w-40 shrink-0 overflow-hidden rounded-lg bg-base-300">
                <img
                  src={~p"/media/videos/#{video.id}/thumb"}
                  loading="lazy"
                  alt=""
                  class="size-full object-cover"
                />
                <span
                  :if={video.duration}
                  class="absolute bottom-1 right-1 rounded bg-black/80 px-1 text-[10px] font-medium text-white"
                >
                  {format_duration(video.duration)}
                </span>
              </div>
              <div class="min-w-0">
                <p class="line-clamp-2 text-sm font-semibold leading-snug group-hover:text-primary">
                  {video.title}
                </p>
                <p class="mt-1 truncate text-xs text-base-content/60">
                  {Archive.Videos.Video.display_uploader(video)}
                </p>
              </div>
            </.link>
            <p :if={@related == []} class="text-sm text-base-content/50">No other videos yet.</p>
          </div>
        </aside>
      </div>

      <.modal :if={@modal == :rename} id="rename-modal" on_close="close_modal" title="Rename video">
        <form id="rename-form" phx-submit="rename">
          <input name="title" value={@video.title} class="input w-full" phx-mounted={JS.focus()} />
          <p class="mt-2 text-xs text-base-content/50">
            Only the title shown in the archive changes; files keep their names.
          </p>
          <div class="mt-6 flex justify-end gap-2">
            <button type="button" class="btn btn-ghost" phx-click="close_modal">Cancel</button>
            <button class="btn btn-primary">Save</button>
          </div>
        </form>
      </.modal>

      <.modal
        :if={@modal == :move}
        id="move-modal"
        on_close="close_modal"
        title="Move to another library"
      >
        <form id="move-form" phx-submit="move">
          <select name="library_id" class="select w-full">
            <option :for={l <- @nav_libraries} :if={l.id != @video.library_id} value={l.id}>
              {l.name}
            </option>
          </select>
          <p class="mt-2 text-xs text-base-content/50">
            The files move to the other library’s folder. Categories are cleared because they belong to a library.
          </p>
          <div class="mt-6 flex justify-end gap-2">
            <button type="button" class="btn btn-ghost" phx-click="close_modal">Cancel</button>
            <button class="btn btn-primary" disabled={length(@nav_libraries) < 2}>Move</button>
          </div>
        </form>
      </.modal>

      <.modal
        :if={@modal == :delete}
        id="delete-video-modal"
        on_close="close_modal"
        title="Delete video?"
      >
        <form id="delete-video-form" phx-change="toggle_delete_files" phx-submit="delete">
          <p class="text-sm text-base-content/70">
            “{@video.title}” will be removed from the archive.
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
              <span class="block text-base-content/60">The video file, its thumbnail, metadata and subtitles.</span>
            </span>
          </label>
          <div class="mt-6 flex justify-end gap-2">
            <button type="button" class="btn btn-ghost" phx-click="close_modal">Cancel</button>
            <button class="btn btn-error">{if @delete_files,
              do: "Delete video and files",
              else: "Delete video"}</button>
          </div>
        </form>
      </.modal>
    </Layouts.app>
    """
  end

  defp subtitle_label(sub) do
    if sub.auto, do: "#{sub.lang} (auto)", else: sub.lang
  end

  defp initial(nil), do: "?"
  defp initial(name), do: String.first(name)
end
