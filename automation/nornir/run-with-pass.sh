#!/usr/bin/env bash
#
# run-with-pass.sh <command> [args...]
#
# Sources credentials from `pass` (the standard Unix password manager —
# GPG-encrypted, git-friendly, one file per secret) instead of a plaintext
# .env file. See SECRETS.md for the one-time setup (GPG key, pass init,
# pass insert).
#
# Example:
#   ./run-with-pass.sh python3 02_nornir_scale.py
#
set -euo pipefail

# Edit these to match whatever paths you used with `pass insert`.
PASS_USERNAME_ENTRY="network/clab-ceos/username"
PASS_PASSWORD_ENTRY="network/clab-ceos/password"

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <command> [args...]" >&2
  exit 1
fi

if ! command -v pass >/dev/null 2>&1; then
  echo "'pass' not found. Install: sudo apt install pass" >&2
  echo "Then see SECRETS.md for the GPG key + pass init + pass insert steps." >&2
  exit 1
fi

export NORNIR_USERNAME="$(pass show "$PASS_USERNAME_ENTRY")"
export NORNIR_PASSWORD="$(pass show "$PASS_PASSWORD_ENTRY")"

exec "$@"
