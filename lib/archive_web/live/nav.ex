defmodule ArchiveWeb.Nav do
  @moduledoc """
  Shared LiveView state for the app shell: the library sidebar, the active
  downloads badge and the global search box.
  """
  import Phoenix.Component
  import Phoenix.LiveView
  use ArchiveWeb, :verified_routes

  alias Archive.{Downloads, Events, Libraries}

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Events.subscribe("libraries")
      Events.subscribe("downloads")
      Events.subscribe("videos")
    end

    socket =
      socket
      |> assign(:nav_libraries, Libraries.list_libraries())
      |> assign(:active_downloads, Downloads.active_count())
      |> assign_new(:search_query, fn -> "" end)
      |> attach_hook(:nav_info, :handle_info, &handle_info/2)
      |> attach_hook(:nav_event, :handle_event, &handle_event/3)

    {:cont, socket}
  end

  defp handle_info({:libraries_changed}, socket) do
    {:cont, assign(socket, :nav_libraries, Libraries.list_libraries())}
  end

  defp handle_info({event, _}, socket) when event in [:video_added, :video_deleted] do
    {:cont, assign(socket, :nav_libraries, Libraries.list_libraries())}
  end

  defp handle_info({event, _}, socket) when event in [:download_updated] do
    {:cont, assign(socket, :active_downloads, Downloads.active_count())}
  end

  defp handle_info({:downloads_changed}, socket) do
    {:cont, assign(socket, :active_downloads, Downloads.active_count())}
  end

  # Components rendered in the shell report results through the LiveView.
  defp handle_info({:nav_flash, kind, message}, socket) do
    {:halt, put_flash(socket, kind, message)}
  end

  defp handle_info({:nav_navigate, path}, socket) do
    {:halt, push_navigate(socket, to: path)}
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  # The top search box: live search on the home page from anywhere.
  defp handle_event("global_search", %{"q" => q}, socket) do
    path = if String.trim(q) == "", do: ~p"/", else: ~p"/?#{[q: q]}"

    socket =
      if socket.view == ArchiveWeb.HomeLive,
        do: push_patch(socket, to: path, replace: true),
        else: push_navigate(socket, to: path)

    {:halt, socket}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}
end
