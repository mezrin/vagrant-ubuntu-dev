# x86_64 development server

This directory provisions a bare-metal or cloud **x86_64 Ubuntu 26.04** server
as a development machine equivalent to the Vagrant guest described in the
[main README](../README.md). It reuses the same provisioning scripts from
`provision/ubuntu-26.04/` and the same tool versions. It replaces only the
parts that exist because the guest is a Parallels VM on a Mac.

It was first used on `dev-10`: 24 cores, 251 GiB of memory, a 1.7 TB root
filesystem, and one public interface (`eno1`).

| File | Purpose |
| --- | --- |
| `setup.sh` | Runs the provisioning steps in order, as root or as the user. |
| `server.env` | Every input: versions, x86_64 URLs and SHA-256 digests, identity, and network settings. |
| `provision/firewall.sh` | UFW policy for a public server. |
| `provision/ssh-hardening.sh` | Allows only public-key SSH logins. |

## What changed compared with the Vagrant template

### Scripts used unchanged

`os-package-security-baseline.sh`, `development-kernel-limits.sh`,
`general-dev-user.sh`, `python.sh`, `python-user.sh` and `mongodb.sh` run
exactly as Vagrant runs them. Only the inputs in `server.env` differ.

### PostgreSQL fix, which also affects Vagrant

`postgresql.sh` used to pin only `postgresql-18` to 18.4. That package
requires `postgresql-client-18` of exactly the same version. Once PGDG
published 18.6, apt chose the newer client, so the install failed with
"Unable to satisfy dependencies". A fresh Vagrant provision fails the same
way. The script now pins and installs `postgresql-client-<major>` at the same
version as the server package.

### Scripts made architecture-neutral

The Vagrant pins are ARM64. Four installers had ARM64 names hard-coded, so they
now derive the archive's top-level directory from the configured URL. The
Vagrantfile still passes the same ARM64 values, so Vagrant behaves as before.

| Script | Before | Now |
| --- | --- | --- |
| `github-cli.sh` | Refused any architecture except `arm64`; used `gh_<v>_linux_arm64/` | Requires the URL to name `gh_<v>_linux_<dpkg architecture>.tar.gz` |
| `python-uv.sh` | Used `uv-aarch64-unknown-linux-gnu/` | Uses the URL's base name |
| `nodejs.sh` | Used `node-<v>-linux-arm64/` | Uses the URL's base name |
| `rust-for-substrate.sh` | Only the comment mentioned ARM64 | Comment updated; the URL selects the target |

`server.env` pins the x86_64 archives for the same versions. The digests were
taken from each project's official checksum file:

| Component | Archive | SHA-256 |
| --- | --- | --- |
| GitHub CLI 2.94.0 | `gh_2.94.0_linux_amd64.tar.gz` | `a757f1ba…12ed62` |
| rustup 1.29.0 | `x86_64-unknown-linux-gnu/rustup-init` | `4acc9acc…5aa10` |
| uv 0.11.16 | `uv-x86_64-unknown-linux-gnu.tar.gz` | `74947fe2…116131` |
| Node.js v22.23.2 | `node-v22.23.2-linux-x64.tar.gz` | `b294a556…c9252a` |

NVM and Corepack are source archives, and the Docker, PostgreSQL and MongoDB
pins are the same on both architectures.

### Docker: new `public-server` ingress policy

`docker.sh` now requires `DOCKER_INGRESS_POLICY`:

- `vagrant-adapters` keeps the original three-adapter policy. The Vagrantfile
  now passes this explicitly.
- `public-server` is used here. Docker's default published-port address is
  `127.0.0.1` (`PRIVATE_NETWORK_IP` in `server.env`), so `docker run -p
  8080:80` listens on loopback only. The `DOCKER-USER` chain also drops every
  new connection that arrives on a physical network interface. Even
  `-p 0.0.0.0:8080:80` is therefore not reachable from the internet. Docker
  forwards published ports before UFW sees the packets, so UFW alone would not
  protect them. Containers keep normal outbound access.

### MongoDB inputs

`mongodb.sh` is unchanged. It runs with these server values:

- It binds to `127.0.0.1:27017` instead of `192.168.56.7:27017`.
- The replica-set member is `localhost:27017` instead of `dev-07:27017`.
  `localhost` resolves to this `mongod` both inside the container and on the
  server, so clients work with or without `directConnection=true`.
- The user is still `vagrant`, with the same replica set `rs0` and
  `authSource=admin`.
- The password comes from `MONGODB_PASSWORD`, or from the gitignored
  `.secrets/mongodb-password` in this checkout. If neither exists, `setup.sh`
  generates a random password into that file with mode `0600`.

### Vagrant provisioners not used on the server

| Provisioner | Reason |
| --- | --- |
| `network-security.sh` | Manages Netplan routes and UFW for three Parallels adapters. Replaced by `provision/firewall.sh`. Running it on a remote server could break networking and SSH. |
| `network-link-recovery.sh` | Repairs Netplan after Parallels link resets. Not applicable. |
| `enlarge-hdd.sh` | Grows the LVM disk of the Vagrant box. Not applicable. |
| `ubuntu-desktop.sh` | Graphical desktop. The server is used headless through VS Code Remote SSH. |
| `nginx.sh` | Not needed now. Running it would also need ports 80 and 443 opened. |

The Ubuntu package list in `server.env` leaves out the corresponding packages:
`ubuntu-desktop-minimal`, `network-manager` (the server uses
systemd-networkd), `lvm2`, `cloud-guest-utils`, `nginx` and `certbot`.

### New server-only steps

- **`provision/firewall.sh`** sets UFW to deny incoming and allow outgoing
  traffic. It always allows the port(s) sshd listens on, read from `sshd -T`,
  and adds that rule before anything else changes. It opens
  `SERVER_PUBLIC_TCP_PORTS`, which is empty by default. On every run it removes
  stale rules tagged `Server managed` and leaves other rules alone.
- **`provision/ssh-hardening.sh`** writes
  `/etc/ssh/sshd_config.d/00-server-key-only.conf`:
  - `PasswordAuthentication no`
  - `KbdInteractiveAuthentication no`
  - `PermitRootLogin prohibit-password`

  It refuses to run if the development user has no `authorized_keys`. It
  validates the result with `sshd -t` and reloads sshd, so open sessions stay
  connected. Before this change, root accepted passwords and was under constant
  password brute-forcing.

### Identity

The development user is whoever runs `setup.sh` (`ubuntu` here), not
`vagrant`. Git uses the same name, email and `code --wait` editor. The GitHub
SSH key is `~/.ssh/github_dev-10_mezrin_ed25519`.

## How to run it

Prerequisites:

- Ubuntu 26.04 on x86_64 (`dpkg --print-architecture` prints `amd64`).
- A non-root user with sudo, who can already log in with an SSH key.
- This repository checked out on the server, with the `dev-server-x86` branch.

Review `server.env` first. In particular, check `GIT_*`,
`GITHUB_SSH_IDENTITY_FILE` and `SERVER_PUBLIC_TCP_PORTS`. Then run as the
development user (not with sudo):

```sh
cd ~/dev/server-setup/vagrant-ubuntu-dev
server/setup.sh 2>&1 | tee ~/server-setup.log
```

Run selected steps, in any combination, in the order shown by `--list`:

```sh
server/setup.sh --list
server/setup.sh docker mongodb
```

Steps run in this order:

| Step | Runs as | Script |
| --- | --- | --- |
| `os-package-security-baseline` | root | Ubuntu packages and unattended security upgrades |
| `development-kernel-limits` | root | inotify limits for large workspaces |
| `ssh-hardening` | root | Key-only SSH |
| `firewall` | root | UFW |
| `general-dev-user` | user | Git identity and GitHub SSH key |
| `github-cli` | root | `gh` |
| `docker` | root | Docker Engine, Buildx and Compose, plus the `public-server` ingress policy; adds the user to `docker` |
| `rust-for-substrate` | user | rustup, Rust 1.97.1, nightly-2026-07-31 and `wasm32-unknown-unknown` |
| `python-uv` | root | `uv` and `uvx` |
| `python`, `python-user` | user | Python 3.12.13 and 3.13.12; pip requires a virtual environment |
| `nodejs` | user | NVM, Node.js v22.23.2 and Corepack |
| `postgresql` | root | PostgreSQL 18 from PGDG |
| `mongodb` | root | Authenticated single-node MongoDB 7.0 replica set in Docker |

Every step is safe to run again. A failed step stops the run; fix the cause
and rerun that step or the whole script.

### Applying the results

1. **Log out and back in**, or use VS Code's "Kill VS Code Server on Host" and
   reconnect. Your existing shell does not yet have the `docker` group or the
   new PATH entries (`~/.cargo/bin`, `~/.local/bin`, NVM).
2. **Reboot if Ubuntu asks for it.** `setup.sh` prints a message when
   `/run/reboot-required` exists. Run `sudo reboot`. Docker, MongoDB,
   PostgreSQL and UFW all start again on boot.
3. **Point apps at loopback.** Replace `192.168.56.7` and `dev-07` in app
   configuration with `localhost`.

## Using the services

All development services listen on `127.0.0.1` only. To reach one from your
laptop, forward its port over SSH. VS Code Remote SSH does this automatically
when a process opens a port, or you can add ports in the **Ports** panel. From
a terminal:

```sh
ssh -N -L 3000:localhost:3000 -L 9944:localhost:9944 ubuntu@dev-10
```

### PostgreSQL

PostgreSQL 18 uses the package defaults, as on the Vagrant box: it listens
locally, and no app role or database is created.

```sh
sudo -u postgres psql
```

### MongoDB

Run `cat .secrets/mongodb-password` in this checkout to see the password.
URL-encode it if it contains special characters.

```text
mongodb://vagrant:PASSWORD@localhost:27017/admin?authSource=admin&replicaSet=rs0&directConnection=true
```

### Opening a port to the internet

Only SSH is public. To publish something, for example a web server on 80 and
443, set `SERVER_PUBLIC_TCP_PORTS="80 443"` in `server.env`, make the service
listen on a public address, and run `server/setup.sh firewall`. Removing a port
from the list and rerunning the step closes it again.

A Docker container cannot be made public this way: the `public-server` policy
blocks inbound connections to containers. Put a reverse proxy on the host in
front of it instead.

## Checking the result

```sh
sudo ufw status verbose                  # deny incoming; only 22/tcp allowed
sudo sshd -T | grep -E '^(passwordauthentication|permitrootlogin) '
sudo ss -tlnp | grep -vE '127\.0\.0\.|\[::1\]'   # only sshd remains
docker run --rm hello-world
gh --version; rustup show; uv --version; python3.13 --version
node --version; corepack --version
pg_lsclusters
docker ps --filter name=mongodb         # STATUS shows (healthy)
ruby test/provisioners_test.rb          # repository tests
```

### Verified state on `dev-10` (2026-10-28)

All 14 steps completed. A second full run also completed without changes:
Docker was not restarted and the MongoDB container was not replaced. No reboot
was requested.

- **Network:** UFW is active, denies incoming traffic and allows only
  `22/tcp`. SSH accepts keys only. Only sshd listens on a public address.
  `DOCKER-USER` drops new inbound connections on `eno1` and `eno2`.
- **Tools:** gh 2.94.0, Rust 1.97.1 (default), nightly-2026-07-31 with
  `wasm32-unknown-unknown`, uv 0.11.16, Python 3.12.13 and 3.13.12, Node.js
  v22.23.2, npm 10.9.8, Corepack 0.35.0 and NVM 0.40.6.
- **Docker:** 29.7.1 with Compose v5.3.1; `ubuntu` is in the `docker` group.
- **PostgreSQL:** 18.4 (`18/main` on port 5432, online).
- **MongoDB:** 7.0.39 is healthy at `127.0.0.1:27017`. An authenticated
  replica-set connection from the host reports `rs0`, writable primary,
  hosts `localhost:27017`.

## Updating versions

Change the value in `server.env`. For an archive, update the version, URL
and SHA-256 together, taking the digest from the vendor's checksum file for
the x86_64 asset. To keep the Vagrant box and the server identical, make the
same version change in the `Vagrantfile`, using the ARM64 URL and digest there.

## Recovery

- **Locked out of SSH.** Use the provider's rescue or KVM console. Delete
  `/etc/ssh/sshd_config.d/00-server-key-only.conf` and run
  `systemctl reload ssh`, or run `ufw disable`.
- **Undoing the firewall.** `sudo ufw disable` turns it off;
  `sudo ufw delete allow 22/tcp` removes a single rule.
- **MongoDB data.** It lives in the Docker volume `mongodb-data`.
  Reprovisioning never deletes it.
