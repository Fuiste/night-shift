#!/bin/sh
set -eu

usage() {
  echo "usage: $0 <release-tag> <target>" >&2
  exit 1
}

release_tag="${1-}"
target="${2-}"

if [ -z "$release_tag" ] || [ -z "$target" ]; then
  usage
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

version=$(
  sed -n 's/^version = "\(.*\)"/\1/p' "$REPO_ROOT/gleam.toml" | head -n 1
)

if [ -z "$version" ]; then
  echo "Failed to read package version from gleam.toml" >&2
  exit 1
fi

if ! command -v gleam >/dev/null 2>&1; then
  echo "gleam is required to build release bundles" >&2
  exit 1
fi

if ! command -v erl >/dev/null 2>&1; then
  echo "erl is required to build release bundles" >&2
  exit 1
fi

artifact_root="$REPO_ROOT/build/releases/$release_tag/$target"
bundle_name="night-shift-$release_tag-$target"
bundle_dir="$artifact_root/$bundle_name"
archive_path="$artifact_root/$bundle_name.tar.gz"
checksum_path="$archive_path.sha256"

mkdir -p "$artifact_root"
rm -rf "$bundle_dir" "$archive_path" "$checksum_path"

cd "$REPO_ROOT"
gleam export erlang-shipment

erlang_root=$(
  erl -eval 'io:format("~s", [code:root_dir()]), halt().' -noshell
)

if [ ! -d "$erlang_root" ]; then
  echo "Resolved Erlang root does not exist: $erlang_root" >&2
  exit 1
fi

mkdir -p "$bundle_dir"
cp -R "$REPO_ROOT/build/erlang-shipment" "$bundle_dir/shipment"
cp -R "$erlang_root" "$bundle_dir/erlang"

if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$bundle_dir" 2>/dev/null || true
fi

cat > "$bundle_dir/night-shift" <<'EOF'
#!/bin/sh
set -eu

BASE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ERL_ROOTDIR="$BASE/erlang" \
  exec "$BASE/erlang/bin/erl" \
    -pa "$BASE"/shipment/*/ebin \
    -eval 'night_shift@@main:run(night_shift)' \
    -noshell \
    -extra "$@"
EOF

chmod +x "$bundle_dir/night-shift"

COPYFILE_DISABLE=1 tar -C "$artifact_root" -czf "$archive_path" "$bundle_name"

(
  cd "$artifact_root"
  archive_file=$(basename "$archive_path")
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$archive_file" > "$(basename "$checksum_path")"
  else
    shasum -a 256 "$archive_file" > "$(basename "$checksum_path")"
  fi
)

echo "Built $bundle_name"
echo "Version: $version"
echo "Archive: $archive_path"
echo "Checksum: $checksum_path"
