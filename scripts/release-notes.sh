#!/bin/sh
# A version's release notes: its section of CHANGELOG.md, without the heading (release.yml,
# docs/releasing.md). Usage: scripts/release-notes.sh <version>
set -eu
awk -v v="${1:?usage: scripts/release-notes.sh <version>}" '/^## / { if (on) exit; on = ($2 == v); next } on' "$(dirname "$0")/../CHANGELOG.md"
