#!/usr/bin/env bash
#
# sync-labs.sh — keep ~/labs in step with the repo.
#
# ~/labs/topologies is the working copy that 02-deploy-lab.sh deploys from by
# default, so it — not the repo — is what actually runs. It used to be seeded
# with `cp -n`, which never updates an existing file: a `git pull` that fixed a
# topology left the deployed copy stale forever, and you'd deploy the old file
# while reading the fixed one.
#
# So topologies are synced, not just seeded. Overwriting blindly would discard
# local edits, so we track what we install in a manifest:
#
#   local copy == what we last installed  ->  ours to update, update it
#   local copy != what we last installed  ->  you edited it, leave it alone
#
# Idempotent: the second run in a row prints nothing and changes nothing.
#
# Called by 00-bootstrap.sh, and by setup.sh before deploying — the latter
# matters because skipping the bootstrap on an already-provisioned box must
# still leave you with current topologies.
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABS_DIR="${LABS_DIR:-$HOME/labs}"
MANIFEST="$LABS_DIR/.topologies.installed"

warn() { printf '\033[1;33m!!\033[0m %s\n' "$1" >&2; }

mkdir -p "$LABS_DIR"/{topologies,automation}
: >>"$MANIFEST"

sum_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

record() { # <file> <basename>
  local tmp="$MANIFEST.tmp"
  grep -v " $2\$" "$MANIFEST" >"$tmp" 2>/dev/null || true
  printf '%s %s\n' "$(sum_of "$1")" "$2" >>"$tmp"
  mv "$tmp" "$MANIFEST"
}

shopt -s nullglob
for src in "$REPO_DIR"/topologies/*.yml; do
  base="$(basename "$src")"
  dest="$LABS_DIR/topologies/$base"

  if [[ ! -e "$dest" ]]; then
    cp "$src" "$dest"
    echo "Installed topologies/$base"
    record "$dest" "$base"
  elif cmp -s "$src" "$dest"; then
    record "$dest" "$base"          # already current; keep the manifest honest
  else
    recorded="$(awk -v b="$base" '$2==b{print $1}' "$MANIFEST" | tail -1)"
    if [[ -z "$recorded" ]]; then
      # Predates the manifest. Before this existed we only ever copied pristine
      # repo files here, so it's almost certainly an old unmodified copy —
      # update it, but keep a .bak in case this box is the exception.
      cp "$dest" "$dest.bak"
      cp "$src" "$dest"
      echo "Updated topologies/$base (previous copy saved as $base.bak)"
      record "$dest" "$base"
    elif [[ "$recorded" == "$(sum_of "$dest")" ]]; then
      cp "$src" "$dest"
      echo "Updated topologies/$base"
      record "$dest" "$base"
    else
      warn "$dest has local edits — leaving it as-is."
      warn "Repo version differs: $src"
    fi
  fi
done
shopt -u nullglob

# Automation code is seeded once, not synced: it's a starting point people are
# meant to edit and build on.
cp -rn "$REPO_DIR"/automation/* "$LABS_DIR/automation/" 2>/dev/null || true
chmod +x "$LABS_DIR/automation/link-inventory.sh" 2>/dev/null || true
