#!/usr/bin/env bash
# Install ds-worker: link the commands into a bin directory on your PATH and
# create a config file from the example if you do not have one yet.
#   ./install.sh                 links into ~/.local/bin
#   PREFIX=/usr/local ./install.sh
set -eo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
bindir="${PREFIX:-$HOME/.local}/bin"
confdir="${XDG_CONFIG_HOME:-$HOME/.config}/ds-worker"

for dep in claude python3 perl; do
  command -v "$dep" > /dev/null || echo "warning: '$dep' not found on PATH (ds needs it)" >&2
done

mkdir -p "$bindir"
for cmd in ds ds-say ds-status; do
  ln -sf "$here/bin/$cmd" "$bindir/$cmd"
  echo "linked $bindir/$cmd"
done

mkdir -p "$confdir"
if [ ! -f "$confdir/config.env" ]; then
  cp "$here/config.example.env" "$confdir/config.env"
  chmod 600 "$confdir/config.env"
  echo "created $confdir/config.env -- fill in your endpoint, token and model"
else
  echo "kept existing $confdir/config.env"
fi

case ":$PATH:" in *":$bindir:"*) ;; *) echo "note: add $bindir to your PATH" ;; esac
