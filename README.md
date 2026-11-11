# Archive

A self-hosted video archive built with Elixir/Phoenix LiveView. It downloads
videos from any site [yt-dlp](https://github.com/yt-dlp/yt-dlp) supports,
stores them in a directory you choose and keeps their metadata in SQLite. There
is no auth: it's meant for your own machine and LAN.

* **Libraries** work like playlists. Each library has its own folder on disk
  and its own **categories**; a video can be in several categories.
* **Home** shows a YouTube-like shelf of recent videos per library. The top
  bar does **live search** over titles, descriptions, tags *and subtitle
  text* (SQLite FTS5, accent-insensitive).
* **Library pages** have category chips, sorting, an in-library filter,
  **infinite scrolling** and bulk select (add/remove categories, move).
* **Add** takes a video, playlist or channel URL. Libraries can have a source
  URL with a **Sync now** button that queues only new videos.
* **Downloads** shows the live queue with progress, speed, ETA, errors,
  retry and cancel.
* **Import** scans a server folder and *moves* existing files into a library.
  Metadata comes from a `.info.json` sidecar, from YouTube when the filename
  contains a video id, or from the cleaned-up filename.
* **Playback**: files browsers can play are streamed directly (with HTTP
  Range seeking). Anything else (MKV, HEVC, …) is **transcoded on the fly**
  to seekable HLS with ffmpeg.
* **yt-dlp maintains itself.** The app downloads the official standalone
  binary (verified against `SHA2-256SUMS`) plus the deno JS runtime yt-dlp
  needs for YouTube, updates them on a schedule, and also updates them when
  downloads fail with errors that usually mean "extractor outdated".

## Requirements

* Erlang/OTP + Elixir (pinned in `mise.toml`; install with [mise](https://mise.jdx.dev): `mise install`)
* `ffmpeg` and `ffprobe` on `PATH`
* `gcc`/`make` (to build the `muontrap` and `exqlite` NIF/ports)
* Python 3, only for the test suite's fake yt-dlp
* yt-dlp and deno are installed automatically into the data directory

## Development

```sh
mise install          # Erlang/Elixir from mise.toml
mix setup             # deps, database, assets
mix phx.server        # http://localhost:4000 (also reachable on the LAN)
mix test
mix precommit         # compile --warnings-as-errors, format, test
```

Development data (DB, tool binaries, caches and the default storage dir) lives
in `./.data/dev`. Delete that folder to start over.

## Production (systemd user service)

```sh
rel/install.sh                     # builds a release into ~/.local/lib/archive and starts it
loginctl enable-linger $USER       # keep running without a login session / start at boot
journalctl --user -u archive -f    # logs
```

Configuration lives in `~/.config/archive/archive.env` (see
`rel/archive.env.example`):

| Variable | Default | |
|---|---|---|
| `PORT` | `4000` | listens on all interfaces |
| `ARCHIVE_DATA_DIR` | `~/.local/share/archive` | DB, `bin/yt-dlp`, `bin/deno`, thumbnails, transcode cache |
| `ARCHIVE_STORAGE_DIR` | `~/Videos/Archive` | default video storage (editable in Settings) |
| `PHX_HOST` | `localhost` | host for generated URLs |
| `SECRET_KEY_BASE` | generated | otherwise persisted in the data dir on first boot |

Migrations run automatically when the release starts.

## Settings page

* Storage directory (existing files are **not** moved when you change it)
* Simultaneous downloads, subtitle languages (original language + English by
  default, manual and auto-generated), extra yt-dlp arguments
* Transcoding: max resolution, x264 preset, max simultaneous streams
* yt-dlp channel (stable/nightly/master), update interval, "Update now", and
  the installed tool versions

## On disk

```
<storage>/
  <library-slug>/
    Title [videoid].webm          # best available format, any codec
    Title [videoid].info.json     # full yt-dlp metadata
    Title [videoid].jpg           # thumbnail
    Title [videoid].en.vtt        # subtitles
```

Database paths are relative to the storage directory, so moving the whole
folder and updating the setting keeps everything working. Renaming a library
renames its folder. Deleting a video or library asks whether to delete files
too.

## Architecture

| Piece | Where |
|---|---|
| Contexts | `Archive.Libraries`, `Archive.Videos`, `Archive.Downloads`, `Archive.Settings`, `Archive.Search` |
| Job queues (Oban, SQLite engine) | `resolve` (expand URLs/playlists), `downloads`, `imports`, `maintenance` (tool updates, missing-file checks) – `lib/archive/workers/` |
| yt-dlp commands | `Archive.YtDlp`; processes run under MuonTrap (`Archive.Tools.Runner`), so cancelling a job kills yt-dlp |
| Tool install/update | `Archive.Tools.Manager` |
| Ingest (probe, sidecars, thumbnails, FTS) | `Archive.Ingest`, `Archive.Media.*` |
| Import heuristics | `Archive.Importer` |
| HLS transcoding | `Archive.Media.TranscodeSession`: a full VOD playlist with 6 s segments; ffmpeg restarts at the requested segment on seeks; keyframes and timestamps are aligned so segments from different runs line up |
| Media HTTP (Range, thumbs, subs, HLS) | `ArchiveWeb.MediaController` (files are looked up by DB id only) |
| UI | LiveViews in `lib/archive_web/live/`, player hook in `assets/js/player.js` (hls.js) |

## Notes

* Cookies/logins are not supported, so only public content can be downloaded.
* YouTube sometimes rate-limits subtitle requests (HTTP 429). The video is
  still archived and the warning is shown on the Downloads page.
* Transcoding is CPU-bound (software x264). Lower the max resolution or use a
  faster preset in Settings on slow machines.
