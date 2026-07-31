# PLAN — Security fixes #1 and #2

Scope: the two highest-severity findings from the audit. Findings #3 (lock file),
#4 (unverified downloads) and #5 (entitlement typo) are deliberately out of scope
here, as are the not-yet-audited LUKS key-file and vsock/IPC paths.

---

## Fix #1 — Remove shell interpolation of guest-controlled paths

**Problem.** `anylinuxfs/src/fsutil.rs` builds shell command strings from data that
originates on the mounted disk, then runs them through `sh -c` as root. Values are
wrapped in double quotes only, which stops nothing: `"` is not escaped, and
`$(…)`/backticks expand inside double quotes.

Attacker-controlled inputs reaching these sinks:

- `nfs_path` — ZFS dataset `mountpoint` properties read from the pool
  (`vmproxy/src/main.rs:1050`), emitted as `<anylinuxfs-nfs-export:{path}>`
  (`vmproxy/src/main.rs:1078`) and parsed back verbatim on the host
  (`anylinuxfs/src/cmd_mount.rs:807-810`).
- `rel_path` — derived from the filesystem label; `path_safe_label_name`
  (`common-utils/src/lib.rs:21-29`) only substitutes `/`, space and `:`.

`elevate == false` does not mean unprivileged — it means the process is *already*
root (`anylinuxfs/src/cmd_mount.rs:1141`), so both branches execute as root.

### Step 1.1 — `parallel_mount_recursive` → argv

`anylinuxfs/src/fsutil.rs:313-357`. Replace the `sh -c` string with a direct argv
invocation:

```rust
let source = [vm_host, b":", nfs_path.as_bytes()].concat();
let target = mnt_point_base.join(rel_path);

let mut cmd = if elevate {
    let mut c = Command::new("sudo");
    c.args([OsStr::new("-S"), OsStr::new("mount")]);
    c
} else {
    Command::new("mount")
};
cmd.args([OsStr::new("-t"), OsStr::new("nfs"), OsStr::new("-o")])
    .arg(OsStr::from_bytes(nfs_opts.as_bytes()))
    .arg(OsStr::from_bytes(&source))
    .arg(&target);

let status = cmd.status()?;
```

`sudo -S` is preserved so interactive password behaviour is unchanged.
`fsutil.rs:225` already uses this argv style for `umount`, so this matches
existing convention.

→ **verify:** mounting a ZFS pool whose dataset mountpoint contains `"`, `$(...)`,
`;` and a space succeeds and mounts at the literal path; no subshell runs.

### Step 1.2 — `parallel_unmount_recursive` → argv

`anylinuxfs/src/fsutil.rs:394-403`. Same treatment for
`diskutil unmount "{}"` / `umount "{}"`:

```rust
#[cfg(target_os = "macos")]
let (prog, pre): (&str, &[&str]) = ("diskutil", &["unmount"]);
#[cfg(target_os = "linux")]
let (prog, pre): (&str, &[&str]) = ("umount", &[]);

let _ = Command::new(prog)
    .args(pre)
    .arg(OsStr::from_bytes(&mount_path[..]))
    .status()?;
```

(`mount_path` is the `BString` half of `dirtrie::Node::paths`; exact accessor to be
settled at implementation time.)

→ **verify:** unmounting the volume from step 1.1 tears down every subdir mount and
leaves nothing in `mount | grep nfs`.

### Step 1.3 — Validate export paths at the trust boundary (defence in depth)

`anylinuxfs/src/cmd_mount.rs:807-810`. Before inserting into `exports`, reject any
path that is not absolute, or that contains NUL, newline, or other control
characters. Newlines matter independently of shell quoting: the marker protocol is
line-based, and the guest writes these paths into a line-based `/etc/exports`
(see step 2.4). Log and skip rather than abort, so one hostile dataset doesn't fail
the whole mount.

→ **verify:** unit test feeding crafted marker lines asserts they're rejected and
that a normal `/mnt/tank/data` passes.

### Step 1.4 — Tighten `path_safe_label_name`

`common-utils/src/lib.rs:21-29`. Switch from a three-character denylist to an
allowlist (alphanumerics, `-`, `_`, `.`), substituting everything else. Keep the
existing leading-`-` strip.

→ **verify:** existing tests still pass; new cases cover a label of
`x";touch /tmp/pwned;"` collapsing to something inert.

---

## Fix #2 — Scope NFS exports to the actual client

**Problem.** `vmproxy/src/main.rs:1078-1086` exports to a wildcard peer:

```rust
// Linux
exports_content += &format!("\"{}\"      *({})\n", export_path, export_args);
// FreeBSD / macOS
exports_content += &format!("{} {},network 0.0.0.0/0\n", export_path, export_args);
```

Combined with the defaults from `export_args_for_path`
(`vmproxy/src/main.rs:533-547`) — `no_subtree_check,no_root_squash,insecure` on
Linux, `-maproot=root` on BSD — any peer that can reach the server gets
root-equivalent read/write to the disk with no authentication.

- Default (loopback) config: `insecure` accepts source ports >1024, so **any local
  unprivileged process** can speak NFS directly to the forwarded port and assert
  uid 0.
- With `--bind-addr <LAN ip>`: the same, for anyone on the network.

**Non-goal:** removing `no_root_squash` / `-maproot=root`. Preserving on-disk
ownership is the point of the tool; squashing root would break the primary use
case. The fix is to restrict *who may connect*, not what a legitimate client may do.

### Step 2.1 — Replace the wildcard peer

Emit a specific peer instead of `*` / `0.0.0.0/0`. The host as seen from the guest
is `VM_GATEWAY_IP` (`common-utils/src/lib.rs:16` = `192.168.127.1`) under gvproxy.
Linux becomes `"{path}" {peer}({args})`; the BSD branch becomes
`-network {peer} -mask 255.255.255.255`.

→ **verify:** `showmount -e` from the host lists the restricted peer, and a normal
mount still succeeds under both net helpers.

### Step 2.2 — Plumb the allowed peer from the host

Mirror the existing `nfs_export_opts` channel (`anylinuxfs/src/cli.rs:141` →
`settings.rs:848` → `vm.rs:523`) with an allowed-peer parameter. Default it to the
host's address on the VM network; widen it only when `bind_addr` is non-loopback,
in which case pass the operator-specified CIDR (not a bare wildcard). Under
vmnet-helper the host address differs from the gvproxy gateway, so derive it from
the active net helper rather than hardcoding.

→ **verify:** the generated `/etc/exports` (or `/tmp/exports`) contains the expected
peer for gvproxy, vmnet-helper, and `--bind-addr` cases.

### Step 2.3 — Re-evaluate `insecure`

Dropping `insecure` forces clients onto reserved source ports, which on macOS
requires root and closes the local-unprivileged-process path outright.

**Caveat to test first:** `insecure` may be present precisely because gvproxy's
user-mode forwarding rewrites the source port to a non-reserved one. If so, it must
stay for gvproxy and can be dropped for vmnet-helper (real L2, client keeps its
reserved port). Determine this empirically before changing the default — step 2.1
is the load-bearing fix either way.

→ **verify:** mount succeeds without `insecure` under vmnet-helper; document the
result for gvproxy and keep the option only where required.

### Step 2.4 — Quote-safety and operator warning

Apply the step 1.3 validation guest-side too, so an export path containing `"` or a
newline cannot inject additional lines into the exports file. Separately, emit a
clear warning when `--bind-addr` resolves to a non-loopback address, stating that
the share is unauthenticated and root-capable.

→ **verify:** crafted dataset mountpoint produces a rejected-and-logged export
rather than a malformed exports file; `--bind-addr` on a LAN IP prints the warning.

---

## Verification pass

1. `./run-rust-tests.sh` — no regressions.
2. Manual: ext4 + NTFS mount/unmount round-trip, both net helpers.
3. Manual: ZFS pool with a hostile dataset mountpoint — mounts safely, no injection.
4. Manual: confirm an unprivileged local NFS client can no longer reach the export
   (subject to the step 2.3 outcome).

## Status

- Fix #1 (1.1–1.4): **done**, verified by `cargo check -F freebsd` and the full
  unit suite.
- Fix #2 steps 2.1, 2.2, 2.4: **done**. Implemented entirely guest-side — vmproxy
  already receives the vmnet CIDR (`-n/--native-network`) and the bind addresses,
  so the peer is derived there and no new host→guest plumbing was needed. Both
  the Linux and BSD/macOS export-line branches were type-checked.
- Fix #2 step 2.3 (`insecure`): **open**, blocked on a probe that needs an
  interactive sudo password. See below.

### Step 2.3 resolved (2026-07-31)

Probe run on the pre-change binary: mounting with
`--nfs-export-opts 'rw,no_subtree_check,no_root_squash'` (the default minus
`insecure`) fails with `mount_nfs: ... Operation not permitted`. That is nfsd
rejecting a non-reserved source port, which confirms the hypothesis below:
gvproxy re-dials forwarded connections from its own netstack with an ephemeral
port.

Consequences, now implemented:

- `insecure` is kept under gvproxy (it is required) and dropped under vmnet,
  keyed off `native_network` being present. Same for the `ignore_permissions`
  squash options, which hardcoded `insecure` too.
- Under gvproxy, peer restriction **cannot** distinguish a local unprivileged
  process from the legitimate client, because both are NAT'd to the gateway
  address. That limitation is real, unfixable via export options, and is now
  documented in README's Limitations with `--net-helper vmnet` as the remedy.
- Under vmnet the combination (peer restricted to the host + reserved ports
  required) does close the hole. **Not yet verified on hardware** — needs a
  mount with `--net-helper vmnet`.

### Original hypothesis for step 2.3

Under gvproxy the guest asks the host to forward `{bind_addr}:2049` to
`{VM_IP}:2049` (`vmproxy/src/main.rs`, `init_network`). gvproxy accepts on the
host and re-dials inside its own netstack, so the connection the guest's nfsd
sees is very likely sourced from the gateway on an *ephemeral* port. If that
holds:

- `insecure` is load-bearing under gvproxy and cannot be dropped, and
- peer restriction alone does not stop a local unprivileged process there,
  because its traffic is NAT'd to the same gateway address as the legitimate
  client.

Under vmnet-helper there is no NAT, so peer restriction is a genuine fix and
`insecure` should be droppable.

To settle it, mount a volume and inspect the peer address and source port the
guest sees:

```bash
sudo anylinuxfs mount /dev/diskN   # in one terminal
anylinuxfs shell -- ss -tn 'sport = :2049'
```

A source port <1024 means `insecure` can be dropped; >=1024 means it must stay.
Repeat with `--net-helper vmnet` to compare.

## Step 2.1 second attempt (2026-07-31)

The first attempt derived the peer as the first host address of the VM's
network — the address the guest *routes through* — which is not the address the
guest *observes* as the connection source. Mounts broke under both helpers.

Now the host observes its own address instead: `host_addr_on_network` scans
`if_addrs::get_if_addrs()` for an address inside the VM's CIDR and passes the
result to vmproxy as `--nfs-export-peer`. Restriction applies only when that
lookup succeeds, so the failure mode is an open export (previous behaviour)
rather than a broken mount. Under gvproxy there is no such network and no
restriction is attempted, which matches the finding that NAT makes one
pointless there.

`--nfs-export-peer` is also exposed on the host CLI, so alternative values can
be tried without a rebuild; `--nfs-export-peer '*'` opts out entirely.

Verified on hardware: the lookup finds `172.27.1.1` (the host's address on the
vmnet `/30`) and the restriction is applied.

### Correction to the step 2.3 conclusion

The vmnet failure attributed to the peer in commit `77ef149` was not caused by
the peer. That commit computed the vmnet peer as `native_network.hosts().next()`
— `172.27.1.1`, the same value the interface lookup now returns. The failure came
from the other half of the commit: dropping `insecure`.

So `insecure` is required under **both** helpers, not just gvproxy. macOS does not
present a reserved source port even over vmnet, where there is no forwarding.
`insecure` is now unconditional again.

### Residual exposure (finding #2 is not closed)

With the peer pinned to `172.27.1.1`, the export excludes other hosts but *not*
other processes on the Mac: a local program connecting to the guest's port 2049
over the vmnet interface presents that same source address. Combined with
`no_root_squash` and mandatory `insecure`, any local process still gets
root-equivalent access to the mounted disk.

This cannot be closed with export options. It would need either a transport not
reachable by arbitrary local processes (vsock rather than IP), packet filtering
on the vmnet address, or giving up `no_root_squash` — which would defeat the
tool's purpose. Documented in README's Limitations instead.

## Deferred: auto-created mount points leak on failed mounts

Not a security issue and pre-existing, but it makes failed mounts pile up
`/Volumes/<name>-1`, `-2`, ... directories.

`cmd_mount.rs:1048` creates the mount point, but the `deferred` cleanup that
removes it is only registered at `cmd_mount.rs:1779`, inside the success branch
(after the `"{} was mounted as {}"` line). A mount that fails after the
directory exists therefore leaks it, and the uniquifying loop at
`cmd_mount.rs:1041` picks the next free suffix on the following attempt.

Two candidate fixes:

1. Remove the directory on the error path inside `mount()`. Self-contained, but
   only covers failures originating in that function.
2. Pass `Deferred` into `mount()` and register the cleanup immediately after
   creation, covering every exit path. Correct, but `Deferred<'a>` holds boxed
   closures and this sits in the privilege drop/re-elevate path, so it needs
   care.

## Risks

- Step 2.1/2.3 can break mounting if the peer or port assumptions are wrong for a
  given net helper; both need testing against gvproxy *and* vmnet-helper before
  merge.
- Step 1.4 changes mount point names for labels containing unusual characters,
  which is user-visible.
