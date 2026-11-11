import Config

# config/runtime.exs is executed for all environments, including releases.
#
# Directories:
#   ARCHIVE_DATA_DIR    – database, managed tool binaries, caches
#                         (prod default: ~/.local/share/archive, dev: ./.data/dev)
#   ARCHIVE_STORAGE_DIR – default video storage directory, can be changed later
#                         from the Settings page (prod default: ~/Videos/Archive)

if System.get_env("PHX_SERVER") do
  config :archive, ArchiveWeb.Endpoint, server: true
end

port = String.to_integer(System.get_env("PORT", "4000"))

if config_env() == :dev do
  data_dir = System.get_env("ARCHIVE_DATA_DIR") || Path.expand("../.data/dev", __DIR__)

  config :archive,
    data_dir: data_dir,
    default_storage_dir: System.get_env("ARCHIVE_STORAGE_DIR") || Path.join(data_dir, "storage")

  config :archive, ArchiveWeb.Endpoint, http: [port: port]

  # Reload browser tabs when matching files change.
  config :archive, ArchiveWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        ~r"lib/archive_web/router\.ex$"E,
        ~r"lib/archive_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  home = System.user_home!()

  data_dir =
    System.get_env("ARCHIVE_DATA_DIR") || Path.join([home, ".local", "share", "archive"])

  File.mkdir_p!(data_dir)

  config :archive,
    data_dir: data_dir,
    default_storage_dir:
      System.get_env("ARCHIVE_STORAGE_DIR") || Path.join([home, "Videos", "Archive"])

  config :archive, Archive.Repo,
    database: System.get_env("DATABASE_PATH") || Path.join(data_dir, "archive.db"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
    busy_timeout: 5_000

  # The secret key base signs cookies. Taken from the environment, or generated
  # once and persisted in the data directory.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      (fn ->
         path = Path.join(data_dir, "secret_key_base")

         case File.read(path) do
           {:ok, secret} when byte_size(secret) >= 64 ->
             String.trim(secret)

           _ ->
             secret = :crypto.strong_rand_bytes(48) |> Base.encode64()
             File.write!(path, secret)
             File.chmod!(path, 0o600)
             secret
         end
       end).()

  host = System.get_env("PHX_HOST") || "localhost"

  config :archive, ArchiveWeb.Endpoint,
    url: [host: host, port: port, scheme: "http"],
    http: [
      # Bind on all interfaces so devices on the LAN can reach the archive.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    # Accept websocket connections for whatever host/IP the page was served from.
    check_origin: :conn,
    secret_key_base: secret_key_base
end
