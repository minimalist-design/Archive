defmodule ArchiveWeb.DownloadsLive do
  @moduledoc "Live view of the download/import queue with progress, errors, retry and cancel."
  use ArchiveWeb, :live_view

  alias Archive.Downloads
  alias Archive.Tools.Manager

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Archive.Events.subscribe("tools")
    {:ok, socket |> assign(page_title: "Downloads") |> load()}
  end

  defp load(socket) do
    assign(socket, groups: Downloads.list_grouped(), tools_busy: Manager.busy?())
  end

  @impl true
  def handle_event("cancel", %{"id" => id}, socket) do
    Downloads.cancel(Downloads.get_download!(String.to_integer(id)))
    {:noreply, load(socket)}
  end

  def handle_event("retry", %{"id" => id}, socket) do
    Downloads.retry(Downloads.get_download!(String.to_integer(id)))
    {:noreply, load(socket)}
  end

  def handle_event("remove", %{"id" => id}, socket) do
    Downloads.delete(Downloads.get_download!(String.to_integer(id)))
    {:noreply, load(socket)}
  end

  def handle_event("retry_all", _params, socket) do
    Downloads.retry_all_failed()
    {:noreply, load(socket)}
  end

  def handle_event("clear_finished", _params, socket) do
    Downloads.clear_finished()
    {:noreply, load(socket)}
  end

  @impl true
  def handle_info({:download_updated, download}, socket) do
    groups = socket.assigns.groups
    running_ids = Enum.map(groups.running, & &1.id)

    # Fast path for progress ticks: update the row in place.
    if download.status == "running" and download.id in running_ids do
      running =
        Enum.map(groups.running, fn d ->
          if d.id == download.id, do: %{download | library: d.library}, else: d
        end)

      {:noreply, assign(socket, groups: %{groups | running: running})}
    else
      {:noreply, load(socket)}
    end
  end

  def handle_info({:downloads_changed}, socket), do: {:noreply, load(socket)}

  def handle_info({:tools_changed}, socket),
    do: {:noreply, assign(socket, tools_busy: Manager.busy?())}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav_libraries={@nav_libraries}
      active_downloads={@active_downloads}
      search_query={@search_query}
      active={:downloads}
    >
      <div class="mx-auto max-w-5xl">
        <div class="mb-6 flex flex-wrap items-center justify-between gap-3">
          <h1 class="text-2xl font-bold tracking-tight">Downloads</h1>
          <div class="flex gap-2">
            <button
              :if={@groups.failed != []}
              id="retry-all"
              phx-click="retry_all"
              class="btn btn-sm btn-soft rounded-full"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Retry failed
            </button>
            <button
              :if={@groups.finished != []}
              id="clear-finished"
              phx-click="clear_finished"
              class="btn btn-sm btn-ghost rounded-full"
            >
              Clear finished
            </button>
          </div>
        </div>

        <div :if={@tools_busy} class="alert alert-info mb-6 text-sm">
          <span class="loading loading-spinner loading-sm"></span>
          Updating yt-dlp; downloads resume when it's done.
        </div>

        <.section :if={@groups.running != []} title="Downloading" id="running">
          <.row :for={d <- @groups.running} download={d} />
        </.section>
        <.section :if={@groups.queued != []} title={"Queued (#{length(@groups.queued)})"} id="queued">
          <.row :for={d <- Enum.take(@groups.queued, 200)} download={d} />
        </.section>
        <.section :if={@groups.failed != []} title="Failed" id="failed">
          <.row :for={d <- @groups.failed} download={d} />
        </.section>
        <.section :if={@groups.finished != []} title="Finished" id="finished">
          <.row :for={d <- @groups.finished} download={d} />
        </.section>

        <.empty_state
          :if={Enum.all?(Map.values(@groups), &(&1 == []))}
          icon="hero-arrow-down-tray"
          title="Nothing in the queue"
          subtitle="Videos you add show up here while they download."
        >
          <button phx-click="open" phx-target="#add-video" class="btn btn-primary">
            <.icon name="hero-plus" class="size-4" /> Add videos
          </button>
        </.empty_state>
      </div>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :id, :string, required: true
  slot :inner_block, required: true

  defp section(assigns) do
    ~H"""
    <section id={@id} class="mb-8">
      <h2 class="mb-3 text-xs font-semibold uppercase tracking-wider text-base-content/50">
        {@title}
      </h2>
      <ul class="divide-y divide-base-300 overflow-hidden rounded-2xl border border-base-300 bg-base-100">
        {render_slot(@inner_block)}
      </ul>
    </section>
    """
  end

  attr :download, :map, required: true

  defp row(assigns) do
    ~H"""
    <li id={"download-#{@download.id}"} class="px-4 py-3">
      <div class="flex items-start gap-3">
        <div class={[
          "mt-0.5 grid size-8 shrink-0 place-items-center rounded-full",
          status_bg(@download.status)
        ]}>
          <.icon
            name={status_icon(@download)}
            class={["size-4", @download.status == "running" && "animate-pulse"]}
          />
        </div>
        <div class="min-w-0 flex-1">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="truncate text-sm font-medium" title={@download.title}>
                <.link
                  :if={@download.video_id}
                  navigate={~p"/videos/#{@download.video_id}"}
                  class="hover:underline"
                >
                  {@download.title || @download.url}
                </.link>
                <span :if={!@download.video_id}>{@download.title || @download.url}</span>
              </p>
              <p class="mt-0.5 truncate text-xs text-base-content/50">
                <span class="font-medium">{kind_label(@download.kind)}</span>
                <span :if={@download.library}> → {@download.library.name}</span>
                <span :if={@download.title != @download.url}> · {@download.url}</span>
              </p>
            </div>
            <div class="flex shrink-0 items-center gap-1">
              <button
                :if={@download.status in ["queued", "running"]}
                phx-click="cancel"
                phx-value-id={@download.id}
                class="btn btn-ghost btn-xs rounded-full"
              >
                Cancel
              </button>
              <button
                :if={@download.status in ["failed", "cancelled"]}
                phx-click="retry"
                phx-value-id={@download.id}
                class="btn btn-soft btn-primary btn-xs rounded-full"
              >
                Retry
              </button>
              <button
                :if={@download.status not in ["queued", "running"]}
                phx-click="remove"
                phx-value-id={@download.id}
                class="btn btn-ghost btn-xs btn-square rounded-full"
                aria-label="Remove"
              >
                <.icon name="hero-x-mark-mini" class="size-4" />
              </button>
            </div>
          </div>

          <div :if={@download.status == "running"} class="mt-2">
            <div class="h-1.5 overflow-hidden rounded-full bg-base-300">
              <div
                class={[
                  "h-full rounded-full bg-primary transition-[width] duration-700",
                  is_nil(@download.progress) && "w-1/3 animate-pulse"
                ]}
                style={@download.progress && "width: #{@download.progress}%"}
              />
            </div>
            <p class="mt-1 flex gap-3 text-xs tabular-nums text-base-content/60">
              <span :if={@download.progress}>{@download.progress}%</span>
              <span :if={@download.total_bytes}>{format_bytes(@download.downloaded_bytes)} / {format_bytes(
                @download.total_bytes
              )}</span>
              <span :if={@download.speed}>{format_speed(@download.speed)}</span>
              <span :if={@download.eta}>ETA {format_eta(@download.eta)}</span>
              <span :if={@download.note == "processing"}>Processing…</span>
              <span :if={is_nil(@download.progress) and @download.note != "processing"}>Starting…</span>
            </p>
          </div>

          <p
            :if={@download.note && @download.status != "running"}
            class="mt-1 text-xs text-base-content/60"
          >
            {@download.note}
          </p>
          <pre
            :if={@download.error}
            class="mt-2 max-h-40 overflow-auto whitespace-pre-wrap break-words rounded-lg bg-error/10 p-2 text-xs text-error"
          >{@download.error}</pre>
        </div>
      </div>
    </li>
    """
  end

  defp kind_label("resolve"), do: "Link"
  defp kind_label("video"), do: "Video"
  defp kind_label("import"), do: "Import"
  defp kind_label(other), do: other

  defp status_icon(%{status: "running"}), do: "hero-arrow-down-tray"
  defp status_icon(%{status: "queued"}), do: "hero-clock"
  defp status_icon(%{status: "done"}), do: "hero-check"
  defp status_icon(%{status: "skipped"}), do: "hero-forward"
  defp status_icon(%{status: "failed"}), do: "hero-exclamation-triangle"
  defp status_icon(%{status: "cancelled"}), do: "hero-no-symbol"
  defp status_icon(_), do: "hero-question-mark-circle"

  defp status_bg("running"), do: "bg-primary/15 text-primary"
  defp status_bg("done"), do: "bg-success/15 text-success"
  defp status_bg("failed"), do: "bg-error/15 text-error"
  defp status_bg(_), do: "bg-base-200 text-base-content/60"
end
