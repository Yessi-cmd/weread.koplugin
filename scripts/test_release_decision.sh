#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
decision_script="$repo_dir/scripts/should_auto_release.sh"
fixture_repo="$(mktemp -d)"

cleanup() {
    rm -rf "$fixture_repo"
}
trap cleanup EXIT

git -C "$fixture_repo" init -q
git -C "$fixture_repo" config user.name "Release Test"
git -C "$fixture_repo" config user.email "release-test@example.invalid"

printf 'version = "1.2.0"\n' > "$fixture_repo/_meta.lua"
git -C "$fixture_repo" add _meta.lua
git -C "$fixture_repo" commit -qm "baseline"
git -C "$fixture_repo" tag v1.2.0

printf 'version = "1.3.0"\n' > "$fixture_repo/_meta.lua"
git -C "$fixture_repo" add _meta.lua
git -C "$fixture_repo" commit -qm "bump version"
printf 'release notes\n' > "$fixture_repo/README.md"
git -C "$fixture_repo" add README.md
git -C "$fixture_repo" commit -qm "follow-up documentation"

if [[ "$(bash "$decision_script" 1.3.0 "$fixture_repo")" != "true" ]]; then
    echo "error: an untagged version was skipped after a multi-commit push" >&2
    exit 1
fi

git -C "$fixture_repo" tag v1.3.0
if [[ "$(bash "$decision_script" 1.3.0 "$fixture_repo")" != "false" ]]; then
    echo "error: an existing release tag was selected again" >&2
    exit 1
fi

if bash "$decision_script" invalid "$fixture_repo" >/dev/null 2>&1; then
    echo "error: an invalid release version was accepted" >&2
    exit 1
fi

echo "release decision tests passed"
