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

## Risks

- Step 2.1/2.3 can break mounting if the peer or port assumptions are wrong for a
  given net helper; both need testing against gvproxy *and* vmnet-helper before
  merge.
- Step 1.4 changes mount point names for labels containing unusual characters,
  which is user-visible.
