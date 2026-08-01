# Ubuntu 26.04 development VM

This directory contains a Vagrant template for a large, reproducible Ubuntu
26.04 development workstation running on Parallels Desktop for Mac. The main
file is `Vagrantfile`.

The template is intended for an Apple Silicon Mac and a trusted development
environment. It installs a graphical Ubuntu desktop, common build tools,
Docker, Rust, Python, Node.js, PostgreSQL, MongoDB, Nginx, and Certbot.

## What the template creates

| Area | Result |
| --- | --- |
| VM identity | Parallels VM and guest hostname `dev-07` |
| Compute | 8 virtual CPUs and 20,000 MiB (about 19.5 GiB) of memory |
| Storage | A full clone with a 1000G fixed-size (`plain`) virtual disk |
| Host access | Static host-only address `192.168.56.7` |
| Guest internet | Bridged Wi-Fi is preferred; Parallels Shared/NAT is fallback |
| Host files | `vagrant/synced_folder` is mounted at `/home/vagrant/synced_folder` |
| Toolchains | Pinned Rust, Node.js, Corepack, uv, and Python versions |
| Databases | Local PostgreSQL and authenticated, single-node MongoDB |
| Web server | Static Nginx site; optional Let's Encrypt certificates |

## Host requirements

Install or provide all of the following before the first launch:

- An Apple Silicon (`arm64`) Mac.
- Vagrant 2.4.0 or newer.
- Parallels Desktop Pro, Business, or Enterprise with a valid license.
- The pinned `vagrant-parallels` plugin.
- Internet access for the box, Ubuntu packages, vendor repositories, archives,
  and the MongoDB container image.
- At least 8 available CPU cores and about 20 GiB of available memory.
- More than 1000 GiB of free storage. Allow additional space for the downloaded
  box, full clone, package caches, and development data.
- A Wi-Fi interface named `en0`, or the actual interface name supplied through
  `VAGRANT_BRIDGED_INTERFACE`.
- An unused `192.168.56.7` address and no conflicting route for
  `192.168.56.0/24`.

### Important storage warning

`PARALLELS_RESOURCES_HDD_SIZE` is `1000G`, and the provider requests a Parallels
`plain` disk. A plain disk is fixed-size rather than sparse, so the host must be
able to allocate the complete capacity. The template cannot shrink an existing
disk. Set the intended size before the first launch and do not reduce it later.

### Check the host

These commands are read-only:

```sh
uname -m
vagrant --version
vagrant plugin list
prlctl --version
prlsrvctl info
df -h .
networksetup -listallhardwareports
ping -c 1 192.168.56.7
```

The ping should receive no response before this guest is started. A response
usually means another guest or device already owns the configured address. No
response is not proof that the address is free because a device may block ICMP.

## Host environment variables

These variables are read on the Mac while Vagrant evaluates the template:

| Variable | Required | Meaning |
| --- | --- | --- |
| `VAGRANT_VAGRANTFILE` | For every command | Selects `Vagrantfile` instead of a file literally named `Vagrantfile` |
| `MONGODB_PASSWORD` | Commands that can run the MongoDB provisioner | Supplies the MongoDB administrative password; keep the original value for an existing database |
| `VAGRANT_BRIDGED_INTERFACE` | Only when Wi-Fi is not `en0` | Selects the Mac interface used by Adapter 3 |

The Vagrantfile passes selected values to guest provisioners as environment
variables. Do not set guest script variables manually during normal use; edit
the `Config` section and let Vagrant provide a validated, consistent set.

## First launch

Run all Vagrant commands from this `vagrant` directory. Because the template
does not use the default filename `Vagrantfile`, select it through an environment
variable for the current shell:

```sh
cd /path/to/repository/vagrant
export VAGRANT_VAGRANTFILE=Vagrantfile
```

Install the exact provider plugin expected by the template:

```sh
vagrant plugin install vagrant-parallels --plugin-version 2.4.9
```

Vagrant can download the box during `vagrant up`. To download it explicitly:

```sh
vagrant box add bento/ubuntu-26.04 \
  --provider parallels \
  --architecture arm64 \
  --box-version 202606.01.0
```

MongoDB provisioning requires a non-empty password. On the default macOS zsh,
the following reads it without placing the value in shell history or displaying
it on screen:

```sh
read -s "MONGODB_PASSWORD?MongoDB password: "
export MONGODB_PASSWORD
printf '\n'
```

Keep this password in a password manager. Use the same value whenever this VM
is validated or reprovisioned. Vagrant marks it as sensitive to reduce log
exposure, but it is still a process environment variable and should not be
treated as a production secret-management mechanism.

Run the fast syntax/policy tests, validate the configuration, and launch the VM:

```sh
ruby test/provisioners_test.rb
vagrant validate
vagrant up --provider=parallels
```

The first run can take a long time. It creates a full clone, allocates the fixed
disk, installs a desktop and development toolchains, downloads container data,
and may reboot once if Ubuntu reports that a reboot is required.

## Testing

The fast host-side suite parses every Bash script, checks the Vagrantfile and
script inventory, exercises command-line secret-selection policy as Ruby code,
and asserts safety invariants for routing, rollback, service restarts, version
gates, and transactional resources. It does not require a running VM:

```sh
ruby test/provisioners_test.rb
```

After a full provisioning run, execute the opt-in read-only integration suite
inside the guest:

```sh
vagrant provision --provision-with integration-test
```

The integration provisioner is configured with `run: "never"`, so normal
`vagrant up`, `reload`, and `provision` commands cannot run it accidentally. It
does not require the host `MONGODB_PASSWORD`; MongoDB authentication is verified
through the already installed root-only guest secret. It checks live network
roles and IPv4/IPv6 metrics, UFW and Docker ingress chains, automatic-update
timers, LVM state, exact PostgreSQL and MongoDB behavior, and local Nginx
HTTP/TLS responses. It changes no guest configuration or application data.

Like every successful provisioning action, an integration-test run is followed
by the conditional reboot check. If Ubuntu already has
`/run/reboot-required`, Vagrant reboots the guest after the checks pass.

## Normal VM lifecycle

Keep `VAGRANT_VAGRANTFILE` set in the shell for every command. Keep
`MONGODB_PASSWORD` set for a full provisioning run or one that selects
`mongodb` or the generic `shell` provisioner type.

```sh
# Show the Vagrant state.
vagrant status

# Open a shell through Vagrant's management connection.
vagrant ssh

# Re-run all enabled provisioners.
vagrant provision

# Re-run one named provisioner.
vagrant provision --provision-with mongodb

# This targeted run does not require MONGODB_PASSWORD.
vagrant provision --provision-with nginx

# Restart and provision, including a conditional Ubuntu reboot if required.
vagrant reload --provision

# Stop or suspend the guest without deleting it.
vagrant halt
vagrant suspend
vagrant resume
```

`vagrant validate`, `vagrant up --no-provision`, `vagrant halt`, `vagrant
status`, and `vagrant destroy` do not need the MongoDB password. A normal
`vagrant up`, an unfiltered `vagrant provision`, and `vagrant reload --provision`
do. With `--provision-with`, the password is required only for `mongodb` or
`shell`; targeting `nginx`, `postgresql`, or another independent provisioner
does not require it.

The conditional reboot is an action hook around Vagrant's provisioning phase,
not a selectable provisioner. It checks `/run/reboot-required` after every
successful full or targeted provisioning run, including
`--provision-with nginx`, and asks Vagrant to perform one provider-aware reboot
when needed. It never runs for `--no-provision`.

### Destroying the VM

```sh
vagrant destroy
```

This deletes the VM and everything stored only inside it, including the Docker
volume that contains MongoDB data, PostgreSQL data, installed toolchains, and
guest-side secrets. It does not delete the host's `synced_folder`. Back up any
required guest data before destroying the VM.

## Connecting from the host

### SSH and VS Code Remote SSH

`vagrant ssh` uses Adapter 1, the Parallels Shared/NAT management network. For a
stable VS Code destination, use Adapter 2 at `192.168.56.7`.

First obtain the exact user and generated private-key path:

```sh
vagrant ssh-config dev-07
```

Copy the resulting stanza into the host's SSH configuration, give it a useful
host alias, and change only `HostName` to the host-only address. Preserve the
`IdentityFile` printed by Vagrant. A typical result looks like this:

```sshconfig
Host dev-07
  HostName 192.168.56.7
  User vagrant
  Port 22
  IdentityFile /absolute/path/vagrant/.vagrant/machines/dev-07/parallels/private_key
  IdentitiesOnly yes
```

Select `dev-07` in VS Code's **Remote-SSH: Connect to Host** command.

The GitHub identity configured inside the guest is a separate key path:
`~/.ssh/my-ssh-key`. The provisioner adds that path to the guest SSH config but
does not create or copy the private key. Put the intended key in the guest and
set mode `0600` before using GitHub over SSH.

### Shared files

The host directory `vagrant/synced_folder` is created automatically and mounted
inside the guest at:

```text
/home/vagrant/synced_folder
```

The mount depends on Parallels Tools. A Tools update can cause an additional
restart or temporarily make the mount unavailable.

## Network and firewall model

The three adapters have different responsibilities. Keeping management and
development traffic separate makes the guest usable while its preferred egress
route or VPN changes.

| Adapter | Parallels mode | Addressing | Purpose | Default route |
| --- | --- | --- | --- | --- |
| 1 | Shared/NAT | DHCPv4, DHCPv6, and IPv6 RA | Vagrant SSH and fallback internet access | IPv4/IPv6 metric 600 |
| 2 | Host-only | Static IPv4; IPv6 disabled | Stable host access at `192.168.56.7` | None |
| 3 | Bridged Wi-Fi | DHCPv4, DHCPv6, and IPv6 RA | Normal application internet access | IPv4/IPv6 metric 100 |

The lower metric makes Bridged Wi-Fi the preferred IPv4 and IPv6 default route.
Shared/NAT remains available as a fallback and as Vagrant's management path.
The host-only adapter deliberately has no default route and disables IPv6 so it
cannot acquire an unintended router-advertisement route. A network may provide
IPv4 only; DHCPv6 is optional, and any IPv6 route that is learned from DHCPv6 or
router advertisements receives the same metric as its IPv4 counterpart.

`systemd-networkd` is the sole owner of the three physical adapters. The
provisioner tells NetworkManager to leave those MAC addresses unmanaged, which
prevents the desktop installation from creating duplicate DHCP leases and
routes. NetworkManager remains installed and running for VPN/tunnel devices and
its desktop controls. A VPN client that requires NetworkManager itself to own
the underlying Ethernet connection is not compatible with this split; use the
client's standalone service/CLI or adapt the network backend deliberately.

Most VPN clients install a still-lower-priority default route, policy-routing
rules, or both. That lets the VPN carry normal guest traffic while Vagrant's
existing management connection remains on Shared/NAT and host SSH remains on
the directly connected host-only subnet. A VPN client that deliberately removes
local routes or applies its own firewall can still interrupt those connections;
that behavior is controlled by the VPN client rather than this template.

The network provisioner identifies adapters by their observed IP address, the
active Vagrant SSH connection, and MAC address. It replaces guest Netplan YAML
with one managed file plus narrowly scoped backend ownership/IPv6-metric files.
Before each attempt, it takes a new root-only snapshot of the exact current
Netplan YAML, backend files, UFW files, and UFW active state, then schedules a
90-second rollback. The timer remains armed until route and firewall checks pass.
If provisioning fails or SSH is lost, the helper restores the immediately
preceding state. Successful transactions and snapshots are removed rather than
being reused on later runs.

Only UFW rules carrying a `Vagrant managed:` comment are reconciled. Untagged
rules remain administrator-owned even when they are broader than the template's
policy; provisioning reports the effective rules but does not delete them.

The UFW firewall denies incoming traffic by default:

| Source/interface | Allowed TCP traffic |
| --- | --- |
| Shared/NAT | SSH (`22`) only |
| Host-only `192.168.56.0/24` | The configured development ports listed below |
| Bridged Wi-Fi | Nothing, unless Nginx bridged ingress is enabled |

Host-only TCP ports are grouped by intended use:

| Ports | Intended use |
| --- | --- |
| `22` | SSH and VS Code Remote SSH |
| `80`, `443` | Nginx HTTP and HTTPS |
| `27017` | MongoDB |
| `3000`, `9944` | Application development endpoints; this template does not start them |
| `15100-15105`, `15200-15205`, `15300-15305`, `15400-15405`, `18890-18894` | Reserved project development endpoints; this template does not start them |

Docker's default published-port address is also `192.168.56.7`. A separate
`DOCKER-USER` firewall chain enforces the same boundary independently of UFW:
new container ingress from Shared/NAT and Bridged Wi-Fi is dropped, while
Host-only ingress is accepted only from `192.168.56.0/24`. Consequently, an
explicit mapping such as `--publish 0.0.0.0:8080:8080` does not expose that port
on Shared or Bridged. Container-to-container traffic and traffic arriving over
other interfaces, including a VPN tunnel, are left to Docker or that interface's
own policy. The policy is reapplied whenever Docker starts.

### Guest VPN behavior

A guest VPN normally replaces the preferred default route. VPN clients with a
kill switch can also block host-only or Shared/NAT traffic. Enable the client's
**allow LAN/local network** option, or exclude both `192.168.56.0/24` and the
current Parallels Shared subnet, if Vagrant SSH or VS Code disconnects while the
VPN is active.

The exact Shared subnet is assigned by Parallels and is intentionally not fixed
in this template.

## Services

### MongoDB

MongoDB runs in a Docker container as a single-member replica set. It is bound
only to `192.168.56.7:27017`, uses a persistent Docker volume, and requires the
configured `vagrant` administrative user.

Use a URL-encoded password in client connection strings:

```text
mongodb://vagrant:PASSWORD@192.168.56.7:27017/admin?authSource=admin&replicaSet=rs0&directConnection=true
```

The container image is pinned by both tag and digest. This template deliberately
uses the maintained MongoDB 7.0 series: MongoDB documents an incompatibility
between MongoDB 8.x and Linux kernels 6.19 through 7.0.13, and this Ubuntu box
currently reports Linux 7.0.0. Pinning or downgrading the guest kernel would
conflict with the security-update policy. Revisit the image only after the box
ships a compatible kernel and follow MongoDB's release-series upgrade procedure.

Provisioning creates a keyfile, stores the supplied password in a root-owned
guest file readable only by the image's MongoDB group, initializes the replica
set and user, and waits for the container health check. A managed container is
recreated when its declarative configuration changes; its named data volume is
retained. The container, volume, and secret directory carry or require explicit
template-ownership markers. A same-named unowned resource is rejected rather
than adopted.

When a managed container must be replaced, the old definition is stopped and
renamed but kept until the candidate passes authenticated topology, Docker
health, port-binding, restart-policy, volume, and ownership checks. Failure
removes the candidate and restores the preceding container definition. The data
volume is never deleted.

Changing `VM_NAME`, `MONGODB_REPLICA_MEMBER`, or the MongoDB port can change the
persisted address of this single replica-set member. Provisioning authenticates,
verifies there is exactly one member, records the old address, and performs a
forced one-member `rs.reconfig`. If a later check fails, it attempts to reverse
that change before restoring the old container. Changing the replica-set name,
converting to multiple members, or migrating to a different volume remains a
manual backup/restore operation.

Password rotation is deliberately not automatic. If `MONGODB_PASSWORD` differs
from the stored value, provisioning stops before changing the container. Rotate
the database credential and the root-readable guest secret as one controlled
operation, or rebuild the disposable development database. Simply changing the
host environment variable is not a rotation procedure.

This MongoDB setup is for development only: it has one replica-set member, one
high-privilege application credential, no TLS on the host-only link, no backup
policy, and no high availability.

### PostgreSQL

PostgreSQL is installed from the signed PGDG repository at an exact configured
package version. The package's normal Ubuntu defaults are retained: the service
is local to the guest, and no application database, role, password, remote
listener, or host firewall rule is created.

Provisioning refuses to cross a PostgreSQL major version while a cluster from a
different major is registered. Major upgrades require `pg_upgrade` or
dump/restore; downgrades require a dump from the newer server and restore into a
new older cluster. Same-major package downgrades are also blocked unless
`POSTGRESQL_ALLOW_PACKAGE_DOWNGRADE` is temporarily set to `true` after a backup
and compatibility review. Return it to `false` after the requested run.

To open the administrative shell:

```sh
vagrant ssh -c 'sudo -u postgres psql'
```

Create application-specific roles and databases separately.

### Nginx and Certbot

With the default configuration, Nginx serves `/var/www/html` over HTTP and is
reachable from the host-only address. It is not a reverse proxy and is not
available through Bridged Wi-Fi. The provisioner owns
`/var/www/html/index.html` and replaces it with a small status page on every
run. Put additional static assets beside it, or change the managed site and
index logic together if an application needs to own that path.

To expose it through the bridged adapter and request certificates, edit the
`Config` section before provisioning:

```ruby
NGINX_BRIDGED_INGRESS = true
NGINX_SERVER_NAMES = ["app.example.com"].freeze
CERTBOT_EMAIL = "operator@example.com"
```

The names must already resolve to the bridged guest and be reachable by Let's
Encrypt on ports 80 and 443. On a typical home network, public access also
requires router and upstream firewall configuration. Certbot runs
noninteractively, its systemd timer renews certificates, and a deploy hook tests
and reloads Nginx after renewal.

Site changes, the status page, and the managed certificate lineage are applied
as one local transaction. The provisioner snapshots the previous site, index,
enabled links, certificate archive/live/renewal paths, and relevant service
state. It commits only after `nginx -t`, service checks, an HTTP probe, and—when
TLS is enabled—an HTTPS handshake using the requested certificate name. A
failure restores the snapshot. This protects the template-owned site and
certificate, but it is not a replacement for an off-guest certificate and
configuration backup.

Setting `NGINX_BRIDGED_INGRESS` to `true` with no domain names adds bridged
firewall allowances for ports 80 and 443 but does not request a certificate or
create an Nginx TLS listener.

### Docker

Docker Engine, containerd, Buildx, and Compose are installed from Docker's
signed repository at exact versions. The `vagrant` user is added to the
`docker` group. Open a new login shell after provisioning before expecting
passwordless Docker access.

The Docker daemon uses the `local` log driver with non-blocking buffering and
defaults published ports to the host-only address. A systemd-managed
`DOCKER-USER` policy also blocks published-port ingress on the Shared and
Bridged adapters, even if a compose file explicitly binds to all host addresses.
Reprovisioning restarts the Docker daemon only after a package-version or daemon
configuration change; unchanged running containers are not interrupted.

### Development toolchains

- Git identity, editor, pruning behavior, and the GitHub SSH key path are set
  for the `vagrant` user.
- Rust is installed for `vagrant` through rustup with exact stable and dated
  nightly toolchains. The nightly WebAssembly target is also installed.
- `uv` is installed system-wide from a verified ARM64 archive. Exact managed
  Python interpreters are installed under the `vagrant` user's home directory.
- `PIP_REQUIRE_VIRTUALENV=1` is added to `.bashrc`, so interactive Bash refuses
  global `pip` installs outside a virtual environment.
- NVM, an exact ARM64 Node.js archive, and Corepack are installed for the
  `vagrant` user. NVM initialization is added to `.bashrc`.

Shell startup changes target Bash because Ubuntu's default `vagrant` shell is
Bash. A different login shell will need equivalent PATH and initialization
configuration.

## Configuration reference

Edit values only in the `Config` section near the beginning of
`Vagrantfile`.

| Setting group | What it controls |
| --- | --- |
| `VM_NAME`, `PROVIDER_VM_NAME` | Stable Vagrant, Parallels, hostname, and MongoDB identity |
| `DEFAULT_USER`, `GIT_*`, `GITHUB_*` | Guest user-level development preferences |
| `PRIVATE_NETWORK_*`, route metrics, port list | Static host access, route priority, and firewall policy |
| `PROVISION_*` | Whether each optional feature is provisioned |
| `NGINX_*`, `CERTBOT_*` | Static site names, bridged exposure, and certificates |
| `*_VERSION`, `*_URL`, `*_SHA256` | Reproducible external software inputs |
| `MONGODB_*` | Container identity, replica set, bind address, secret paths, and health timing |
| `PARALLELS_RESOURCES_*`, `RESOURCES_*` | Disk, CPU, and memory allocation |

Configuration is validated before guest mutation. Validation checks types,
addresses, ports, feature dependencies, exact version formats, checksums,
required scripts, and MongoDB settings. Validation cannot prove that remote
artifacts still exist or that their contents match until provisioning downloads
them.

Make architecture, disk, and persistent-service decisions before the first
launch. Changing them after data exists may require manual migration or a new
VM. The template supports a controlled address change for its one-member
MongoDB replica set, but not a replica-set-name, topology, or data-volume change.

Feature flags control future provisioning; turning a flag off does not uninstall
software that was installed by an earlier run.

## Provisioning order and privileges

Provisioners execute in this order:

| Provisioner | Runs as | Responsibility |
| --- | --- | --- |
| `os-package-security-baseline` | root | Install the combined Ubuntu package set, apply security updates, and always restore automatic-update services |
| `network-security` | root, every provisioning-enabled up/reload | Reconcile Netplan routes and UFW rules |
| `enlarge-hdd` | root, every provisioning-enabled up/reload | Reconcile partition, LVM, and filesystem growth while preserving existing free VG extents |
| `ubuntu-desktop` | root | Enable the graphical login and graphical boot target |
| `general-dev-user` | `vagrant` | Configure Git and the GitHub SSH identity path |
| `docker` | root | Install and configure Docker and grant user access |
| `rust-for-substrate` | `vagrant` | Install pinned Rust toolchains and WebAssembly target |
| `python-uv` | root | Install verified `uv` and `uvx` executables |
| `python` / `python-user` | `vagrant` | Install managed interpreters and enforce virtual environments |
| `nodejs` | `vagrant` | Install NVM, Node.js, and Corepack |
| `postgresql` | root | Gate unsafe version transitions, configure PGDG, install PostgreSQL, and verify the default cluster |
| `mongodb` | root | Reconcile the authenticated MongoDB container and volume |
| `nginx` | root | Reconcile the static site, Certbot, and service state |
| `integration-test` | root, only when explicitly selected | Run read-only checks against the fully provisioned guest |

After the listed provisioners finish, a host-side Vagrant action hook checks
`/run/reboot-required` and performs at most one provider-aware reboot. Because it
wraps the provisioning action itself, it is not filtered out by
`--provision-with`.

The scripts use `set -Eeuo pipefail`, validate required environment inputs, and
are written to tolerate repeated provisioning. They avoid interactive package
prompts. A failed command stops the relevant provisioner.

For readers unfamiliar with Bash strict mode: `-e` stops after an unhandled
failure, `-u` rejects unset variables, `pipefail` detects a failed command inside
a pipeline, and `-E` preserves error traps inside functions and subshells. The
cleanup and rollback `trap` statements run registered safety code when a script
exits or fails.

The network provisioner runs on every `vagrant up` or `vagrant reload` unless
provisioning is explicitly disabled, so manual Netplan and managed UFW changes
are intentionally overwritten. Most other provisioners run on the first
`vagrant up` and when explicitly requested.

## Reproducibility policy

The template uses several levels of pinning:

- The Vagrant provider plugin and base box use exact versions.
- Vendor archives use versioned HTTPS URLs and expected SHA-256 digests.
- Docker and PostgreSQL repositories use verified signing keys and exact package
  versions.
- The MongoDB image uses a readable tag plus an immutable manifest digest.
- Ubuntu archive packages intentionally follow signed Ubuntu security updates
  rather than a frozen snapshot.

When updating an archive, update its version, URL, and SHA-256 together. When
updating an apt package, confirm the exact version exists for Ubuntu 26.04 ARM64.
Remote repositories can remove pinned versions, so this is reproducible but not
an offline or permanently available build. No local artifact mirror is provided.

## Design decisions and limitations

- **Parallels and ARM64 only.** Provider and architecture checks reject other
  hypervisors and x86 boxes.
- **Full clone.** The VM owns its disk independently, which makes resizing safe
  but consumes more time and storage than a linked clone.
- **Fixed 1000G disk.** It favors predictable capacity and performance at a very
  high host storage cost. Only growth is supported.
- **LVM root required.** Disk growth expects an ext4 or XFS root filesystem on
  one LVM physical volume. A different box layout fails safely instead of
  guessing. Only extents added by a virtual-disk expansion are assigned to the
  root LV; existing unallocated VG space is preserved. An interrupted operation
  resumes from root-only state in `/var/lib/vagrant/storage/root-vg-growth`.
- **Exactly three guest NICs required.** Additional physical virtual NICs make
  adapter identification ambiguous and stop network provisioning.
- **Provider Netplan is replaced.** Manual guest Netplan edits are not durable;
  change the template instead.
- **Bridged address uses DHCP.** The host-only address is stable, but the LAN
  address may change as Wi-Fi networks or DHCP leases change.
- **VPN behavior is client-specific.** Route metrics cannot override every VPN
  kill switch or packet filter.
- **Development firewall policy.** The host-only port list is intentionally
  broad for development. It should be reduced for a less trusted host.
- **MongoDB is not production-ready.** It has no TLS, backup, high availability,
  or least-privilege application role. The 7.0 image is also a deliberate kernel
  compatibility choice; a future release-series change requires MongoDB's
  documented upgrade procedure, not just editing the image tag.
- **PostgreSQL is only installed.** Application roles, databases, backups, TLS,
  and remote access are outside this template.
- **Nginx serves static files only.** Application reverse-proxy rules must be
  added deliberately.
- **No automated uninstall.** Disabling a feature flag does not remove its
  packages, files, users, containers, or data.
- **Integration tests are opt-in.** The fast suite does not boot a VM or contact
  repositories. The live suite exercises the current guest only when explicitly
  selected; it does not create a second clean VM or test public ACME reachability.
- **Destructive rebuilds lose guest data.** Only files in the host synced folder
  survive `vagrant destroy` automatically.

## Troubleshooting

### Vagrant cannot load the Parallels provider

Check the installed version and reinstall the pinned plugin if necessary:

```sh
vagrant plugin list
vagrant plugin install vagrant-parallels --plugin-version 2.4.9
```

### The bridged adapter cannot attach

Find the active Wi-Fi device and override the default:

```sh
networksetup -listallhardwareports
export VAGRANT_BRIDGED_INTERFACE=en1
vagrant reload
```

Use the device associated with Wi-Fi; `en1` is only an example.

### SSH or VS Code stops working when VPN connects

Enable LAN access in the VPN client or exclude `192.168.56.0/24` and the
Parallels Shared subnet. If necessary, use `vagrant ssh` through Shared/NAT to
inspect routes and firewall state:

```sh
ip -brief address
ip -4 route
sudo ufw status verbose
```

### Network provisioning rolls back

The script requires exactly three physical guest NICs and must identify the
private NIC, the Vagrant SSH NIC, and one remaining bridged NIC. Inspect:

```sh
ip -brief link
ip -brief address
ip -4 route
sudo journalctl -u 'vagrant-network-rollback-*'
```

Do not edit `/etc/netplan/99-vagrant-network.yaml` as a permanent fix; update the
template inputs and reprovision.

### Disk growth fails

The selected box must use one LVM physical volume for its root volume group.
Inspect the guest layout:

```sh
findmnt /
lsblk
sudo pvs
sudo vgs
sudo lvs
```

Also confirm the host had enough free space for the fixed-size disk before VM
creation.

### MongoDB provisioning reports a password mismatch

Supply the same password used when the database was initialized. Do not delete
the guest secret file to bypass the check: the data volume still contains the
old database credential. Perform an explicit rotation or rebuild disposable
MongoDB data.

For other MongoDB failures:

```sh
vagrant ssh -c 'sudo docker inspect mongodb'
vagrant ssh -c 'sudo docker logs --tail 200 mongodb'
```

The provisioner also prints container state and recent logs when it fails.

### A pinned download or package is unavailable

Confirm that the configured version still exists for Ubuntu 26.04 ARM64. Update
the associated version and checksum as one reviewed change. Do not remove digest
or signature verification merely to make provisioning continue.

## File map

```text
vagrant/
├── Vagrantfile          VM definition, validation, and orchestration
├── README.md                         This operator and design guide
├── lib/ubuntu_26_04_command_policy.rb Testable host command/secret policy
├── provision/ubuntu-26.04/*.sh       One executable script per provisioning task
├── synced_folder/                    Host files shared with the guest; auto-created
├── test/provisioners_test.rb         Fast syntax, policy, and invariant tests
└── test/guest_integration.sh          Opt-in read-only live guest checks
```

Useful upstream references:

- [Vagrant documentation](https://developer.hashicorp.com/vagrant/docs)
- [Vagrant Parallels provider](https://parallels.github.io/vagrant-parallels/docs/)
- [Parallels provider configuration](https://parallels.github.io/vagrant-parallels/docs/configuration.html)
