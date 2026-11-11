defmodule Archive.Events do
  @moduledoc """
  PubSub topics used to keep LiveViews up to date.

    * `"libraries"`        – `{:libraries_changed}`
    * `"videos"`           – `{:video_added, video}`, `{:video_updated, video}`,
                             `{:video_deleted, video}`
    * `"downloads"`        – `{:download_updated, download}`, `{:downloads_changed}`
    * `"tools"`            – `{:tools_changed}`
  """

  @pubsub Archive.PubSub

  def subscribe(topic), do: Phoenix.PubSub.subscribe(@pubsub, topic)

  def broadcast(topic, message) do
    Phoenix.PubSub.broadcast(@pubsub, topic, message)
  end

  def libraries_changed, do: broadcast("libraries", {:libraries_changed})
end
