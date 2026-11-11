defmodule ArchiveWeb.Router do
  use ArchiveWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ArchiveWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :media do
    plug :put_secure_browser_headers
  end

  scope "/", ArchiveWeb do
    pipe_through :browser

    live_session :default, on_mount: [ArchiveWeb.Nav] do
      live "/", HomeLive, :index
      live "/libraries/:slug", LibraryLive, :show
      live "/videos/:id", VideoLive, :show
      live "/downloads", DownloadsLive, :index
      live "/import", ImportLive, :index
      live "/settings", SettingsLive, :index
    end
  end

  # Media files are always looked up by database id, never by a client path.
  scope "/media", ArchiveWeb do
    pipe_through :media

    get "/videos/:id/file", MediaController, :file
    get "/videos/:id/thumb", MediaController, :thumb
    get "/videos/:id/thumb/full", MediaController, :thumb_full
    get "/videos/:id/hls/index.m3u8", MediaController, :hls_playlist
    get "/videos/:id/hls/:segment", MediaController, :hls_segment
    get "/subtitles/:id", MediaController, :subtitle
  end

  # Other scopes may use custom stacks.
  # scope "/api", ArchiveWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:archive, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ArchiveWeb.Telemetry
    end
  end
end
