#!/bin/sh
set -eu

usage() {
  cat <<'EOF' >&2
usage: install_local_cli.sh [--source PATH] [--label LABEL] [--install-root PATH] [--bin-path PATH]

Build a Night Shift worktree and publish it to the local CLI install.
EOF
  exit 1
}

SOURCE_DIR=""
LABEL=""
INSTALL_ROOT="${HOME}/.local/share/night-shift"
BIN_PATH="${HOME}/.local/bin/night-shift"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source)
      [ "$#" -ge 2 ] || usage
      SOURCE_DIR="$2"
      shift 2
      ;;
    --label)
      [ "$#" -ge 2 ] || usage
      LABEL="$2"
      shift 2
      ;;
    --install-root)
      [ "$#" -ge 2 ] || usage
      INSTALL_ROOT="$2"
      shift 2
      ;;
    --bin-path)
      [ "$#" -ge 2 ] || usage
      BIN_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      ;;
  esac
done

if [ -z "$SOURCE_DIR" ]; then
  SOURCE_DIR="$(pwd)"
fi

SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"
BUILD_DIR="$SOURCE_DIR/build/dev/erlang"

if [ ! -f "$SOURCE_DIR/gleam.toml" ]; then
  echo "Not a Gleam project: $SOURCE_DIR" >&2
  exit 1
fi

(
  cd "$SOURCE_DIR"
  gleam build
)

if [ ! -d "$BUILD_DIR" ]; then
  echo "Missing build output: $BUILD_DIR" >&2
  exit 1
fi

if [ -z "$LABEL" ]; then
  if LABEL="$(git -C "$SOURCE_DIR" rev-parse --short HEAD 2>/dev/null)"; then
    :
  else
    LABEL="$(basename "$SOURCE_DIR")"
  fi
fi

INSTALL_DIR="$INSTALL_ROOT/$LABEL"

rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

for package_dir in "$BUILD_DIR"/*; do
  if [ -d "$package_dir" ]; then
    cp -R "$package_dir" "$INSTALL_DIR"/
  fi
done

cat > "$INSTALL_DIR/entrypoint.sh" <<'EOF'
#!/bin/sh
set -eu

PACKAGE=night_shift
BASE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
COMMAND="${1-default}"

run() {
  exec erl \
    -pa "$BASE"/*/ebin \
    -eval "$PACKAGE@@main:run($PACKAGE)" \
    -noshell \
    -extra "$@"
}

shell() {
  exec erl -pa "$BASE"/*/ebin
}

case "$COMMAND" in
run)
  shift
  run "$@"
  ;;
shell)
  shift
  shell "$@"
  ;;
*)
  echo "usage:" >&2
  echo "  entrypoint.sh \$COMMAND" >&2
  echo "" >&2
  echo "commands:" >&2
  echo "  run    Run the project main function" >&2
  echo "  shell  Run an Erlang shell" >&2
  exit 1
  ;;
esac
EOF

cat > "$INSTALL_DIR/entrypoint.ps1" <<'EOF'
$Package = "night_shift"
$Base = Split-Path -Parent $MyInvocation.MyCommand.Path
$Command = if ($args.Count -gt 0) { $args[0] } else { "run" }

switch ($Command) {
  "run" {
    $Remaining = if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() }
    & erl -pa "$Base/*/ebin" -eval "$Package@@main:run($Package)" -noshell -extra @Remaining
  }
  "shell" {
    & erl -pa "$Base/*/ebin"
  }
  default {
    Write-Error "usage: entrypoint.ps1 run|shell"
    exit 1
  }
}
EOF

chmod +x "$INSTALL_DIR/entrypoint.sh"

mkdir -p "$(dirname "$BIN_PATH")" "$INSTALL_ROOT"
ln -sfn "$INSTALL_DIR" "$INSTALL_ROOT/current"

cat > "$BIN_PATH" <<EOF
#!/bin/sh
set -eu

exec "$INSTALL_ROOT/current/entrypoint.sh" run "\$@"
EOF

chmod +x "$BIN_PATH"

echo "Installed Night Shift bundle: $INSTALL_DIR"
echo "Current bundle symlink: $INSTALL_ROOT/current"
echo "Launcher: $BIN_PATH"

"$BIN_PATH" plan >/tmp/night-shift-install-smoke.$$ 2>&1 || true
cat /tmp/night-shift-install-smoke.$$
rm -f /tmp/night-shift-install-smoke.$$
