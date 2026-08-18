# Getting These Files Onto Your Lab VM

Three ways, depending on what your team has set up. Any of them works — they all end with the same files in `~/clab-bootstrap` on the VM, at which point you run `./setup.sh`.

---

## Option 1: Internal git repo (best for a team)

If your team has an internal git host (GitHub Enterprise, GitLab, Gitea, Bitbucket), this is the one to use. Coworkers pull updates instead of re-copying a zip every time something changes.

**One-time, by whoever owns the repo (you):**

```bash
cd clab-bootstrap
git init
git add .
git commit -m "Containerlab automation lab bootstrap"
git branch -M main
git remote add origin <your-internal-git-url>
git push -u origin main
```

**Then, on each person's VM:**

```bash
sudo apt install -y git          # if not already there
git clone <your-internal-git-url> ~/clab-bootstrap
cd ~/clab-bootstrap
./setup.sh
```

Getting updates later:

```bash
cd ~/clab-bootstrap && git pull && ./setup.sh
```

`setup.sh` is safe to re-run — it detects what's already installed and skips it, so pulling and re-running is the normal update path.

> **Before you push:** the `.gitignore` already excludes credentials, `.env` files, cEOS images, and containerlab's generated inventories. Give `git status` a quick read on your first commit anyway, just to be sure nothing sensitive is staged. That habit is worth building regardless.

---

## Option 2: scp the folder (no git needed)

Fine for a couple of people, or a one-off.

```bash
# From your laptop, in the directory ABOVE clab-bootstrap:
scp -r clab-bootstrap yourname@<VM-IP>:~/

ssh yourname@<VM-IP>
cd ~/clab-bootstrap
chmod +x setup.sh lab scripts/*.sh
./setup.sh
```

The `chmod` line matters — `scp` doesn't always preserve the executable bit depending on the source filesystem.

---

## Option 3: zip file (email/Slack/USB friendly)

If you're handing this to someone who can't reach your git host and doesn't want to think about `scp -r`:

```bash
# On your laptop:
zip -r clab-bootstrap.zip clab-bootstrap
scp clab-bootstrap.zip yourname@<VM-IP>:~/

# On the VM:
sudo apt install -y unzip
unzip clab-bootstrap.zip
cd clab-bootstrap
chmod +x setup.sh lab scripts/*.sh
./setup.sh
```

---

## Which should we standardize on?

Git, if you have anywhere to put it. Not because zip or scp don't work, but because:

- **Updates are one command** (`git pull`) instead of re-copying and hoping everyone has the current version.
- **Everyone's on the same version**, and `git log` says what changed.
- **People can contribute back** — a coworker who fixes a bug or adds a topology can open a PR instead of emailing you a file.
- **It's the same workflow as the automation itself.** The whole point of the Nornir/Ansible material here is treating infrastructure as code in version control; distributing the lab that way is a small bit of practicing what it preaches.

If there's no internal git host and you'd rather not push work code to a personal account, zip is completely fine. It's a lab, not production.
