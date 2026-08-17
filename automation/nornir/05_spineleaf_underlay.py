#!/usr/bin/env python3
"""
05_spineleaf_underlay.py — deploy the OSPF underlay to the spine-leaf fabric.

Same pattern as 04_idempotent_deploy.py (render template -> NAPALM diff ->
push only if different), but now with real per-host data: each node gets
its own loopback, router-id, and a list of fabric interfaces with /31
point-to-point addressing.

Prereqs:
  1. Deploy the fabric:   ./scripts/02-deploy-lab.sh topologies/spine-leaf.clab.yml
  2. Re-link inventory:   ./automation/link-inventory.sh ~/labs/topologies/clab-spineleaf
     (or wherever the clab-spineleaf directory landed — the deploy script
     prints the path)

Run from automation/nornir/, inside the netauto venv:
    netauto
    python3 05_spineleaf_underlay.py
    python3 05_spineleaf_underlay.py   # second run: changed=False everywhere

Verify on any node afterwards:
    ssh admin@clab-spineleaf-leaf1
    show ip ospf neighbor        # expect FULL to both spines
    ping 10.255.0.12 source 10.255.0.11   # leaf1 loopback -> leaf2 loopback

IP plan (see course/03-spine-leaf.md for the reasoning):
  Loopbacks /32:  spine1=10.255.0.1  spine2=10.255.0.2
                  leaf1 =10.255.0.11 leaf2 =10.255.0.12
  P2P links /31:  spine1-leaf1 10.0.1.0/31   spine1-leaf2 10.0.1.2/31
                  spine2-leaf1 10.0.2.0/31   spine2-leaf2 10.0.2.2/31
  (/31 on point-to-point links is standard modern practice — RFC 3021 —
   and halves your address burn vs /30s.)
"""
from nornir import InitNornir
from nornir_jinja2.plugins.tasks import template_file
from nornir_napalm.plugins.tasks import napalm_configure
from nornir_utils.plugins.functions import print_result

from creds import apply_credential_override

FABRIC = {
    "clab-spineleaf-spine1": {
        "role": "spine",
        "loopback": "10.255.0.1/32",
        "router_id": "10.255.0.1",
        "interfaces": [
            {"name": "Ethernet1", "description": "to_leaf1_Et1", "ip": "10.0.1.0/31"},
            {"name": "Ethernet2", "description": "to_leaf2_Et1", "ip": "10.0.1.2/31"},
        ],
    },
    "clab-spineleaf-spine2": {
        "role": "spine",
        "loopback": "10.255.0.2/32",
        "router_id": "10.255.0.2",
        "interfaces": [
            {"name": "Ethernet1", "description": "to_leaf1_Et2", "ip": "10.0.2.0/31"},
            {"name": "Ethernet2", "description": "to_leaf2_Et2", "ip": "10.0.2.2/31"},
        ],
    },
    "clab-spineleaf-leaf1": {
        "role": "leaf",
        "loopback": "10.255.0.11/32",
        "router_id": "10.255.0.11",
        "interfaces": [
            {"name": "Ethernet1", "description": "to_spine1_Et1", "ip": "10.0.1.1/31"},
            {"name": "Ethernet2", "description": "to_spine2_Et1", "ip": "10.0.2.1/31"},
        ],
    },
    "clab-spineleaf-leaf2": {
        "role": "leaf",
        "loopback": "10.255.0.12/32",
        "router_id": "10.255.0.12",
        "interfaces": [
            {"name": "Ethernet1", "description": "to_spine1_Et2", "ip": "10.0.1.3/31"},
            {"name": "Ethernet2", "description": "to_spine2_Et2", "ip": "10.0.2.3/31"},
        ],
    },
}


def deploy_underlay(task):
    if task.host.name not in FABRIC:
        print(f"Skipping {task.host.name}: not in the FABRIC data "
              f"(is the spineleaf inventory linked? see docstring)")
        return
    task.host.data.update(FABRIC[task.host.name])

    rendered = task.run(
        task=template_file,
        template="spineleaf_underlay.j2",
        path="templates",
    )

    task.run(
        task=napalm_configure,
        configuration=rendered.result,
        replace=False,
        dry_run=False,
    )


def main() -> None:
    nr = InitNornir(config_file="config.yaml")
    apply_credential_override(nr)

    results = nr.run(task=deploy_underlay)
    print_result(results)

    print("\nVerify from any leaf:")
    print("  show ip ospf neighbor                       (expect FULL x2)")
    print("  ping 10.255.0.12 source 10.255.0.11         (loopback to loopback)")


if __name__ == "__main__":
    main()
