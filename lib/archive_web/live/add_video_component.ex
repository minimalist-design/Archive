defmodule ArchiveWeb.AddVideoComponent do
  @moduledoc "The Add dialog: paste a video/playlist URL, pick a library and categories."
  use ArchiveWeb, :live_component

  alias Archive.{Downloads, Libraries}

  @impl true
  def mount(socket) do
    {:ok, assign(socket, open: false, categories: [], error: nil, form: blank_form(nil))}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, id: assigns.id, libraries: assigns.libraries)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.modal :if={@open} id="add-video-modal" on_close="close" target={@myself} title="Add videos">
        <.form
          for={@form}
          id="add-video-form"
          phx-change="change"
          phx-submit="submit"
          phx-target={@myself}
        >
          <p class="mb-4 text-sm text-base-content/60">
            Paste a link to a video, playlist or channel from any site yt-dlp supports.
          </p>
          <.input
            field={@form[:url]}
            type="url"
            label="URL"
            placeholder="https://…"
            autocomplete="off"
            phx-mounted={JS.focus()}
            required
          />
          <.input
            field={@form[:library_id]}
            type="select"
            label="Library"
            options={Enum.map(@libraries, &{&1.name, &1.id}) ++ [{"+ New library…", "new"}]}
          />
          <.input
            :if={@form[:library_id].value in ["new", nil, ""]}
            field={@form[:new_library]}
            type="text"
            label="New library name"
            placeholder="e.g. Music videos"
          />
          <fieldset :if={@categories != []} class="mt-2">
            <legend class="mb-2 text-sm font-medium">Categories</legend>
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
                  name="add[category_ids][]"
                  value={category.id}
                  checked={to_string(category.id) in (@form[:category_ids].value || [])}
                  class="hidden"
                />
                {category.name}
              </label>
            </div>
          </fieldset>
          <input type="hidden" name="add[category_ids][]" value="" />
          <p :if={@error} class="mt-3 flex items-center gap-2 text-sm text-error">
            <.icon name="hero-exclamation-circle" class="size-4" /> {@error}
          </p>
          <div class="mt-6 flex justify-end gap-2">
            <button type="button" class="btn btn-ghost" phx-click="close" phx-target={@myself}>
              Cancel
            </button>
            <button type="submit" class="btn btn-primary" phx-disable-with="Adding…">
              <.icon name="hero-arrow-down-tray" class="size-4" /> Download
            </button>
          </div>
        </.form>
      </.modal>
    </div>
    """
  end

  @impl true
  def handle_event("open", params, socket) do
    library_id =
      case params["library_id"] do
        id when is_binary(id) and id != "" -> id
        _ -> socket.assigns.libraries |> List.first() |> then(&(&1 && to_string(&1.id)))
      end

    {:noreply,
     socket
     |> assign(open: true, error: nil, form: blank_form(library_id))
     |> load_categories(library_id)}
  end

  def handle_event("close", _params, socket) do
    {:noreply, assign(socket, open: false)}
  end

  def handle_event("change", %{"add" => params}, socket) do
    params = normalize(params)

    {:noreply,
     socket
     |> assign(form: to_form(params, as: :add), error: nil)
     |> load_categories(params["library_id"])}
  end

  def handle_event("submit", %{"add" => params}, socket) do
    params = normalize(params)

    with {:ok, library} <- resolve_library(params),
         {:ok, _download} <-
           Downloads.enqueue_url(params["url"] || "", library, params["category_ids"]) do
      send(self(), {:nav_flash, :info, "Queued for download into “#{library.name}”."})
      {:noreply, assign(socket, open: false)}
    else
      {:error, :invalid_url} ->
        {:noreply,
         assign(socket, form: to_form(params, as: :add), error: "Enter a valid http(s) URL.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        message =
          changeset.errors
          |> Enum.map_join(", ", fn {field, {msg, _}} -> "#{field} #{msg}" end)

        {:noreply, assign(socket, form: to_form(params, as: :add), error: "Library: " <> message)}

      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, form: to_form(params, as: :add), error: message)}
    end
  end

  defp resolve_library(%{"library_id" => id} = params) when id in ["new", "", nil] do
    case String.trim(params["new_library"] || "") do
      "" -> {:error, "Enter a name for the new library."}
      name -> Libraries.create_library(%{name: name})
    end
  end

  defp resolve_library(%{"library_id" => id}) do
    case Integer.parse(id) do
      {int, ""} ->
        try do
          {:ok, Libraries.get_library!(int)}
        rescue
          Ecto.NoResultsError -> {:error, "That library no longer exists."}
        end

      _ ->
        {:error, "Choose a library."}
    end
  end

  defp normalize(params) do
    Map.update(params, "category_ids", [], fn ids -> Enum.reject(List.wrap(ids), &(&1 == "")) end)
  end

  defp load_categories(socket, library_id) do
    categories =
      case library_id && Integer.parse(to_string(library_id)) do
        {id, ""} -> Libraries.list_categories(id)
        _ -> []
      end

    assign(socket, :categories, categories)
  end

  defp blank_form(library_id) do
    to_form(
      %{
        "url" => "",
        "library_id" => library_id || "new",
        "new_library" => "",
        "category_ids" => []
      },
      as: :add
    )
  end
end
