# FortiGate on Containerlab (via vrnetlab)

FortiGate is not a container. It ships as a **qcow2 disk image** — a full VM — so
Containerlab runs it through [vrnetlab](https://github.com/hellt/vrnetlab), which
wraps a vendor VM in a container that QEMU boots at start-up.

That has two consequences worth understanding before you start:

1. **There is no image to pull.** `vrnetlab/vr-fortios:7.0.9` does not exist on
   any registry. You build it locally from the qcow2. `02-deploy-lab.sh` checks
   for it and stops with this message rather than letting Containerlab try a
   registry and fail with a confusing "pull access denied".
2. **It needs hardware virtualization.** QEMU inside the container wants
   `/dev/kvm`. On a VM (which this lab host is), that means *nested*
   virtualization has to be switched on at the hypervisor. Without it FortiGate
   either refuses to boot or falls back to pure emulation and takes many minutes
   per node.

---

## The short version

```bash
./lab fortigate          # or: ./scripts/03-build-vrnetlab.sh
```

That one command does everything below: checks `/dev/kvm` and tells you exactly
which hypervisor setting to change if it's missing, installs build
dependencies, clones or updates vrnetlab, finds your `.qcow2`, builds, reports
the image tag it actually produced, and offers to update your topology files to
match that tag. It's safe to re-run.

`setup.sh` also offers it, but only when one of your topologies actually
references a `vrnetlab/` image — the cEOS-only path never sees the prompt.

The rest of this document is what that script does, for when you want to do it
by hand or something goes sideways.

---

## 1. Check nested virtualization first

Do this before downloading anything — if it's off, nothing else matters.

```bash
ls -l /dev/kvm                          # must exist
grep -Ec '(vmx|svm)' /proc/cpuinfo      # must be > 0
```

If `/dev/kvm` is missing:

- **vSphere / ESXi** — power the VM off, then Edit Settings → expand **CPU** →
  tick **Hardware virtualization: Expose hardware assisted virtualization to the
  guest OS**. Power back on. (`docs/vcenter-vm-setup.md` builds the VM without
  this, since cEOS doesn't need it.)
- **Proxmox** — set the VM's CPU type to `host` and make sure nesting is enabled
  on the Proxmox host. See `docs/proxmox-vm-setup.md`.

## 2. Get the qcow2

**Team Drive (internal mirror):**
<https://drive.google.com/drive/folders/1kBDv_xgv4T4NQJfWZtLKkCnYbmcfs9KU?usp=drive_link>
→ `ContainerLab/Fortigate Images/fortinet-FGT-v7.0.9-build0444.qcow2`

**Or from the vendor**, if you'd rather pull it yourself or need a different
build: <https://support.fortinet.com> → Download → VM Images → select the KVM
image for your version.

Either way you need a valid Fortinet entitlement to use the image — the mirror is
a convenience for people who already have one, not a way around licensing.

Copy it to the lab host:

```bash
scp fortinet-FGT-v7.0.9-build0444.qcow2 <you>@<VM-IP>:~/
```

## 3. Build the container image

```bash
sudo apt-get install -y make git qemu-kvm
git clone https://github.com/hellt/vrnetlab.git ~/vrnetlab
cd ~/vrnetlab
ls                       # find the FortiGate directory for your vrnetlab version
```

The directory name has changed across vrnetlab releases — current trees use
`fortinet_fortigate/`, older ones `fortios/`. Use whichever your clone has:

```bash
cd ~/vrnetlab/fortinet_fortigate      # or fortios/ on older trees
cp ~/fortinet-FGT-v7.0.9-build0444.qcow2 .
make
```

The build boots the VM once to prepare it, so it takes a few minutes.

## 4. Match the tag to your topology

**This is the step people miss.** vrnetlab's image tag has also changed across
versions — newer trees produce `vrnetlab/fortinet_fortigate:<version>`, older
ones `vrnetlab/vr-fortios:<version>`. Check what you actually got:

```bash
docker images | grep -i forti
```

Then make `topologies/memory-test.clab.yml` agree with it:

```yaml
  kinds:
    fortinet_fortigate:
      image: vrnetlab/vr-fortios:7.0.9      # <- must match `docker images`
```

A mismatch here produces exactly the "not available locally" stop from
`02-deploy-lab.sh`, which is the intended behaviour — it's telling you the truth.

## 5. Deploy

```bash
./lab topo memory-test.clab.yml
./lab deploy
```

FortiGate nodes boot far more slowly than cEOS — allow several minutes before
the management interface answers. `./lab status` shows when the containers are
up; the VM inside takes longer still.

Default credentials on a fresh FortiGate VM are `admin` with an **empty**
password, and it forces a password change on first login. That's a different
account from the cEOS nodes' `admin`/`admin`.

---

## Resource cost

A FortiGate VM node is much heavier than a cEOS node — roughly 1–2 GB RAM each
plus QEMU overhead, against ~0.5–1 GB for cEOS. `memory-test.clab.yml` runs two
of them alongside four cEOS nodes and four small containers; budget around 8–10 GB
of the VM's 32 GB, and destroy the lab when you stop for the day.
