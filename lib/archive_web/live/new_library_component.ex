defmodule ArchiveWeb.NewLibraryComponent do
  @moduledoc "Dialog for creating a library from the sidebar."
  use ArchiveWeb, :live_component

  alias Archive.Libraries
  alias Archive.Libraries.Library

  @impl true
  def mount(socket) do
    {:ok, assign(socket, open: false, form: to_form(Libraries.change_library(%Library{})))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.modal :if={@open} id="new-library-modal" on_close="close" target={@myself} title="New library">
        <.form
          for={@form}
          id="new-library-form"
          phx-change="validate"
          phx-submit="save"
          phx-target={@myself}
        >
          <.input field={@form[:name]} type="text" label="Name" phx-mounted={JS.focus()} required />
          <.input field={@form[:description]} type="textarea" label="Description (optional)" rows="2" />
          <.input
            field={@form[:source_url]}
            type="url"
            label="Source playlist/channel URL (optional)"
            placeholder="https://…"
          />
          <p class="-mt-1 text-xs text-base-content/50">
            With a source URL, “Sync now” on the library page downloads new videos from it.
          </p>
          <div class="mt-6 flex justify-end gap-2">
            <button type="button" class="btn btn-ghost" phx-click="close" phx-target={@myself}>
              Cancel
            </button>
            <button type="submit" class="btn btn-primary" phx-disable-with="Creating…">Create</button>
          </div>
        </.form>
      </.modal>
    </div>
    """
  end

  @impl true
  def handle_event("open", _params, socket) do
    {:noreply, assign(socket, open: true, form: to_form(Libraries.change_library(%Library{})))}
  end

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, open: false)}

  def handle_event("validate", %{"library" => params}, socket) do
    changeset = Libraries.change_library(%Library{}, params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"library" => params}, socket) do
    case Libraries.create_library(params) do
      {:ok, library} ->
        send(self(), {:nav_navigate, ~p"/libraries/#{library.slug}"})
        {:noreply, assign(socket, open: false)}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
