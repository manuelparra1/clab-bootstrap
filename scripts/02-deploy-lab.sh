#!/usr/bin/env bash
#
# 02-deploy-lab.sh [topology-file] [deploy|destroy|inspect|graph]
#
# Deploys (or destroys/inspects/graphs) a Containerlab topology. Defaults
# to topologies/testlab.clab.yml and "deploy" if no arguments are given.
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_TOPO="$HOME/labs/topologies/testlab.clab.yml"
[[ -f "$DEFAULT_TOPO" ]] || DEFAULT_TOPO="$REPO_DIR/topologies/testlab.clab.yml"
TOPO="${1:-$DEFAULT_TOPO}"
ACTION="${2:-deploy}"

if [[ ! -f "$TOPO" ]]; then
  echo "Topology file not found: $TOPO" >&2
  exit 1
fi

# Containerlab creates its per-lab directory (containers' configs, and the
# auto-generated ansible-inventory.yml / nornir-simple-inventory.yml) in the
# CURRENT working directory. cd into the topology's own directory first so
# that directory always lands next to the .clab.yml file, in a predictable
# place for the automation/ scripts to find.
TOPO_DIR="$(cd "$(dirname "$TOPO")" && pwd)"
TOPO_FILE="$(basename "$TOPO")"
cd "$TOPO_DIR"

# Makes containerlab label node platforms in the generated Nornir inventory
# using NAPALM driver names (e.g. "eos") instead of the raw kind ("ceos"),
# which nornir-napalm expects.
export CLAB_NORNIR_PLATFORM_NAME_SCHEMA=napalm

# ---------------------------------------------------------------------------
# Image preflight
#
# Containerlab treats a locally-missing image as "go pull it from a registry".
# cEOS isn't on any public registry, so the pull fails with
#   pull access denied for ceos, repository does not exist
# which reads like an auth problem and sends people off to `docker login`.
# The real cause is always local: the tag in the topology doesn't match what
# was imported. Check here and say so plainly.
# ---------------------------------------------------------------------------
ceos_images() {
  sudo docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | grep '^ceos:' | grep -v ':latest$' | grep -v '<none>' || true
}

check_images() {
  local img missing=0 found n=0 first=""
  while IFS= read -r img; do
    [[ -n "$img" ]] || continue
    if sudo docker image inspect "$img" >/dev/null 2>&1; then
      continue
    fi

    # ceos:latest is the alias 01-import-ceos.sh maintains. If it's absent but
    # exactly one real cEOS image exists, this is just a pre-alias import —
    # adopt it rather than making the user re-import or hand-edit YAML.
    if [[ "$img" == "ceos:latest" ]]; then
      n=0; first=""
      while IFS= read -r found; do
        [[ -n "$found" ]] || continue
        n=$((n + 1)); [[ -z "$first" ]] && first="$found"
      done < <(ceos_images)

      if (( n == 1 )); then
        echo "==> $img is missing; tagging the one imported cEOS image ($first) as $img"
        sudo docker tag "$first" ceos:latest
        continue
      elif (( n > 1 )); then
        echo "Several cEOS images are imported, so I won't guess which one to use:" >&2
        ceos_images | sed 's/^/  /' >&2
        echo "Pick one:  docker tag <image> ceos:latest" >&2
        missing=1
        continue
      fi
    fi

    echo "Image not available locally: $img" >&2
    missing=1
  done < <(grep -E '^[[:space:]]*image:' "$TOPO_FILE" | awk '{print $2}' | sort -u)

  if (( missing )); then
    echo >&2
    if [[ -n "$(ceos_images)" ]]; then
      echo "cEOS images currently imported on this host:" >&2
      ceos_images | sed 's/^/  /' >&2
    else
      echo "No cEOS image is imported on this host. cEOS can't be pulled from a" >&2
      echo "registry — import it from the tarball you download from Arista:" >&2
      echo "  ./scripts/01-import-ceos.sh ~/cEOS64-lab-<version>.tar.xz" >&2
    fi
    return 1
  fi
  return 0
}

case "$ACTION" in
  deploy)
    check_images || exit 1
    echo "==> Deploying $TOPO_FILE (in $TOPO_DIR)"
    sudo -E containerlab deploy -t "$TOPO_FILE"
    echo
    echo "Nodes:"
    sudo containerlab inspect -t "$TOPO_FILE"
    echo
    echo "Log into a node with, e.g.:  ssh admin@clab-testlab-spine1  (password: admin)"
    echo "or:  docker exec -it clab-testlab-spine1 Cli"
    echo
    LAB_DIR="$TOPO_DIR/clab-$(grep -m1 '^name:' "$TOPO_FILE" | awk '{print $2}')"
    if [[ -d "$LAB_DIR" ]]; then
      echo "Ansible/Nornir inventories were generated at:"
      echo "  $LAB_DIR/ansible-inventory.yml"
      echo "  $LAB_DIR/nornir-simple-inventory.yml"
      echo "Wire them up for the automation/ scripts with:"
      echo "  automation/link-inventory.sh \"$LAB_DIR\""
    fi
    ;;
  destroy)
    echo "==> Destroying $TOPO_FILE"
    echo "Remember to 'write memory' on each node first if you want to keep configs —"
    echo "destroy removes containers but the clab-<lab> directory (with startup-configs)"
    echo "persists, so the next deploy restores state."
    sudo containerlab destroy -t "$TOPO_FILE"
    ;;
  inspect)
    sudo containerlab inspect -t "$TOPO_FILE"
    ;;
  graph)
    echo "==> Starting topology graph server — browse to http://<VM-IP>:50080"
    sudo containerlab graph -t "$TOPO_FILE"
    ;;
  *)
    echo "Unknown action: $ACTION (expected deploy|destroy|inspect|graph)" >&2
    exit 1
    ;;
esac
