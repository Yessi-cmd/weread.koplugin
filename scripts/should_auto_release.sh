#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${1:-}"
target_repo="${2:-$repo_dir}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: version must use X.Y.Z format (got: ${version:-missing})" >&2
    exit 1
fi
if ! git -C "$target_repo" rev-parse --git-dir >/dev/null 2>&1; then
    echo "error: release decision target is not a Git repository" >&2
    exit 1
fi

if git -C "$target_repo" rev-parse --verify --quiet \
    "refs/tags/v$version" >/dev/null; then
    printf 'false\n'
else
    printf 'true\n'
fi
