#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

read_version() {
    local path="$1"
    sed -nE 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
        "$path"
}

meta_versions="$(read_version _meta.lua)"
main_versions="$(read_version main.lua)"
meta_count="$(printf '%s\n' "$meta_versions" | sed '/^$/d' | wc -l | tr -d ' ')"
main_count="$(printf '%s\n' "$main_versions" | sed '/^$/d' | wc -l | tr -d ' ')"

if [[ "$meta_count" -ne 1 || "$main_count" -ne 1 ]]; then
    echo "error: _meta.lua and main.lua must each declare exactly one version" >&2
    exit 1
fi

version="$meta_versions"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: plugin version must use X.Y.Z format (got: $version)" >&2
    exit 1
fi
if [[ "$main_versions" != "$version" ]]; then
    echo "error: main.lua version $main_versions does not match _meta.lua $version" >&2
    exit 1
fi

notes_file="$(mktemp)"
cleanup() {
    rm -f "$notes_file"
}
trap cleanup EXIT
bash scripts/extract_release_notes.sh "$version" "$notes_file"
grep -qx '## 新功能与改进' "$notes_file"

echo "release metadata is consistent: v$version"
