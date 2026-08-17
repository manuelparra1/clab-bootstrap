#!/usr/bin/env bash
#
# run-with-sops.sh <command> [args...]
#
# Decrypts secrets.enc.yaml (encrypted with sops + age) directly into the
# child process's environment for the duration of that one command, using
# `sops exec-env` — nothing touches disk unencrypted, nothing lingers in
# shell history. See SECRETS.md for the one-time setup (age-keygen,
# encrypting secrets.example.yaml -> secrets.enc.yaml).
#
# Example:
#   ./run-with-sops.sh python3 02_nornir_scale.py
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_FILE="$SCRIPT_DIR/secrets.enc.yaml"

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <command> [args...]" >&2
  exit 1
fi

if ! command -v sops >/dev/null 2>&1; then
  echo "'sops' not found. See SECRETS.md for install instructions" >&2
  echo "(no apt package on Debian — install the .deb from GitHub releases)." >&2
  exit 1
fi

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "No $SECRETS_FILE found." >&2
  echo "See SECRETS.md: copy secrets.example.yaml, fill it in, then" >&2
  echo "  sops --encrypt --age <your-age-public-key> -i secrets.enc.yaml" >&2
  exit 1
fi

exec sops exec-env "$SECRETS_FILE" "$*"
