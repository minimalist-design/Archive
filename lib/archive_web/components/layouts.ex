defmodule ArchiveWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use ArchiveWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  The app shell: top bar with live search and the Add button, sidebar with the
  libraries, and the page content.
  """
  attr :flash, :map, required: true
  attr :nav_libraries, :list, default: []
  attr :active_downloads, :integer, default: 0
  attr :search_query, :string, default: ""

  attr :active, :any,
    default: nil,
    doc: ":home | :downloads | :import | :settings | {:library, id}"

  attr :add_library_id, :any, default: nil, doc: "library preselected in the Add dialog"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-100 text-base-content">
      <header class="sticky top-0 z-40 flex h-14 items-center gap-2 border-b border-base-300/70 bg-base-100/90 px-3 backdrop-blur-md sm:gap-4 sm:px-4">
        <button
          type="button"
          class="grid size-10 place-items-center rounded-full hover:bg-base-200 lg:hidden"
          phx-click={toggle_sidebar()}
          aria-label="Toggle sidebar"
        >
          <.icon name="hero-bars-3" class="size-5" />
        </button>
        <.link navigate={~p"/"} class="flex shrink-0 items-center gap-2" id="logo-link">
          <span class="grid size-8 place-items-center rounded-lg bg-primary text-primary-content shadow-sm">
            <.icon name="hero-play-solid" class="size-4" />
          </span>
          <span class="hidden text-[17px] font-bold tracking-tight sm:inline">Archive</span>
        </.link>

        <form
          id="global-search"
          class="mx-auto flex w-full max-w-2xl items-center"
          phx-change="global_search"
          phx-submit="global_search"
          role="search"
        >
          <label class="relative flex w-full items-center">
            <.icon
              name="hero-magnifying-glass"
              class="pointer-events-none absolute left-4 size-4 text-base-content/50"
            />
            <input
              type="search"
              name="q"
              id="global-search-input"
              value={@search_query}
              phx-debounce="250"
              autocomplete="off"
              placeholder="Search titles, descriptions, tags and subtitles"
              class="h-10 w-full rounded-full border border-base-300 bg-base-200/60 pl-10 pr-4 text-sm outline-none transition placeholder:text-base-content/40 focus:border-primary/60 focus:bg-base-100 focus:ring-4 focus:ring-primary/10"
            />
          </label>
        </form>

        <button
          type="button"
          id="open-add-video"
          phx-click="open"
          phx-value-library_id={@add_library_id}
          phx-target="#add-video"
          class="inline-flex h-9 shrink-0 items-center gap-1.5 rounded-full bg-primary px-3.5 text-sm font-semibold text-primary-content shadow-sm transition hover:brightness-110 active:scale-95"
        >
          <.icon name="hero-plus" class="size-4" />
          <span class="hidden sm:inline">Add</span>
        </button>
        <div class="hidden md:block"><.theme_toggle /></div>
      </header>

      <div class="flex">
        <div
          id="sidebar-backdrop"
          class="fixed inset-0 top-14 z-20 hidden bg-black/40 lg:hidden"
          phx-click={toggle_sidebar()}
        />
        <aside
          id="sidebar"
          class="fixed top-14 z-30 h-[calc(100vh-3.5rem)] w-64 shrink-0 -translate-x-full overflow-y-auto border-r border-base-300/70 bg-base-100 px-3 py-4 transition-transform duration-200 lg:sticky lg:translate-x-0 lg:border-r-0"
        >
          <nav class="space-y-0.5">
            <.nav_link navigate={~p"/"} icon="hero-home" active={@active == :home}>Home</.nav_link>
            <.nav_link
              navigate={~p"/downloads"}
              icon="hero-arrow-down-tray"
              active={@active == :downloads}
            >
              Downloads
              <span
                :if={@active_downloads > 0}
                id="downloads-badge"
                class="ml-auto rounded-full bg-primary px-2 py-0.5 text-[11px] font-semibold tabular-nums text-primary-content"
              >
                {@active_downloads}
              </span>
            </.nav_link>
            <.nav_link
              navigate={~p"/import"}
              icon="hero-folder-arrow-down"
              active={@active == :import}
            >
              Import
            </.nav_link>
            <.nav_link navigate={~p"/settings"} icon="hero-cog-6-tooth" active={@active == :settings}>
              Settings
            </.nav_link>
          </nav>

          <div class="mt-6 flex items-center justify-between px-3">
            <h2 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
              Libraries
            </h2>
            <button
              type="button"
              id="open-new-library"
              phx-click="open"
              phx-target="#new-library"
              class="grid size-7 place-items-center rounded-full text-base-content/60 hover:bg-base-200 hover:text-base-content"
              title="New library"
            >
              <.icon name="hero-plus" class="size-4" />
            </button>
          </div>
          <nav id="sidebar-libraries" class="mt-2 space-y-0.5">
            <.nav_link
              :for={library <- @nav_libraries}
              id={"nav-library-#{library.id}"}
              navigate={~p"/libraries/#{library.slug}"}
              icon="hero-rectangle-stack"
              active={@active == {:library, library.id}}
            >
              <span class="truncate">{library.name}</span>
              <span class="ml-auto text-xs tabular-nums text-base-content/40">{library.video_count}</span>
            </.nav_link>
            <p :if={@nav_libraries == []} class="px-3 py-2 text-sm text-base-content/50">
              No libraries yet.
            </p>
          </nav>
          <div class="mt-8 px-3 md:hidden"><.theme_toggle /></div>
        </aside>

        <main class="min-w-0 flex-1 px-4 pb-16 pt-5 sm:px-6">
          {render_slot(@inner_block)}
        </main>
      </div>

      <.live_component
        module={ArchiveWeb.AddVideoComponent}
        id="add-video"
        libraries={@nav_libraries}
      />
      <.live_component module={ArchiveWeb.NewLibraryComponent} id="new-library" />
      <.flash_group flash={@flash} />
    </div>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, default: false
  attr :id, :string, default: nil
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      class={[
        "flex items-center gap-3 rounded-lg px-3 py-2 text-sm transition",
        if(@active,
          do: "bg-base-200 font-semibold text-base-content",
          else: "text-base-content/80 hover:bg-base-200/70 hover:text-base-content"
        )
      ]}
    >
      <.icon name={@icon} class={["size-5 shrink-0", @active && "text-primary"]} />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  defp toggle_sidebar do
    JS.toggle_class("-translate-x-full", to: "#sidebar")
    |> JS.toggle_class("hidden", to: "#sidebar-backdrop")
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
