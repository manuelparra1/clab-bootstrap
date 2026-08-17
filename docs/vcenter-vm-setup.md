# Building the Lab VM in vCenter

One-time setup, done in the vSphere Client, before you ever touch a terminal. Takes about 10 minutes. These are the settings the reference build used and validated — deviate at your own risk, but the two things that actually matter are the **network adapter type/port group** and the **guest OS type**.

## 1. Get a Debian 13 (Trixie) ISO onto a datastore

vCenter's built-in guest OS catalog does **not** ship a Debian installer — you have to bring your own ISO.

1. From your laptop, download the **DVD-1** ISO (not the netinst image — netinst requires internet access mid-install to pull packages, and if your VM's network isn't configured yet, you'll land in a broken minimal system with no `ifupdown`, `sudo`, or `openssh-server`): `https://www.debian.org/distrib/` → amd64 → complete installer set → DVD-1.
2. In the vSphere Client, go to your datastore (or a Content Library if your team uses one) → **Upload Files** → upload the ISO.

## 2. Create the VM

vSphere Client → your resource pool → **Actions → New Virtual Machine → Create a new virtual machine**.

| Setting | Value |
| --- | --- |
| Compatibility | ESXi 6.7 or later |
| Guest OS family | Linux |
| Guest OS version | **Other 4.x or later Linux (64-bit)** |
| CPU | 8 vCPUs (1 socket × 8 cores) |
| Memory | 32 GB |
| Hard disk | 64 GB, **Thin Provision** |
| SCSI Controller | VMware Paravirtual |
| Network Adapter | **VMXNET3** — see step 3, this is the important one |
| CD/DVD Drive | Datastore ISO File → point at the Debian ISO you uploaded; check **Connect At Power On** |

Why these specs: cEOS nodes run ~0.5–1 GB RAM each. 32 GB comfortably supports a handful of nodes (a ring of 6 routers, or a small spine-leaf) without starving the host. Scale up if you're planning something bigger.

## 3. Network adapter — the part that actually matters

Set the adapter type to **VMXNET3** and connect it to the port group your team uses for routable WiFi access — ask whoever manages the resource pool which port group that is if you don't already know it (in the reference build this was a `/23` with DHCP enabled, reachable directly from work WiFi and via OpenVPN from home, no NAT required).

Do **not** attach it to an isolated/NAT'd lab network if you want direct SSH from your laptop — that path requires port-forwarding or jump hosts and was the whole workaround this repo is designed to avoid.

Confirm **Connect At Power On** is checked for the adapter.

## 4. Install Debian

Power on the VM, open the console, and run through the Debian installer normally:

- Hostname/domain: your choice
- Partitioning: guided, use entire disk, is fine for a lab VM
- Software selection: **uncheck desktop environments**, keep only **SSH server** and **standard system utilities** — you don't need a GUI
- Set a root password and create your user account

Reboot when it finishes and remove the ISO from the CD/DVD drive (vSphere Client → Edit Settings → CD/DVD → Disconnect) so it doesn't try to boot the installer again.

## 5. First login and DHCP check

At the console (not SSH yet — you don't have an IP):

```bash
ip addr show ens192
```

If DHCP already handed you an address (likely, since the port group provides it), you can `ssh` in immediately from your laptop. If not, see the DHCP troubleshooting table in the main `README.md` — you may need to `su -` and run `apt install ifupdown` first, since a minimal install sometimes leaves that out.

Once you have SSH access, continue with the main `README.md` **Quick Start** section — copy this repo over and run `scripts/00-bootstrap.sh`.
