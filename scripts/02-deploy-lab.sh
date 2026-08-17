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

case "$ACTION" in
  deploy)
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
