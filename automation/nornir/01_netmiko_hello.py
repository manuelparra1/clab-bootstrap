#!/usr/bin/env python3
"""
01_netmiko_hello.py — "The Typist"

The simplest possible automation: open one SSH session with Netmiko, run
one command, print the output. No inventory framework, no concurrency —
just proving the connection works, the same first step from the course
("Hello Netmiko: Fire and Forget").

Zero setup required: this reads connection details straight out of
containerlab's auto-generated nornir-simple-inventory.yml (symlinked in by
../link-inventory.sh), which already contains cEOS's default admin/admin
credentials for every node. It grabs the first host in that file so you can
run this immediately after deploying the lab.

Set NORNIR_USERNAME / NORNIR_PASSWORD in the environment (see SECRETS.md
for three ways to do that) to override the inventory-supplied credentials.

Run from automation/nornir/, inside the netauto venv:
    netauto
    python3 01_netmiko_hello.py
"""
import os
from pathlib import Path

import yaml
from netmiko import ConnectHandler

INVENTORY_FILE = Path(__file__).parent / "nornir-simple-inventory.yml"


def main() -> None:
    if not INVENTORY_FILE.exists():
        raise SystemExit(
            f"{INVENTORY_FILE} not found.\n"
            f"Deploy the lab first (scripts/02-deploy-lab.sh), then run:\n"
            f"  ./automation/link-inventory.sh ~/labs/topologies/clab-testlab"
        )

    inventory = yaml.safe_load(INVENTORY_FILE.read_text())
    name, host = next(iter(inventory.items()))

    device = {
        "device_type": "arista_eos",
        "host": host["hostname"],
        "username": os.environ.get("NORNIR_USERNAME", host["username"]),
        "password": os.environ.get("NORNIR_PASSWORD", host["password"]),
        "port": 22,
    }

    print(f"Connecting to {name} ({device['host']})...")
    conn = ConnectHandler(**device)

    output = conn.send_command("show ip interface brief")
    print("-" * 60)
    print(output)
    print("-" * 60)

    conn.disconnect()
    print("\nThat's one device. automation/nornir/02_nornir_scale.py does this")
    print("across every device in the lab at once instead of one at a time.")


if __name__ == "__main__":
    main()
