# Nix Packaging Design Bundle

Lightweight design bundle for the Kasm Nix-packaging effort. Source of truth is
**[`REQUIREMENTS.md`](REQUIREMENTS.md)**.

| Doc | What it covers |
|---|---|
| [`REQUIREMENTS.md`](REQUIREMENTS.md) | Scope, models, constraints, open questions — start here |
| [`docs/build-pipeline.md`](docs/build-pipeline.md) | One store → fat + per-app images; nix2container; CI cache; nightly |
| [`docs/packaging-apps.md`](docs/packaging-apps.md) | Team guide: add an app; when a custom Nix package is needed; runtimes; persistence |
| [`docs/base-image-assessment.md`](docs/base-image-assessment.md) | Should the core image thin out / KasmVNC-as-Nix? (assessment) |
| [`docs/investigation-findings.md`](docs/investigation-findings.md) | Tooling decision (nix2container vs streamLayeredImage), runtime support, spikes |
| [`docs/build_plan.md`](docs/build_plan.md) | Milestones M0–M7, dependency graph, first live tests |
| [`docs/demo-environment-setup.md`](docs/demo-environment-setup.md) | Reproducible build-host setup (Docker, Nix, big-disk relocation, Chrome sandbox prereqs) |
| [`docs/handover.md`](docs/handover.md) | Session handover — what's built/running, findings, follow-ups |

Related, outside the bundle:

- [`../nix-package-process.md`](../nix-package-process.md) — the original
  single-image PoC design (store layout, activation, update cadence). Still
  authoritative for those mechanics; this bundle extends it to per-app images
  and the nix2container pipeline.
- [`../../docs/nix-how-to.md`](../../docs/nix-how-to.md) — end-user/operator
  guide (PoC-era; to refresh in M7).
- [`../../bin/nix-profiles.toml`](../../bin/nix-profiles.toml) — the profile set.
