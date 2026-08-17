#!/usr/bin/env bash
#
# link-inventory.sh <path-to-clab-lab-dir>
#
# Containerlab auto-generates ansible-inventory.yml and
# nornir-simple-inventory.yml inside the lab's clab-<labname> directory on
# every `deploy` (management IPs change per deploy, so these are always
# freshly regenerated — no manual inventory to maintain).
#
# This script symlinks the current lab's copies into fixed locations so
# ansible.cfg and nornir/config.yaml can reference stable paths regardless
# of which lab you last deployed.
#
# Example:
#   ./automation/link-inventory.sh ~/labs/topologies/clab-testlab
#
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <path-to-clab-<labname>-directory>" >&2
  echo "(printed at the end of scripts/02-deploy-lab.sh)" >&2
  exit 1
fi

LAB_DIR="$(cd "$1" && pwd)"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ANSIBLE_SRC="$LAB_DIR/ansible-inventory.yml"
NORNIR_SRC="$LAB_DIR/nornir-simple-inventory.yml"

for f in "$ANSIBLE_SRC" "$NORNIR_SRC"; do
  [[ -f "$f" ]] || { echo "Not found: $f (did the lab finish deploying?)" >&2; exit 1; }
done

ln -sf "$ANSIBLE_SRC" "$REPO_DIR/ansible/inventory.yml"
ln -sf "$NORNIR_SRC"  "$REPO_DIR/nornir/nornir-simple-inventory.yml"

echo "Linked:"
echo "  automation/ansible/inventory.yml         -> $ANSIBLE_SRC"
echo "  automation/nornir/nornir-simple-inventory.yml -> $NORNIR_SRC"
echo
echo "Try it:"
echo "  netauto   # activates the venv"
echo "  cd automation/ansible && ansible-playbook playbooks/gather_facts.yml"
