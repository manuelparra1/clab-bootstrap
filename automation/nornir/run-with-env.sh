#!/usr/bin/env bash
#
# run-with-env.sh <command> [args...]
#
# The zero-tool option: source a plaintext .env file, export everything in
# it, run the command, done. `set -a` auto-exports every variable a
# subsequent `source` defines, so .env doesn't need "export" prefixes on
# each line and we don't need python-dotenv or any other library — this is
# plain bash.
#
# Example:
#   cp .env.example .env && nano .env
#   ./run-with-env.sh python3 02_nornir_scale.py
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <command> [args...]" >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "No .env file at $ENV_FILE" >&2
  echo "Run: cp .env.example .env && nano .env" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

exec "$@"
