# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :archive,
  ecto_repos: [Archive.Repo],
  generators: [timestamp_type: :utc_datetime]

# Background jobs (SQLite engine). Queue limits for :downloads are adjusted
# at runtime from the Settings page.
config :archive, Oban,
  engine: Oban.Engines.Lite,
  repo: Archive.Repo,
  queues: [resolve: 2, downloads: 2, imports: 1, maintenance: 1],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron,
     crontab: [
       {"7 * * * *", Archive.Workers.UpdateToolsWorker},
       {"30 4 * * *", Archive.Workers.MaintenanceWorker}
     ]}
  ]

# Paths to external tools. `nil` means "managed by the app" (yt-dlp, deno) or
# "look up on PATH" (ffmpeg, ffprobe).
config :archive, :tools,
  ytdlp: nil,
  deno: nil,
  ffmpeg: nil,
  ffprobe: nil,
  manage_tools: true

# Configure the endpoint
config :archive, ArchiveWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ArchiveWeb.ErrorHTML, json: ArchiveWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Archive.PubSub,
  live_view: [signing_salt: "cluQ0Ijr"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  archive: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  archive: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
