import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :archive, Archive.Repo,
  database:
    Path.expand("../.data/test/archive#{System.get_env("MIX_TEST_PARTITION")}.db", __DIR__),
  busy_timeout: 5_000,
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :archive, ArchiveWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Z6ERVm183nQG95wINeeUmgw0SW5HNcslk5fXEjtuqW7hz2hY1oNorjjTvrcSzGpz",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :archive, Oban, testing: :manual

config :archive,
  data_dir: Path.expand("../.data/test/data", __DIR__),
  default_storage_dir: Path.expand("../.data/test/storage", __DIR__),
  settings_cache: false

config :archive, :tools,
  ytdlp: Path.expand("../test/support/bin/fake-yt-dlp", __DIR__),
  deno: nil,
  ffmpeg: nil,
  ffprobe: nil,
  manage_tools: false
