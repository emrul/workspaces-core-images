# Namespace scoping — restricting `unshare`/`clone` to declared Nix apps

Companion to `design/security-model.md` §2, §5. That doc's proposed answer to the
container-wide userns grant was a per-binary AppArmor profile (§5.2). This is the
replacement: the same scoping, enforced by container-init, with no host policy
and no LSM dependency. It is **not** a substitute for userns remapping (§4a) —
see "Interplay with userns remapping" below.

**Goal.** A tenant running arbitrary commands in a workspace terminal cannot
create a user namespace. Only Nix apps that declare a need for one get it.

---

## 1. Why this is a narrowing problem, not a widening one

Seccomp filters are additive, inherited across `fork`/`exec`, and irrevocable. A
process can never re-widen its own filter. So "widen for the apps that need it"
must be implemented as:

- the **runtime** attaches the permissive profile (`chrome.json`, or `bwrap.json`
  if the image contains an FHS app) to PID 1, as today;
- **container-init does not narrow itself** — it applies an additional
  deny-namespaces filter to each child at spawn, before `exec`;
- units and launches for declared apps are spawned **without** that extra filter.

The tenant's terminal is a descendant of `window-manager.service`. Narrow that
unit and every command the tenant types inherits the restriction, permanently.

---

## 2. Mechanism

### 2a. `RestrictNamespaces=` unit directive

New directive in `container-init` (`github.com/emrul/container-init`), same name
and seccomp implementation as systemd's, applied to `src/common/kasm-go/units/*.service`.

- **Default-deny** — a unit with no `RestrictNamespaces=` gets all namespace
  types denied. This deliberately inverts systemd's default; fail-open is the
  property that made the AppArmor path unusable.
- Denial is an arg filter on the namespace bits of `clone`
  (`CLONE_NEW*` mask `0x7E020000`), plus `clone3`, `unshare`, `setns`.
- Installing the filter unprivileged needs `PR_SET_NO_NEW_PRIVS`. Wanted anyway
  (§4c), but it disables setuid binaries — confirm no unit depends on one.
- PID 1 and the 5 root infra units are unaffected; they are not tenant-reachable.

For **single-app images this is the whole design.** container-init spawns the one
app as `custom-startup.service`; the grant lands on that unit and nowhere else.
No launch plumbing, no whitelist.

### 2b. `nix-launch` → container-init spawn (desktops only)

On a desktop the app is launched by the panel/file manager, which is already
narrowed, so its children are too. The interposition point already exists:
`nix-activate:336` rewrites every generated shim's `Exec=` through
`/usr/local/bin/nix-launch`. `nix-launch` becomes a client that asks container-init
to spawn the app, and container-init performs the `exec` with the app's declared
filter.

Three requirements decide whether this is sound rather than decorative:

1. **Resolve by app id, not command line.** `nix-activate:366` chowns the
   `~/Desktop/nix-*.desktop` copies to the session user, so the tenant can edit
   `Exec=`. container-init must resolve the store path itself from root-owned
   `/nix/var/nix/profiles/_meta.json` and reject anything absent from it.
2. **Filter argv.** Chrome's `--gpu-launcher=`, `--renderer-cmd-prefix=`,
   `--utility-cmd-prefix=` execute an arbitrary command; path validation does not
   catch them. Pass only non-flag arguments (URLs, file paths); reject any
   argument beginning with `-`. Check the Firefox and Electron flag families
   before fixing the rule.
3. **Construct the environment, do not forward it.** Otherwise `LD_PRELOAD` into
   a declared app re-opens the whole grant. Accept only a whitelisted set from the
   client (`DISPLAY`, `XDG_RUNTIME_DIR`); build the rest as units do today.

With all three, container-init is not authenticating a process — it is
constructing one, so there is no gap between "which binary" and "whose code".

### 2c. Policy is derived, not hand-maintained

`bin/nix-profiles.toml` already declares the requirement per app
(`seccomp = "bwrap"`, currently 5 profiles). Extend the vocabulary so absence is
explicit rather than "inherit the image default", and derive the per-app filter
at activation:

| declaration | namespaces allowed |
|---|---|
| *(none)* | none |
| `chrome` | `user`, `pid` (`net` pending §5.3) |
| `bwrap` | the above **+** `mnt`, and the mount syscall family |

The requirement is also *derivable* from the closure (presence of
`chrome-sandbox`, `libcef`, electron, an FHS/bwrap wrapper).
`ci-scripts/nix-seccomp-audit.py` should compare declared against derived and
fail the build on drift, so the declaration is a verified property rather than a
comment.

---

## 3. What this protects against

- **Arbitrary tenant commands cannot create a user namespace.** `unshare -Ur true`
  from a workspace terminal returns `EPERM`. This is the stated goal, and it is
  what removes the container-wide property `security-model.md` §5 concedes.
- **Namespaced `CAP_SYS_ADMIN` is no longer reachable by tenant code**, so the
  userns-gated kernel classes are not either — the nf_tables/netfilter surface
  under `chrome.json`, and additionally the whole mount API under `bwrap.json`.
- **Accidental widening.** An app that does not declare a need does not get one,
  and CI fails if the declaration and the closure disagree.
- **No host state.** Nothing to load, remove, or garbage-collect per agent;
  policy is versioned with the image and identical on RHEL, Alpine, SUSE. An
  agent that does not know about us cannot silently run the workspace unscoped.

## 4. What this does not protect against

1. **Children of a declared app inherit its grant.** Seccomp cannot transition
   out on `exec`. A tenant who configures a native-messaging host
   (`~/.mozilla/native-messaging-hosts/`, Chrome's equivalent) or a handler in
   `~/.config/mimeapps.list` obtains a permissively-spawned child. This is
   scriptable. **On a full desktop this is a raised bar, not a boundary**, and
   §7 rows for untrusted shared agents must not lean on it.
2. **Kernel LPE.** Unchanged. A bug reachable without namespaces is unaffected;
   scoping only reduces the population of processes that can reach the
   namespace-gated surface.
3. **In-container privilege escalation** to container root (PID 1 and the 5 root
   units) — orthogonal, see §3 of the security model.
4. **Launching a declared app from a terminal.** It inherits the terminal's
   restricted filter and its sandbox fails to initialise. Functional regression,
   not a hole, and an accepted consequence of scoping by spawn lineage rather
   than by binary identity.

---

## 5. Interplay with userns remapping

**Orthogonal. Both are required; neither substitutes for the other.** They answer
the two separate objections in the security model:

| | answers | mechanism |
|---|---|---|
| userns remapping (§4a) | root PID 1 (§3) — *where an escape lands* | container uid 0 → unprivileged host uid |
| namespace scoping (this doc) | the seccomp delta (§2) — *who can reach the surface* | per-spawn seccomp filter |

Consequences of running both:

- A tenant shell cannot create a namespace at all, so the question of where its
  escape lands does not arise.
- A declared app **keeps** the grant. If it escapes by filesystem or namespace
  means, remapping is what makes it land as an unprivileged host uid — scoping
  does nothing for that case.
- Neither stops a kernel LPE. Remapping is irrelevant in kernel context (§4a);
  scoping only shrinks who can get there. Placement and a second kernel (§5.4)
  remain the only controls for that class.
- Scoping makes the *residual* grant small enough that remapping's raised bar is
  meaningful: without it, every tenant process can reach the surface, so
  "attacker needs a kernel bug" describes the whole tenancy rather than one app.

Note remapping and in-container namespace creation are compatible in principle —
a nested userns draws from the container's own mapped uid range — but this must
be tested for both Chrome's zygote and bwrap, not assumed.

---

## 6. Verify before shipping

- No unit depends on a setuid binary (`PR_SET_NO_NEW_PRIVS` breaks them).
- Chrome's zygote survives `CLONE_NEWNET` denial (`security-model.md` §5.3, open).
- Nested userns works under `userns-remap` for Chrome and for bwrap FHS apps.
- Firefox/Electron equivalents of the `--*-cmd-prefix` flag family (§2b.2).
- Kubernetes: the permissive base profile is `seccompProfile: type: Localhost`,
  so it needs node-side distribution (Security Profiles Operator or a DaemonSet).
  One static fleet-wide file, versus per-image policy — but it is host state, and
  it is the one piece of this design that is.

**Acceptance test** (both conditions, or the scoping is not working):

```
# from a tenant terminal in the workspace
unshare -Ur true                 # must fail
# in the app
chrome://sandbox                 # namespace sandbox must be active
```
