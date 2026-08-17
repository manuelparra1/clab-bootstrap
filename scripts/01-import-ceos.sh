#!/usr/bin/env bash
#
# 01-import-ceos.sh <path-to-cEOS64-lab-VERSION.tar.xz> [image-tag]
#
# Re-verifies the sha512 hash of the cEOS tarball (catches corruption from
# the scp transfer itself, separate from whatever you checked on your
# laptop before sending it), then imports it into Docker with a progress
# bar via `pv`.
#
# Expects a matching <file>.sha512sum next to the tarball, in the same
# format Arista ships it in (i.e. what `sha512sum -c` understands).
#
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <path-to-cEOS64-lab-VERSION.tar.xz> [image:tag]" >&2
  exit 1
fi

TARBALL="$1"
BASENAME="$(basename "$TARBALL")"
SHAFILE="${TARBALL}.sha512sum"

# Derive a default image tag like ceos:4.35.3F from the filename if one
# wasn't given explicitly.
if [[ $# -ge 2 ]]; then
  IMAGE_TAG="$2"
else
  VERSION="$(echo "$BASENAME" | sed -E 's/cEOS64-lab-(.+)\.tar\.xz/\1/')"
  IMAGE_TAG="ceos:${VERSION}"
fi

if [[ ! -f "$TARBALL" ]]; then
  echo "File not found: $TARBALL" >&2
  exit 1
fi

echo "==> Verifying checksum"
if [[ -f "$SHAFILE" ]]; then
  if ! (cd "$(dirname "$TARBALL")" && sha512sum -c "$(basename "$SHAFILE")"); then
    echo "Checksum FAILED. The file is corrupt — re-scp it from your laptop" >&2
    echo "and don't let the laptop sleep mid-transfer. Do not import a bad" >&2
    echo "tarball; a corrupt EOS filesystem produces confusing boot failures." >&2
    exit 1
  fi
  echo "Checksum OK."
else
  echo "No .sha512sum file found next to the tarball ($SHAFILE)." >&2
  echo "Proceeding without verification — you did check it on your laptop, right?" >&2
fi

echo "==> Importing into Docker as ${IMAGE_TAG}"
if command -v pv >/dev/null 2>&1; then
  pv "$TARBALL" | docker import - "$IMAGE_TAG"
else
  docker import "$TARBALL" "$IMAGE_TAG"
fi

# Also publish a stable alias. The topologies reference ceos:latest so they
# work with whatever version you personally downloaded — without this, every
# new cEOS release would mean hand-editing every topology file, and getting it
# wrong makes containerlab try to pull `ceos` from Docker Hub (where it does
# not exist) and fail with a misleading "pull access denied".
echo "==> Tagging ${IMAGE_TAG} as ceos:latest (the tag topologies reference)"
docker tag "$IMAGE_TAG" ceos:latest

echo
echo "Done. Verify with: docker images | grep ceos"
echo "Imported as: ${IMAGE_TAG}  (also tagged ceos:latest)"
echo "Topologies use ceos:latest, so they'll pick this up automatically."
