defmodule ArchiveWeb.UI do
  @moduledoc "App-specific UI components and formatting helpers."
  use Phoenix.Component
  use ArchiveWeb, :verified_routes

  import ArchiveWeb.CoreComponents, only: [icon: 1]
  alias Phoenix.LiveView.JS

  # --- modal ---------------------------------------------------------------------

  @doc """
  A server-controlled modal: render it only while it should be visible.
  `on_close` is the event (or JS) used by the backdrop, close button and Esc.
  """
  attr :id, :string, required: true
  attr :on_close, :any, required: true
  attr :target, :any, default: nil
  attr :title, :string, default: nil
  attr :class, :string, default: "max-w-lg"
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      class="fixed inset-0 z-50 flex items-start sm:items-center justify-center p-4 overflow-y-auto"
      role="dialog"
      aria-modal="true"
      phx-window-keydown={close_js(@on_close, @target)}
      phx-key="escape"
    >
      <div
        class="fixed inset-0 bg-black/50 backdrop-blur-[2px] animate-[fade-in_120ms_ease-out]"
        phx-click={close_js(@on_close, @target)}
        aria-hidden="true"
      />
      <div class={[
        "relative w-full rounded-2xl bg-base-100 shadow-2xl ring-1 ring-base-300 my-8",
        "animate-[pop-in_140ms_ease-out]",
        @class
      ]}>
        <div class="flex items-center justify-between gap-4 px-6 pt-5">
          <h2 :if={@title} class="text-lg font-semibold">{@title}</h2>
          <button
            type="button"
            class="ml-auto rounded-full p-1.5 text-base-content/60 hover:bg-base-200 hover:text-base-content transition"
            phx-click={close_js(@on_close, @target)}
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>
        <div class="px-6 pb-6 pt-3">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  defp close_js(%JS{} = js, _target), do: js
  defp close_js(event, nil) when is_binary(event), do: JS.push(event)
  defp close_js(event, target) when is_binary(event), do: JS.push(event, target: target)

  # --- video cards ------------------------------------------------------------------

  attr :video, :map, required: true
  attr :id, :string, default: nil
  attr :show_library, :boolean, default: false
  attr :selectable, :boolean, default: false
  attr :selected, :boolean, default: false
  attr :class, :string, default: nil

  def video_card(assigns) do
    ~H"""
    <div id={@id} class={["group relative", @class]}>
      <.link navigate={~p"/videos/#{@video.id}"} class="block" data-video-link>
        <div class={[
          "relative aspect-video overflow-hidden rounded-xl bg-base-300",
          @selected && "ring-4 ring-primary"
        ]}>
          <img
            src={~p"/media/videos/#{@video.id}/thumb"}
            alt=""
            loading="lazy"
            decoding="async"
            class="size-full object-cover transition duration-300 group-hover:scale-[1.03]"
          />
          <span
            :if={@video.duration}
            class="absolute bottom-1.5 right-1.5 rounded-md bg-black/80 px-1.5 py-0.5 text-[11px] font-medium tabular-nums text-white"
          >
            {format_duration(@video.duration)}
          </span>
          <span
            :if={@video.status == "missing"}
            class="absolute top-1.5 left-1.5 rounded-md bg-error px-1.5 py-0.5 text-[11px] font-semibold text-error-content"
          >
            File missing
          </span>
        </div>
        <div class="mt-2.5 pr-2">
          <h3 class="line-clamp-2 text-sm font-semibold leading-snug" title={@video.title}>
            {@video.title}
          </h3>
          <p class="mt-1 truncate text-xs text-base-content/60">
            <span :if={@show_library && Ecto.assoc_loaded?(@video.library)}>
              {@video.library.name} ·
            </span>
            <span :if={Archive.Videos.Video.display_uploader(@video)}>
              {Archive.Videos.Video.display_uploader(@video)} ·
            </span>
            {format_date(@video.upload_date || @video.inserted_at)}
          </p>
        </div>
      </.link>
      <button
        :if={@selectable}
        type="button"
        phx-click="toggle_select"
        phx-value-id={@video.id}
        class={[
          "absolute top-2 left-2 z-10 grid size-7 place-items-center rounded-full border-2 shadow transition",
          if(@selected,
            do: "bg-primary border-primary text-primary-content",
            else: "bg-black/40 border-white/80 text-transparent hover:text-white/80"
          )
        ]}
        aria-label="Select video"
      >
        <.icon name="hero-check-micro" class="size-4" />
      </button>
    </div>
    """
  end

  @doc "Responsive thumbnail grid container classes."
  def grid_class,
    do:
      "grid grid-cols-1 gap-x-4 gap-y-8 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 2xl:grid-cols-5"

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :icon, :string, default: "hero-film"
  slot :inner_block

  def empty_state(assigns) do
    ~H"""
    <div class="mx-auto flex max-w-md flex-col items-center py-24 text-center">
      <div class="grid size-16 place-items-center rounded-2xl bg-base-200 text-base-content/50">
        <.icon name={@icon} class="size-8" />
      </div>
      <h2 class="mt-5 text-lg font-semibold">{@title}</h2>
      <p :if={@subtitle} class="mt-1.5 text-sm text-base-content/60">{@subtitle}</p>
      <div class="mt-6">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  # --- formatting ---------------------------------------------------------------------

  def format_duration(nil), do: ""

  def format_duration(seconds) when is_number(seconds) do
    seconds = round(seconds)
    h = div(seconds, 3600)
    m = div(rem(seconds, 3600), 60)
    s = rem(seconds, 60)

    if h > 0,
      do: "#{h}:#{pad(m)}:#{pad(s)}",
      else: "#{m}:#{pad(s)}"
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  def format_date(nil), do: ""
  def format_date(%Date{} = d), do: Calendar.strftime(d, "%b %-d, %Y")
  def format_date(%DateTime{} = d), do: Calendar.strftime(d, "%b %-d, %Y")
  def format_date(%NaiveDateTime{} = d), do: Calendar.strftime(d, "%b %-d, %Y")

  def format_bytes(nil), do: "—"

  def format_bytes(bytes) when is_number(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 0) |> trunc()} KB"
      true -> "#{trunc(bytes)} B"
    end
  end

  def format_speed(nil), do: nil
  def format_speed(bps), do: format_bytes(bps) <> "/s"

  def format_eta(nil), do: nil
  def format_eta(seconds), do: format_duration(seconds)

  def format_count(nil), do: nil

  def format_count(n) when is_integer(n) do
    cond do
      n >= 1_000_000 -> "#{Float.round(n / 1_000_000, 1)}M"
      n >= 1_000 -> "#{Float.round(n / 1_000, 1)}K"
      true -> Integer.to_string(n)
    end
  end

  def format_count(_), do: nil

  def time_ago(nil), do: ""

  def time_ago(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)} min ago"
      diff < 86_400 -> "#{div(diff, 3600)} h ago"
      diff < 86_400 * 30 -> "#{div(diff, 86_400)} d ago"
      true -> format_date(dt)
    end
  end
end
