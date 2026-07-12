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
  vault_user/               Adds/updates/removes one userpass user + their custom policy - see "Managing individual users"
    files/policies/           Per-user HCL policy files live here - Ansible finds them automatically, just a bare filename
      example.hcl              A starting-point policy - copy it per user, don't apply it unedited
playbooks/
  site.yml                  Full bring-up, in the dependency order that actually matters
  init.yml                  One-time: initializes the Raft cluster, shows unseal keys + root token ONCE
  unseal.yml                Unseals every node (existing + newly-added) with 3 of the keys init.yml showed
  add_node.yml              Add a new node to the existing Raft cluster
  check_cluster.yml         Read-only: every node unsealed, optionally the real Raft peer list
  manage_user.yml           Thin wrapper around roles/vault_user - see "Managing individual users"
  enable_audit.yml          Enables Vault's syslog audit device - see "Enabling audit logging"
  build_offline_repo.yml    Builds offline-repo/'s portable apt repo (vault + haproxy + every dependency) - see "Offline install"
  destroy.yml               Completely removes Vault (and HAProxy) from every node - all data, no undo - see "Destroying the cluster"
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

## Managing individual users

By default the only credential that exists is the root token from
`init.yml` - fine for first bring-up, not something real people should
share day-to-day. `roles/vault_user` (invoked by `playbooks/manage_user.yml`)
adds people as Vault's built-in `userpass` auth method users (so they log
into the same web UI with a username/password), each with their **own
custom policy** you write - there's no fixed set of built-in roles here,
since what any given person should actually be able to touch is entirely
specific to your setup.

1. Write an HCL policy scoped to what that person needs and drop it in
   `roles/vault_user/files/policies/` - copy `example.hcl` there as a
   starting point, don't apply it unedited.
2. Add (or update) the user:

   ```bash
   ansible-playbook -i <inventory> playbooks/manage_user.yml \
     -e vault_root_token=<root or a sufficiently privileged token> \
     -e target_username=alice \
     -e target_password='<a password you chose - not auto-generated>' \
     -e target_policy_name=alice-policy \
     -e target_policy_file=alice.hcl
   ```

   **`target_policy_file` is just a filename**, not a path - Ansible's
   `copy` module automatically resolves a relative `src` against the
   role's own `files/` directory first, so as long as `alice.hcl` lives in
   `roles/vault_user/files/policies/`, this works from anywhere, no path
   to get wrong.

   Safe to re-run: enabling `userpass` is skipped if already enabled,
   re-uploading the same policy name overwrites it with the new file's
   contents, and `vault write` on an existing user just updates their
   password/policies.
3. Give `alice` her username/password directly (out of band - this
   playbook never writes them anywhere) - she logs in at
   `https://<any node or the LB>:8200/ui` with them.
4. Remove a user later (optionally her policy too, if nothing else
   references it):

   ```bash
   ansible-playbook -i <inventory> playbooks/manage_user.yml \
     -e vault_root_token=<token> \
     -e target_username=alice \
     -e target_state=absent \
     -e target_policy_name=alice-policy
   ```

## Enabling audit logging

Turns on Vault's `syslog` audit device - a complete log of every request
Vault handles (who did what, when), written to the syslog of whichever
node is currently the active leader:

```bash
ansible-playbook -i <inventory> playbooks/enable_audit.yml \
  -e vault_root_token=<root or a sufficiently privileged token>
```

Safe to re-run - does nothing if a device is already enabled at that
path. Audit devices are a cluster-wide Vault setting (stored in Raft, not
per-node config), so this only ever needs to run once, against any one
node.

Because leadership can move between nodes over time (failover, a
restart), the actual audit trail ends up split across whichever node(s)
were leader at different points - forward each node's syslog to a central
log collector yourself (rsyslog remote forwarding, a log shipper, etc.)
if you want one aggregated stream; which collector to use is genuinely
environment-specific and left to you.

## Destroying the cluster

Completely removes Vault (and HAProxy, by default) from every node:
service stopped, package purged, **all data deleted** - the entire Raft
storage directory, config, and TLS certs. There is no undo. If this Vault
holds real secrets and you don't have a separate backup, they are gone
permanently once this runs.

Refuses to run without an explicit confirmation extra-var:

```bash
ansible-playbook -i <inventory> playbooks/destroy.yml -e confirm_destroy=yes
# keep HAProxy (e.g. reusing it for something else):
ansible-playbook -i <inventory> playbooks/destroy.yml -e confirm_destroy=yes -e destroy_haproxy=false
```

It also re-enables the host's default Ubuntu apt sources if
`vault_offline_mode` had disabled them, leaving the host closer to how it
looked before any of this ran.

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
- **`vault_user` targets `vault_cluster[0]` and shells out to the real
  `vault` CLI**, the same style as `init.yml`/`unseal.yml`/
  `check_cluster.yml`, rather than adding a new collection dependency
  (e.g. `community.hashi_vault`) or the `uri` module just for this - one
  fewer thing to install/version-pin, and it's already proven to work
  against this cluster's TLS setup (`-ca-cert={{ vault_tls_dir }}/ca.pem`).
- **`vault_user` is a role, unlike `init`/`unseal`/`check_cluster`/`destroy`
  (which stay flat playbooks)** - a deliberate exception to this project's
  usual "roles are only for things reused/composed across multiple
  playbooks" rule. It moved into a role specifically so its policy files
  could live under `roles/vault_user/files/policies/` and be found by
  Ansible's own automatic role-file resolution - solving a real, reported
  point of friction where a relative `target_policy_file` path was silently
  resolved against the *playbook's* directory instead of the caller's
  shell `cwd`. Wrapping it in a role isn't about reuse here; it's what
  gets you a `files/` search path for free.
- **Policies are per-user HCL files copied to the Vault node, not inlined
  into a `vault policy write - <<EOF` shell heredoc** - real policies
  contain quotes/braces that are painful and fragile to get right escaped
  through Ansible's `command` module; copying a file and pointing
  `vault policy write` at it sidesteps that entirely.
- **No fixed admin/readwrite/readonly policy tiers** - deliberately, per
  explicit request: every user gets a fully custom policy written for
  them, since what a specific person should be able to touch is entirely
  usage-specific and a fixed tier model would either be too broad or force
  awkward workarounds for anyone who doesn't fit one of the three boxes.
- **Passwords are operator-chosen via `-e target_password=...`, never
  auto-generated** - per explicit request. Unlike `init.yml`'s unseal
  keys (which Vault itself generates and can never show again), a
  userpass password is something the operator picks and hands to that
  person directly - there's nothing here for this playbook to "show once."
- **`enable_audit.yml` uses a `syslog` device, not a `file` device** - per
  explicit choice: relies on the host's existing syslog/rsyslog rather
  than managing a dedicated log file's path/rotation/permissions itself,
  and composes naturally if you already forward syslog to a central
  collector. A `file` device would be simpler for a single all-in-one
  host but adds file-rotation concerns this project doesn't otherwise
  need to own.
- **`enable_audit.yml` is its own standalone playbook, not folded into
  `site.yml`** - per explicit choice, matching `init.yml`/`unseal.yml`/
  `manage_user.yml`: an operator decision made once (or rarely
  reconfigured), not part of the routine node-provisioning path every
  `site.yml` run repeats.
- **`destroy.yml` refuses to run without `-e confirm_destroy=yes`**, checked
  as a normal per-host task at the top of *each* destructive play, not via
  a separate confirmation-only play. Tried that first - a `hosts:
  localhost` play whose only job is the confirmation check *does* stop a
  normal run when it fails, but `--limit vault_cluster` skips a play with
  no matching hosts entirely ("no hosts matched") rather than treating it
  as a failure, so the destructive play still ran with the gate never
  evaluated at all. Verified directly (a synthetic two-play test,
  reproducing exactly this) before settling on checking it inside every
  play that actually does something, which no `--limit` combination can
  route around.

## Known gaps (not built here, ask if you want them)

- **Auto-unseal via a cloud KMS** - not configured; manual Shamir unseal
  only, per explicit request. Real operational cost: every Vault restart
  (host reboot, systemd restart, a config change) needs a human to run
  `unseal.yml` with 3 of the keys before that node serves traffic again.
- **Central aggregation of audit logs across nodes** - `enable_audit.yml`
  turns on the `syslog` device cluster-wide, but forwarding each node's
  local syslog to one central collector (so the trail doesn't stay split
  across whichever node was leader at any given time) is left to you.
- **Automated snapshots/backups** of the Raft data directory.
- **Secrets engines** (KV mounts, database secrets, PKI, etc.) - this only
  stands up the cluster and, via `manage_user.yml`, userpass
  logins/policies; what those policies actually grant access *to* is
  deliberately left to you, it's entirely usage-specific.
- **Only the `userpass` auth method** is wired up (`manage_user.yml`) -
  no LDAP/OIDC/other auth backends. Fine for a small team with
  operator-issued credentials; revisit if you need SSO or don't want to
  hand out passwords directly.
