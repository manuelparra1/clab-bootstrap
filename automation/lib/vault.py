"""
Shared secrets loader for Python automation scripts (Nornir, custom code)
that need the same credentials Ansible Vault protects.

Rather than maintaining a second secret store for Nornir, this decrypts the
exact same group_vars/ceos/vault.yml file Ansible reads — one encrypted
file, one password, two tools. It works because ansible-core (already a
project dependency) ships the same vault library `ansible-vault` itself
uses; we're not reimplementing crypto here, just calling into it directly.

Usage:
    from lib.vault import load_vault_vars
    creds = load_vault_vars("../ansible/group_vars/ceos/vault.yml")
    creds["vault_ceos_username"], creds["vault_ceos_password"]

Password resolution order (first match wins), mirroring how ansible-vault
itself resolves a password:
    1. ANSIBLE_VAULT_PASSWORD       env var (raw password)
    2. ANSIBLE_VAULT_PASSWORD_FILE  env var (path to a file containing it)
    3. Interactive prompt (getpass — same "Vault password:" experience as
       `ansible-playbook --ask-vault-pass`)

For day-to-day interactive lab use, just run the script and type the
password when asked. For unattended/CI use, set one of the env vars —
and in a real production pipeline, that env var would itself be populated
by a proper secrets manager (Vault, CyberArk, your CI platform's secret
store), not a plaintext file sitting on the runner.
"""
from __future__ import annotations

import getpass
import os
from pathlib import Path

import yaml
from ansible.parsing.vault import VaultLib, VaultSecret


def _resolve_vault_password() -> bytes:
    env_pass = os.environ.get("ANSIBLE_VAULT_PASSWORD")
    if env_pass:
        return env_pass.encode()

    pw_file = os.environ.get("ANSIBLE_VAULT_PASSWORD_FILE")
    if pw_file and Path(pw_file).is_file():
        return Path(pw_file).read_text().strip().encode()

    return getpass.getpass("Vault password: ").encode()


def load_vault_vars(path: str | Path) -> dict:
    """Decrypt (if needed) and parse an Ansible Vault YAML file, returning
    its contents as a plain dict. Works on both encrypted and plain YAML,
    so it's safe to point at vault.yml.example during initial setup too.
    """
    path = Path(path)
    if not path.is_file():
        raise FileNotFoundError(
            f"{path} not found — did you run the vault setup steps in "
            f"vault.yml.example (copy, edit, ansible-vault encrypt)?"
        )

    raw = path.read_bytes()

    if raw.startswith(b"$ANSIBLE_VAULT"):
        password = _resolve_vault_password()
        vault = VaultLib(secrets=[("default", VaultSecret(password))])
        raw = vault.decrypt(raw)

    return yaml.safe_load(raw)
