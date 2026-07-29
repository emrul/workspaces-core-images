# Design: a named AppArmor profile that survives userns restriction

**Status:** proposal, not started. Supersedes nothing; complements
`design/glycin-whiteout-tldr.md` (desktop icons — already fixed) and
`design/known_issues.md` § 2 (FHS apps — the problem this targets).

**One-line goal.** Replace `apparmor=unconfined` in the workspace `run_config`
with `apparmor=kasm-app-bwrap`, such that bubblewrap completes its *full* setup on
a host with `kernel.apparmor_restrict_unprivileged_userns=1`.

---

## 1. What this buys us

| | today (`apparmor=unconfined`) | with a working named profile |
|---|---|---|
| FHS apps (only-office, steam) on `restrict=1` hosts | **broken** — `bwrap: setting up uid map: Permission denied`, app never starts | **work** (the objective) |
| Desktop icons / panel | already fixed by `bwrap_dispatch.sh` | unchanged |
| AppArmor confinement | **none** — all of `sys_module`, `sys_rawio`, `/dev/mem`, `/proc/kcore`, `/sys/firmware` reachable | retained; only bwrap's mount set is re-opened |
| `workspaces-stigs` V-235812 | **false FAIL** ("seccomp unconfined" — it greps `SecurityOpt` for the string `unconfined`) | **PASS** |
| Host sysctl change required | no | no |
| Works on hosts that don't know about us | **yes** | **NO — see § 6** |

The last row is the whole tension. Everything else is upside.

**What it does NOT buy.** Nothing about the desktop whiteout — the bwrap
dispatcher already fixes that everywhere, independently. This work is exclusively
about (a) FHS/buildFHSEnv apps on hardened hosts and (b) STIG cleanliness.

---

## 2. Why the current profiles fail (measured)

Both profiles already have the right *shape* — `abi <abi/4.0>`, `capability,`,
`network,`, `userns,`, and `kasm-app-bwrap` has an explicit mount list plus
`pivot_root`. This is not "write a profile from scratch"; it is "find the two
rules that don't match".

Measured on a throwaway from the SaaS host image (CIS L2 Hardened 2.2.4,
`restrict_unprivileged_userns=1`), `seccomp=bwrap.json` in all rows:

| apparmor | bwrap result |
|---|---|
| `unconfined` | `loopback: Failed RTM_NEWADDR: Operation not permitted` |
| `kasm-app-bwrap` | `Failed to make / slave: Permission denied` (EACCES) |
| `kasm-desktop` | `No permissions to create a new namespace` |

### Hypothesis A — `kasm-app-bwrap`: the mount rule is too specific

`src/common/apparmor/kasm-app-bwrap:57` grants:

```
mount options=(rw,rslave),
```

The failing operation is bwrap's `mount --make-rslave /`, a *propagation-only*
change. It carries no `rw`, so in AppArmor terms it is `mount options=(rslave)`
and the rule above plausibly never matches. Same class of gap likely exists for
the other propagation flags (`rprivate`, `rshared`) and for `remount` variants.

**This is a one-line, directly falsifiable hypothesis** — see § 4 phase 2.

### Hypothesis B — `kasm-desktop`: `userns,` may not grant creation

`kasm-desktop:53` has bare `userns,` yet namespace creation is denied. Either the
bare rule does not imply the `create` permission the way most AppArmor rules imply
all permissions, or the parser silently dropped it. Needs `userns create,` tried
explicitly, and the loaded policy inspected (`apparmor_parser -p` to dump what the
kernel actually got, not what we wrote).

Note `kasm-desktop` has **no mount rules at all**, so even with creation fixed it
would then fail exactly like `kasm-app-bwrap`. If the desktop images ever need
real bwrap (they do not today — the dispatcher passes glycin through), the two
profiles must converge.

---

## 3. Prerequisite: denial visibility

**This is the actual blocker and phase 1 of the work.** On the hardened host,
`ausearch -m AVC,USER_AVC -ts recent` returned **nothing** after a reproducible
EACCES, and `dmesg` is unreadable (`kernel.dmesg_restrict=1`). Without denial
records every iteration is guesswork, and guessing at mount rule syntax is
precisely how we get a profile that looks right and isn't.

Tasks:

- Load the profiles in **complain** mode (`COMPLAIN=1 bin/load-apparmor.sh`) so
  operations are logged-and-allowed rather than denied. In complain mode a single
  run should emit the *complete* list of operations bwrap performs — that list is
  the specification for the profile.
- Establish where denials land on a CIS box: `/var/log/audit/audit.log` directly,
  `aa-notify -s`, or `journalctl -k` as root. Determine whether auditd's rules are
  filtering AVC records, and if so add a rule for the duration of the work.
- Sanity-check that we can see a *known* denial (e.g. touch `/proc/sysrq-trigger`
  under the profile, which is explicitly denied) before trusting an empty log.

Exit criterion: a reproducible EACCES produces a readable audit record naming the
operation and the requested mount flags.

---

## 4. Implementation phases

### Phase 1 — visibility (§ 3). No code changes.

### Phase 2 — prove the approach can work at all

Temporarily replace the mount list in `kasm-app-bwrap` with bare `mount,` plus
`umount, pivot_root,` and re-run the FHS probe on the hardened host.

- **bwrap completes** → the approach is viable and the problem is rule
  specificity. Continue to phase 3.
- **bwrap still fails** → Ubuntu's userns transition is stripping capabilities
  regardless of profile content. **Stop.** The named-profile route is dead; record
  the negative result and use the sysctl (§ 7 option C). This is a real
  possibility and the kill criterion for the whole design.

### Phase 3 — narrow to a minimal rule set

From the complain-mode log, write the exact operations bwrap needs. Expected
additions over today's file:

```
mount options=(rslave),          # make-rslave (no rw) — hypothesis A
mount options=(rprivate),
mount options=(rshared),
mount options=in (remount,ro,nosuid,nodev,noexec,relatime),
userns create,                   # explicit, not bare `userns,`
```

Every added rule must be justified by a log line, not by guessing. Keep the
existing `deny` block untouched — that block is the entire security value of the
profile over `unconfined`.

### Phase 4 — converge `kasm-desktop`

Either give it the same mount set, or document that desktop images must use
`kasm-app-bwrap`. Do not ship two profiles that differ in ways nobody can explain.

### Phase 5 — wire it up

- `bin/nix-profiles.toml`: add an `apparmor = "kasm-app-bwrap"` key alongside the
  existing `seccomp = "bwrap"`, so the requirement is declared where it can be
  audited (mirrors what `ci-scripts/nix-seccomp-audit.py` already does for
  seccomp).
- `bin/build-nix-store-volume` / `nix-crane-assemble`: emit a
  `dev.kasm.apparmor.profile` label, same mechanism as
  `dev.kasm.seccomp.profile`.
- Registry `run_config`: **conditional on § 6's decision** — this is the part
  that is not purely technical.

---

## 5. Acceptance criteria

All on the hardened host at `restrict_unprivileged_userns=1`, with
`seccomp=bwrap.json`:

1. `bwrap --unshare-all --die-with-parent --chdir / --ro-bind /usr /usr --dev /dev /bin/true`
   reaches `execvp` (no permission error).
2. `GdkPixbuf.Pixbuf.new_from_file(image-missing.svg)` succeeds.
3. Full desktop session: `xfce4-panel` alive, `Bail out!` = 0, pixbuf warnings = 0.
4. **`only-office:nix` session: `pgrep -fc DesktopEditors` > 0** and zero
   `setting up uid map` errors. This is the criterion that matters — it is what
   `unconfined` cannot achieve today.
5. `aa-status` shows the profile in **enforce** (not complain).
6. The `deny` block still bites: reading `/proc/kcore` or `/dev/mem` inside the
   container fails.
7. `apply_docker_stigs.sh` V-235812 reports PASS with a session running.

Criteria 5 and 6 exist because a profile that permits everything would pass 1–4
and be worth nothing.

---

## 6. What happens on hosts WITHOUT the profile loaded

**Measured, not assumed.** `docker run --security-opt apparmor=kasm-does-not-exist`
on a host where that profile is not in the kernel:

```
docker: Error response from daemon: failed to create task for container:
failed to create shim task: OCI runtime create failed: runc create failed:
unable to start container process: error during container init:
unable to apply apparmor profile: apparmor failed to apply profile:
write fsmount:fscontext:proc/thread-self/attr/apparmor/exec:
no such file or directory
```

**docker exit code 127. The container never starts.** There is no partial start,
no degraded mode, no fallback to unconfined.

Consequences:

- A Kasm session on such a host **fails to provision**. The user gets a launch
  error rather than a desktop. (The precise Kasm UI string is **unverified** — no
  Kasm stack was stood up for this — but the agent's container create fails, so
  the session cannot start.)
- This is a **hard** failure and strictly worse, for that host, than today's
  behaviour: `apparmor=unconfined` always works, because `unconfined` needs
  nothing loaded.
- **The image cannot self-heal.** Verified inside a container: `securityfs` is not
  mounted, `/sys/kernel/security/apparmor/.load` is absent, and `apparmor_parser`
  is not installed. AppArmor policy is host-global and can only be loaded from the
  host. No entrypoint hook, no unit file, and no privileged trick in the image can
  make a missing profile appear.
- Failure mode comparison:

| scenario | today (`unconfined`) | named profile, host prepared | named profile, host NOT prepared |
|---|---|---|---|
| desktop | works | works | **no session at all** |
| FHS app on `restrict=1` | broken (uid map) | works | **no session at all** |
| diagnosis difficulty | white desktop, subtle | — | trivial — explicit docker error |

The one virtue of the failure is that it is **loud and unambiguous**, unlike the
whiteout it replaces. But it converts a cosmetic failure into a total one for any
consumer who hasn't loaded our policy — including third parties pulling from
`kasm-nix-registry`, who we cannot reach.

### Distribution requirement

For a host to be "prepared":

1. Install the profile to `/etc/apparmor.d/kasm-app-bwrap` (NOT just
   `apparmor_parser -r`, which loads into the running kernel only — that is how it
   is loaded on the test box today, and it would not survive a reboot; nothing is
   in `/etc/apparmor.d/` there).
2. `apparmor.service` (enabled by default on Ubuntu) loads `/etc/apparmor.d/` at
   boot, so step 1 makes it persistent.
3. Verify with `aa-status | grep kasm-app-bwrap`.

That is a per-host provisioning step for **every** workspace host — an ops change
of the same weight as setting a sysctl, which is the crux of § 7.

---

## 7. Rollout options

- **A — registry default stays `apparmor=unconfined`; named profile is opt-in.**
  Nothing breaks for anyone. Hardened/STIG fleets load the profile and override
  `run_config` themselves. Documented in `docs/apparmor-how-to.md`. **Recommended**
  — it is the only option that cannot break an unprepared consumer.
- **B — switch the published registry entries to `apparmor=kasm-app-bwrap`.**
  Best security posture and STIG-clean by default, but every consumer who has not
  loaded the profile loses all sessions (§ 6). Only defensible if the profile ships
  with, and is loaded by, the Kasm installer itself — i.e. an upstream change, not
  ours to make unilaterally.
- **C — don't do this work; set `kernel.apparmor_restrict_unprivileged_userns=0`
  on workspace hosts.** Already measured working for both the desktop and FHS
  apps. Costs one `sysctl.d` drop-in per host, needs no profile distribution, and
  cannot break unprepared consumers. Downside: re-enables unprivileged userns
  host-wide (the protection CIS added) and leaves V-235812 falsely failing.

**Honest comparison of C against A/B:** if ops must touch every workspace host
either way, C is strictly cheaper and has no failure mode. A/B are worth the effort
only because they keep AppArmor's other denials in force and clear the STIG
finding. Do not start A/B expecting a big functional win over C — there isn't one.
The win is posture and audit cleanliness.

---

## 8. Effort and risk

- Phase 1 (visibility): unknown, possibly the largest chunk — auditd on a CIS box
  is not cooperating and that must be solved before anything else.
- Phases 2–4: a few hours of iterate-and-measure *if* phase 2 succeeds.
- Phase 2 is a genuine fork with a real chance of failure (§ 4). If it fails the
  deliverable is a documented negative result plus option C.
- Phase 5 + docs: small.

**Kill criteria.** Abandon and adopt option C if: bare `mount,` does not let bwrap
complete (phase 2), or the minimal rule set ends up so broad that criterion 6 in
§ 5 cannot be met — a profile that must permit everything to work is `unconfined`
with extra steps.

---

## 9. Verification snippets

```sh
# host: is the profile loaded, and in what mode?
sudo aa-status | grep -A1 kasm-app-bwrap

# host: what did the kernel actually receive (vs what we wrote)?
sudo apparmor_parser -p src/common/apparmor/kasm-app-bwrap | grep -nE "mount|userns"

# container: does the deny block still bite? (must fail)
docker run --rm --security-opt apparmor=kasm-app-bwrap <img> cat /proc/kcore

# container: the criterion that matters
docker run -d --name oo --security-opt apparmor=kasm-app-bwrap \
  --security-opt seccomp=src/common/seccomp/bwrap.json <only-office img>
docker exec oo pgrep -fc DesktopEditors     # want > 0
docker logs oo 2>&1 | grep -c "setting up uid map"   # want 0
```
