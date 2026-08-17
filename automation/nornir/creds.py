"""
Optional credential override for the Nornir demo scripts.

By default, every script in this folder uses whatever credentials
containerlab baked into the auto-generated inventory (admin/admin for
cEOS) — that's what makes the demo need zero setup.

If NORNIR_USERNAME / NORNIR_PASSWORD are set in the environment when a
script runs, this overrides the inventory defaults with those instead. It
doesn't care *how* those env vars got set — that's the point. Three ways
to set them, same effect, pick whichever backend you want to demo:

    ./run-with-env.sh   python3 02_nornir_scale.py   # plaintext .env file
    ./run-with-pass.sh  python3 02_nornir_scale.py   # `pass` (GPG-backed)
    ./run-with-sops.sh  python3 02_nornir_scale.py   # sops + age (encrypted file)

See SECRETS.md for how each of those three works.
"""
import os


def apply_credential_override(nr):
    username = os.environ.get("NORNIR_USERNAME")
    password = os.environ.get("NORNIR_PASSWORD")
    if username:
        nr.inventory.defaults.username = username
    if password:
        nr.inventory.defaults.password = password
    return nr
