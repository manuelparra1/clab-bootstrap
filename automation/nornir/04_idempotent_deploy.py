#!/usr/bin/env python3
"""
04_idempotent_deploy.py — "The Architect" / self-healing demo

This is the payoff script — the one worth showing coworkers. It combines
everything from 01-03:

  1. Render:   Jinja2 template + per-host data -> desired config
  2. Compare:  NAPALM diffs the candidate against the live running-config
  3. Enforce:  only push if there's an actual difference

Run it twice in a row and watch the difference:
  - 1st run:  loopback is missing -> diff shown -> config pushed -> "changed"
  - 2nd run:  loopback already matches -> empty diff -> nothing pushed -> "no changes"

That's the entire pitch for declarative automation in one demo: idempotency
means running the same script 100 times is exactly as safe as running it
once.

Per-host template data is assigned right here in the script (site_code,
loopback ID/address) rather than in a separate data file, so this stays a
self-contained, zero-extra-setup demo against the 2-node test topology.
Extend the DEMO_DATA dict (or move it into inventory `data:` fields) as you
grow past the test lab.

Run from automation/nornir/, inside the netauto venv:
    netauto
    python3 04_idempotent_deploy.py
    python3 04_idempotent_deploy.py   # run again to see idempotency in action
"""
from nornir import InitNornir
from nornir_jinja2.plugins.tasks import template_file
from nornir_napalm.plugins.tasks import napalm_configure
from nornir_utils.plugins.functions import print_result

from creds import apply_credential_override

# Per-host data the Jinja2 template needs. In a bigger lab this would live
# in inventory `data:` fields (hosts.yaml or containerlab topology labels)
# instead of being hardcoded here.
DEMO_DATA = {
    "clab-testlab-spine1": {
        "site_code": "LAB-01",
        "mgmt_lo_id": "0",
        "mgmt_lo_ip": "10.255.1.1/32",
    },
    "clab-testlab-spine2": {
        "site_code": "LAB-01",
        "mgmt_lo_id": "0",
        "mgmt_lo_ip": "10.255.1.2/32",
    },
}


def deploy_architecture(task):
    task.host.data.update(DEMO_DATA.get(task.host.name, {}))
    if "site_code" not in task.host.data:
        print(f"Skipping {task.host.name}: no demo data defined for it "
              f"(add an entry to DEMO_DATA in this script)")
        return

    # Step 1: render the desired-state config from the template
    rendered = task.run(
        task=template_file,
        template="ceos_base.j2",
        path="templates",
    )

    # Step 2 + 3: NAPALM compares candidate vs running config and only
    # pushes if they differ. dry_run=False means "actually enforce it",
    # but napalm_configure still only sends something if there's a diff.
    task.run(
        task=napalm_configure,
        configuration=rendered.result,
        replace=False,   # merge — only touch what's specified, don't wipe the box
        dry_run=False,
    )


def main() -> None:
    nr = InitNornir(config_file="config.yaml")
    apply_credential_override(nr)  # no-op unless NORNIR_USERNAME/PASSWORD are set

    results = nr.run(task=deploy_architecture)
    print_result(results)

    print("\nRun this script again — if nothing changed on the device since")
    print("the last run, you should see 'changed: False' this time. That's")
    print("idempotency: the script describes a *goal*, not a list of steps.")


if __name__ == "__main__":
    main()
