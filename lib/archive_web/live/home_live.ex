defmodule ArchiveWeb.HomeLive do
  @moduledoc """
  Home page: one shelf of recent videos per library. A search query (from the
  top bar, kept in `?q=`) replaces the shelves with a ranked results grid.
  """
  use ArchiveWeb, :live_view

  alias Archive.{Search, Videos}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Home", shelves: [], results: [], query: "")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    query = params |> Map.get("q", "") |> String.trim()

    socket =
      socket
      |> assign(query: query, search_query: query)
      |> load()

    {:noreply, socket}
  end

  defp load(%{assigns: %{query: ""}} = socket) do
    socket
    |> assign(:results, [])
    |> assign(:shelves, Videos.shelves(socket.assigns.nav_libraries))
    |> assign(:page_title, "Home")
  end

  defp load(%{assigns: %{query: query}} = socket) do
    socket
    |> assign(:results, Search.search(query, limit: 60))
    |> assign(:page_title, "Search: #{query}")
  end

  @impl true
  def handle_info({event, _}, socket)
      when event in [:video_added, :video_deleted, :video_updated] do
    if socket.assigns.query == "" do
      {:noreply, assign(socket, :shelves, Videos.shelves(socket.assigns.nav_libraries))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:libraries_changed}, socket) do
    {:noreply, load(socket)}
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
      active={:home}
    >
      <%= if @query != "" do %>
        <div id="search-results-view">
          <div class="mb-6 flex items-baseline gap-3">
            <h1 class="text-xl font-bold">Results for “{@query}”</h1>
            <span class="text-sm text-base-content/50">
              {length(@results)}{if length(@results) == 60, do: "+"} videos
            </span>
          </div>
          <div :if={@results != []} id="search-results" class={grid_class()}>
            <.video_card
              :for={video <- @results}
              id={"result-#{video.id}"}
              video={video}
              show_library
            />
          </div>
          <.empty_state
            :if={@results == []}
            icon="hero-magnifying-glass"
            title="No matches"
            subtitle="Try other words. Titles, descriptions, tags and subtitles are searched."
          />
        </div>
      <% else %>
        <div id="shelves" class="space-y-10">
          <section :for={{library, videos} <- @shelves} id={"shelf-#{library.id}"}>
            <div class="mb-3 flex items-center justify-between gap-4">
              <.link navigate={~p"/libraries/#{library.slug}"} class="group flex items-center gap-2">
                <h2 class="text-xl font-bold group-hover:text-primary">{library.name}</h2>
                <span class="text-sm text-base-content/50">{library.video_count}</span>
              </.link>
              <.link
                navigate={~p"/libraries/#{library.slug}"}
                class="inline-flex items-center gap-1 rounded-full px-3 py-1.5 text-sm font-medium text-primary hover:bg-primary/10"
              >
                See all <.icon name="hero-arrow-right-mini" class="size-4" />
              </.link>
            </div>
            <div class="scrollbar-thin -mx-1 flex snap-x gap-4 overflow-x-auto px-1 pb-3">
              <.video_card
                :for={video <- videos}
                id={"shelf-#{library.id}-video-#{video.id}"}
                video={video}
                class="w-64 shrink-0 snap-start sm:w-72"
              />
            </div>
          </section>

          <.empty_state
            :if={@shelves == []}
            icon="hero-film"
            title="Your archive is empty"
            subtitle="Add a video or playlist URL from any site yt-dlp supports, or import files you already have."
          >
            <div class="flex flex-wrap justify-center gap-2">
              <button phx-click="open" phx-target="#add-video" class="btn btn-primary">
                <.icon name="hero-plus" class="size-4" /> Add videos
              </button>
              <.link navigate={~p"/import"} class="btn btn-ghost">
                <.icon name="hero-folder-arrow-down" class="size-4" /> Import files
              </.link>
            </div>
          </.empty_state>
        </div>
      <% end %>
    </Layouts.app>
    """
  end
end
