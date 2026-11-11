#!/usr/bin/env bash
# Builds a production release, installs it and (re)starts the systemd user service.
#
#   rel/install.sh            # install to ~/.local/lib/archive and start
#   ARCHIVE_INSTALL_DIR=/opt/archive rel/install.sh
set -euo pipefail

cd "$(dirname "$0")/.."
if command -v mise >/dev/null 2>&1; then eval "$(mise env -s bash)";
elif [ -x "$HOME/.local/bin/mise" ]; then eval "$("$HOME/.local/bin/mise" env -s bash)"; fi

export MIX_ENV=prod
mix deps.get --only prod
mix compile
mix assets.deploy
mix release --overwrite

DEST="${ARCHIVE_INSTALL_DIR:-$HOME/.local/lib/archive}"
UNIT_DIR="$HOME/.config/systemd/user"
CONF_DIR="$HOME/.config/archive"

if systemctl --user is-active --quiet archive; then systemctl --user stop archive; fi

rm -rf "$DEST.new"
mkdir -p "$(dirname "$DEST")"
cp -a _build/prod/rel/archive "$DEST.new"
rm -rf "$DEST"
mv "$DEST.new" "$DEST"

mkdir -p "$UNIT_DIR" "$CONF_DIR"
[ -f "$CONF_DIR/archive.env" ] || cp rel/archive.env.example "$CONF_DIR/archive.env"
sed "s|@INSTALL_DIR@|$DEST|g" rel/archive.service > "$UNIT_DIR/archive.service"

systemctl --user daemon-reload
systemctl --user enable --now archive

echo
echo "Archive installed in $DEST and running on port ${PORT:-4000}."
echo "Config: $CONF_DIR/archive.env   Logs: journalctl --user -u archive -f"
echo "To keep it running after logout / start at boot: loginctl enable-linger $USER"
