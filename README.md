# vault-ha

Ansible playbooks for a production-oriented, HA HashiCorp Vault cluster on
Ubuntu: Integrated Storage (Raft) - no external Consul cluster needed -
TLS everywhere, Vault's own built-in web UI (not a custom one), and an
HAProxy load balancer in front that always routes to the current leader.

## Architecture

- **3-node Raft cluster** (`vault_cluster`) - Vault's own documented
  minimum for real HA (tolerates 1 node down while keeping Raft quorum).
  Each node stores its own encrypted copy of the data via Integrated
  Storage; no separate Consul cluster to run/patch/monitor.
- **UI**: Vault's own built-in web UI (`ui = true` in `vault.hcl`) - per
  explicit request, this does *not* build a separate custom UI project the
  way `kubespray-webui` did for kubespray. Reach it at
  `https://<any node>:8200/ui` directly, or through the load balancer.
- **HAProxy** (`haproxy_lb`) - TCP passthrough (never terminates Vault's
  TLS - see "Why", below), health-checking each node's real
  `/v1/sys/health` response so it only ever routes to the current
  active+unsealed leader, failing over automatically when leadership
  changes.
- **TLS**: a self-signed CA generated once (on the control node, not any
  Vault host) and a per-node cert signed by it - real Vault deployments
  should always use TLS, this isn't optional here. Bring your own CA
  instead by skipping `roles/vault_tls` and dropping files at
  `{{ vault_tls_dir }}/{ca.pem,cert.pem,key.pem}` yourself.
- **Unseal**: Shamir's Secret Sharing (Vault's default) - 5 key shares, 3
  needed to unseal. Manual by design (no cloud KMS auto-unseal) - fits a
  self-hosted environment without assuming an AWS/GCP/Azure KMS is
  available. `playbooks/init.yml` shows the keys + root token exactly
  once; `playbooks/unseal.yml` uses 3 of them to unseal every node, and
  needs re-running after any Vault process restart (seal state lives in
  memory, not on disk).

## Layout

```
inventory/sample/          Copy this, fill in real values
  hosts.ini                 3 vault_cluster hosts + 1 haproxy_lb + empty new_members (INI format)
  inventory.yml             Same hosts/groups, YAML format - use whichever you prefer, not both
  group_vars/all/main.yml   All tunables (version, ports, TLS validity, cluster name...)
roles/
  vault_repo/               Adds HashiCorp's official apt repo + GPG key (or the offline one - see below)
  vault_install/            Installs vault, templates vault.hcl (Raft storage + retry_join + TLS + ui=true), enables (not starts) the service
  vault_tls/                Generates the CA once + a per-node cert/key signed by it
  haproxy_lb/                Installs/configures HAProxy (TCP passthrough + Vault-aware health check)
playbooks/
  site.yml                  Full bring-up, in the dependency order that actually matters
  init.yml                  One-time: initializes the Raft cluster, shows unseal keys + root token ONCE
  unseal.yml                Unseals every node (existing + newly-added) with 3 of the keys init.yml showed
  add_node.yml              Add a new node to the existing Raft cluster
  check_cluster.yml         Read-only: every node unsealed, optionally the real Raft peer list
  build_offline_repo.yml    Builds offline-repo/'s portable apt repo (vault + haproxy + every dependency) - see "Offline install"
offline-repo/               Portable: build once with real internet, copy the whole directory anywhere, docker-compose up -d there
  docker-compose.yml         One nginx service serving the flat apt repo
  nginx-autoindex.conf        Same stock-default.conf-wins fix kubespray-webui's Offline Install hit - see that project's CLAUDE.md gotcha #4
  packages/                  Populated by build_offline_repo.yml - empty until then
```

## Usage

```bash
cp -r inventory/sample inventory/production
# edit hosts.ini (or inventory.yml - delete whichever one you don't use)
# with real ansible_host IPs/users, and group_vars/all/main.yml if any
# defaults need changing (vault_version, vault_apt_codename, etc.)

ansible-galaxy collection install -r requirements.yml
ansible-playbook -i inventory/production/hosts.ini playbooks/site.yml

# Once, ever, on a fresh cluster:
ansible-playbook -i inventory/production/hosts.ini playbooks/init.yml
# ^ copy the unseal keys + root token somewhere safe RIGHT NOW - shown only this once.

ansible-playbook -i inventory/production/hosts.ini playbooks/unseal.yml \
  -e unseal_key_1=<key1> -e unseal_key_2=<key2> -e unseal_key_3=<key3>

ansible-playbook -i inventory/production/hosts.ini playbooks/check_cluster.yml
```

Then open `https://<any node or the HAProxy address>:8200/ui` and log in
with the root token (create real auth methods/policies and stop using the
root token day-to-day, same as any real Vault deployment).

## Scaling the cluster

1. Add the new host to `[new_members]` in your inventory.
2. `ansible-playbook -i <inventory> playbooks/add_node.yml`
3. `ansible-playbook -i <inventory> playbooks/unseal.yml -e unseal_key_1=... -e unseal_key_2=... -e unseal_key_3=...`
4. Once healthy (`playbooks/check_cluster.yml`), move it from
   `[new_members]` into `[vault_cluster]` in your inventory. Be aware: a
   future `site.yml` run against the whole group will then regenerate
   every node's config (their `retry_join` list now includes one more
   peer), which **does restart (and reseal) already-running nodes** -
   expected, not a bug - just unseal them again afterward.

## Offline install

For installing onto hosts with no real internet access - `offline-repo/`
is a self-contained, **portable** apt repo covering vault, haproxy, and
every dependency either one needs (Ubuntu-only, matching what this whole
project targets).

**Build it once, anywhere with real internet access + Docker:**

```bash
ansible-playbook playbooks/build_offline_repo.yml
# or for a different Ubuntu release:
ansible-playbook playbooks/build_offline_repo.yml -e ubuntu_release=22.04
```

This downloads every `.deb` (via a real Ubuntu container, for exact
compatibility with the target release) into `offline-repo/packages/` and
builds a flat apt repo index there.

**Copy the whole `offline-repo/` directory** (docker-compose.yml +
nginx-autoindex.conf + the now-populated `packages/`) to wherever you'll
actually install from - a USB drive, scp, whatever gets it there. Start
it:

```bash
cd offline-repo && docker-compose up -d
```

**Point the Vault playbooks at it** - in your inventory's
`group_vars/all/main.yml`:

```yaml
vault_offline_mode: true
vault_offline_repo_url: "http://<wherever offline-repo is running>:8081"
```

Then run `playbooks/site.yml` as usual - `roles/vault_repo` adds this flat
repo (`deb [trusted=yes] ...`) instead of the real HashiCorp one, and -
specifically for a genuinely air-gapped host - **disables the host's own
default Ubuntu apt sources first** (handles both the Ubuntu 24.04+ deb822
`ubuntu.sources` format and the older `sources.list` format, renaming
rather than deleting, so it's reversible), so `apt-get update` doesn't
hang or fail trying to reach mirrors this host can't actually reach.
`init.yml`/`unseal.yml`/`check_cluster.yml` are unaffected either way -
they only ever talk to Vault's own API, never apt.

## Why these specific design choices

- **Integrated Storage (Raft), not Consul**: fewer moving parts to
  operate - no separate Consul cluster to deploy, secure, and keep
  healthy just so Vault has somewhere to put its data. Vault's own
  recommended default for new deployments since it stabilized.
- **`retry_join` in every node's config, not a manual `vault operator raft
  join` step**: each node's `storage "raft"` stanza lists every *other*
  cluster member as a potential leader to join through - Vault attempts
  this automatically on startup, so growing the cluster (`add_node.yml`)
  is just "start Vault with the right config," not a separate join
  command. This is also why `add_node.yml` doesn't touch existing nodes
  at all - joining is initiated entirely from the new node's side.
- **`vault_install` enables but does not start the service** - its
  `vault.hcl` references TLS cert files that don't exist on disk yet at
  that point (`roles/vault_tls` runs after it, since generating/copying
  those files needs the `vault` system user this role's package install
  creates first). `site.yml`/`add_node.yml` both start the service
  explicitly as their last step, once both roles have actually run.
- **HAProxy runs in TCP mode, passthrough - it never terminates Vault's
  TLS.** Re-terminating TLS at an intermediate hop for a secrets manager
  specifically is the kind of shortcut that's easy to regret - this way
  traffic is genuinely end-to-end encrypted to whichever Vault node
  actually serves it. `option httpchk` + `check-ssl` still let HAProxy
  inspect the real `/v1/sys/health` response *through* that same TLS
  connection to decide routing, without decrypting client traffic itself.
- **HAProxy's health check uses Vault's default `/v1/sys/health` behavior
  (no `standbyok`/`perfstandbyok` query params)** - deliberately, so it
  only ever considers the current active+unsealed leader "up," failing
  over automatically the moment leadership changes, rather than
  load-balancing across standbys that can't serve writes anyway.
- **Unseal keys are never written to disk by this repo** - `init.yml`
  displays them via a single `debug` task and nothing else touches them.
  Copying them somewhere safe afterward is the operator's job, same as
  any real Vault deployment - there's no way to show them again once
  Vault has generated them.
- **`unseal.yml` uses `no_log: true` on every task that handles a real
  key value** - so a key never ends up in Ansible's own verbose/debug
  output, only in the process's actual argument list for that one command
  invocation.
- **The offline repo is built via a real Ubuntu container**, not the
  ansible control node's own package manager - guarantees the downloaded
  `.deb`s are actually compatible with the target release even if you're
  building the bundle from a different OS/distro entirely. Same reasoning
  and technique as kubespray-webui's own offline-install feature.
- **Offline mode disables the host's own default apt sources rather than
  just adding the flat repo alongside them** - a real air-gapped host's
  default Ubuntu mirrors are simply unreachable, and leaving them
  configured means `apt-get update` hangs or fails outright instead of
  quietly using only the offline repo. Renamed, not deleted, so it's
  reversible if you ever reconnect the host to the internet.

## Known gaps (not built here, ask if you want them)

- **Auto-unseal via a cloud KMS** - not configured; manual Shamir unseal
  only, per explicit request. Real operational cost: every Vault restart
  (host reboot, systemd restart, a config change) needs a human to run
  `unseal.yml` with 3 of the keys before that node serves traffic again.
- **Audit logging** - not enabled by default; a real production Vault
  should have at least one audit device turned on.
- **Automated snapshots/backups** of the Raft data directory.
- **Auth methods/secrets engines/policies** - this only stands up the
  cluster itself; configuring what Vault actually manages (KV mounts,
  auth backends, policies) is deliberately left to you, it's entirely
  usage-specific.
