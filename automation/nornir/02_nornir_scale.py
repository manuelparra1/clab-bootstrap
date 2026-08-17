#!/usr/bin/env python3
"""
02_nornir_scale.py — "Scaling from 1 to Many"

Same idea as 01_netmiko_hello.py — run a show command — but against every
node in the lab at once instead of one at a time. Nornir owns the
inventory (config.yaml -> nornir-simple-inventory.yml, generated fresh by
containerlab on every deploy) and the concurrency (threaded runner), so the
script itself doesn't grow at all as the topology grows from 2 nodes to 50.

Run from automation/nornir/, inside the netauto venv:
    netauto
    python3 02_nornir_scale.py

Uses whatever credentials containerlab put in the inventory by default —
override them via any of the three secrets backends in SECRETS.md, e.g.:
    ./run-with-env.sh python3 02_nornir_scale.py
"""
from nornir import InitNornir
from nornir_netmiko.tasks import netmiko_send_command
from nornir_utils.plugins.functions import print_result

from creds import apply_credential_override


def say_hello(task):
    task.run(
        task=netmiko_send_command,
        command_string="show ip interface brief",
    )


def main() -> None:
    nr = InitNornir(config_file="config.yaml")
    apply_credential_override(nr)  # no-op unless NORNIR_USERNAME/PASSWORD are set
    print(f"Inventory loaded: {list(nr.inventory.hosts.keys())}")

    results = nr.run(task=say_hello)
    print_result(results)


if __name__ == "__main__":
    main()
