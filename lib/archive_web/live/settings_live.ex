defmodule ArchiveWeb.SettingsLive do
  @moduledoc "Settings: storage, downloads, subtitles, transcoding and tool updates."
  use ArchiveWeb, :live_view

  alias Archive.Settings
  alias Archive.Settings.Form
  alias Archive.Tools.Manager

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Archive.Events.subscribe("tools")

    {:ok,
     socket
     |> assign(
       page_title: "Settings",
       form: to_form(Settings.change_form()),
       tools: Manager.status()
     )}
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    form = params |> Settings.change_form() |> Map.put(:action, :validate) |> to_form()
    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"form" => params}, socket) do
    case Settings.save_form(params) do
      {:ok, changed} ->
        if :download_concurrency in changed do
          _ = Oban.scale_queue(queue: :downloads, limit: Settings.get(:download_concurrency))
        end

        if :storage_dir in changed, do: Archive.Paths.ensure_dirs!()

        {:noreply,
         socket
         |> put_flash(:info, "Settings saved.")
         |> assign(form: to_form(Settings.change_form()))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("update_tools", _params, socket) do
    Manager.update_now()
    {:noreply, assign(socket, tools: Manager.status())}
  end

  @impl true
  def handle_info({:tools_changed}, socket),
    do: {:noreply, assign(socket, tools: Manager.status())}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav_libraries={@nav_libraries}
      active_downloads={@active_downloads}
      search_query={@search_query}
      active={:settings}
    >
      <div class="mx-auto max-w-3xl">
        <h1 class="mb-6 text-2xl font-bold tracking-tight">Settings</h1>

        <.form
          for={@form}
          id="settings-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-6"
        >
          <.card title="Storage" icon="hero-server-stack">
            <.input field={@form[:storage_dir]} type="text" label="Video storage directory" />
            <p class="-mt-1 text-xs text-base-content/50">
              Each library is a folder inside this directory. Changing it does <strong>not</strong>
              move existing files;
              move the folder yourself, then point this setting at the new location.
            </p>
          </.card>

          <.card title="Downloads" icon="hero-arrow-down-tray">
            <div class="grid gap-x-4 sm:grid-cols-2">
              <.input
                field={@form[:download_concurrency]}
                type="number"
                label="Simultaneous downloads"
                min="1"
                max="8"
              />
              <.input
                field={@form[:subtitle_mode]}
                type="select"
                label="Subtitles"
                options={[
                  {"Original language + English", "original_plus_en"},
                  {"Original language only", "original"},
                  {"English only", "en"},
                  {"Don't download subtitles", "none"}
                ]}
              />
            </div>
            <.input
              field={@form[:extra_ytdlp_args]}
              type="text"
              label="Extra yt-dlp arguments (advanced)"
              placeholder="--limit-rate 5M"
            />
          </.card>

          <.card title="Playback" icon="hero-play">
            <p class="mb-3 text-xs text-base-content/50">
              Files a browser can't play natively are transcoded on the fly to H.264/AAC.
            </p>
            <div class="grid gap-x-4 sm:grid-cols-3">
              <.input
                field={@form[:transcode_max_height]}
                type="select"
                label="Max resolution"
                options={Enum.map(Form.heights(), &{"#{&1}p", &1})}
              />
              <.input
                field={@form[:transcode_preset]}
                type="select"
                label="x264 preset"
                options={Form.presets()}
              />
              <.input
                field={@form[:max_transcode_sessions]}
                type="number"
                label="Max simultaneous streams"
                min="1"
                max="8"
              />
            </div>
          </.card>

          <.card title="yt-dlp updates" icon="hero-arrow-path">
            <div class="grid gap-x-4 sm:grid-cols-2">
              <.input
                field={@form[:ytdlp_channel]}
                type="select"
                label="Release channel"
                options={Form.channels()}
              />
              <.input
                field={@form[:ytdlp_update_interval_hours]}
                type="number"
                label="Check every (hours)"
                min="1"
              />
            </div>
          </.card>

          <div class="flex justify-end">
            <button class="btn btn-primary" phx-disable-with="Saving…">Save settings</button>
          </div>
        </.form>

        <section id="tools-status" class="mt-10 rounded-2xl border border-base-300 p-5">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <h2 class="flex items-center gap-2 font-semibold">
              <.icon name="hero-wrench-screwdriver" class="size-5 text-base-content/60" /> Tools
            </h2>
            <button
              id="update-tools"
              phx-click="update_tools"
              class="btn btn-sm btn-soft btn-primary rounded-full"
              disabled={@tools.busy}
            >
              <span :if={@tools.busy} class="loading loading-spinner loading-xs"></span>
              <.icon :if={!@tools.busy} name="hero-arrow-path" class="size-4" />
              {if @tools.busy, do: "Updating…", else: "Update now"}
            </button>
          </div>
          <dl class="mt-4 grid gap-4 text-sm sm:grid-cols-2">
            <.tool name="yt-dlp" state={@tools.ytdlp} />
            <.tool name="deno (JS runtime)" state={@tools.deno} />
          </dl>
          <p class="mt-4 text-xs text-base-content/50">
            <span :if={@tools.managed}>The app installs and updates these tools in its data directory.</span>
            <span :if={!@tools.managed}>Tool management is disabled in this environment.</span>
            JavaScript runtime used by yt-dlp: {@tools.js_runtime || "none found"}
          </p>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp card(assigns) do
    ~H"""
    <section class="rounded-2xl border border-base-300 p-5">
      <h2 class="mb-3 flex items-center gap-2 font-semibold">
        <.icon name={@icon} class="size-5 text-base-content/60" /> {@title}
      </h2>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :name, :string, required: true
  attr :state, :map, required: true

  defp tool(assigns) do
    ~H"""
    <div class="rounded-xl bg-base-200/60 p-4">
      <dt class="font-medium">{@name}</dt>
      <dd class="mt-1 space-y-0.5 text-xs text-base-content/70">
        <p>Version: <span class="font-mono">{@state["version"] || "unknown"}</span></p>
        <p :if={@state["path"]} class="truncate" title={@state["path"]}>
          Path: <span class="font-mono">{@state["path"]}</span>
        </p>
        <p :if={@state["last_check_at"]}>
          Last check: {@state["last_check_at"] |> parse_time() |> time_ago()}
        </p>
        <p
          :if={@state["last_message"]}
          class={["line-clamp-3", @state["last_status"] == "error" && "text-error"]}
          title={@state["last_message"]}
        >
          {@state["last_message"]}
        </p>
      </dd>
    </div>
    """
  end

  defp parse_time(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end
