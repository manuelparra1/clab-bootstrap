#!/usr/bin/env python3
"""
03_napalm_facts.py — "Structured Data instead of Screen Scraping"

02_nornir_scale.py got us raw CLI text back from every device — readable,
but fragile to parse (a wording change in a future EOS release could break
anything downstream that greps it). NAPALM getters return real Python
dicts/JSON instead, which is what makes the next step (idempotent
diff-and-enforce, see 04_idempotent_deploy.py) possible at all.

Run from automation/nornir/, inside the netauto venv:
    netauto
    python3 03_napalm_facts.py
"""
from nornir import InitNornir
from nornir_napalm.plugins.tasks import napalm_get
from nornir_utils.plugins.functions import print_result

from creds import apply_credential_override


def get_facts(task):
    task.run(task=napalm_get, getters=["facts", "interfaces_ip"])


def main() -> None:
    nr = InitNornir(config_file="config.yaml")
    apply_credential_override(nr)  # no-op unless NORNIR_USERNAME/PASSWORD are set
    results = nr.run(task=get_facts)
    print_result(results)


if __name__ == "__main__":
    main()
