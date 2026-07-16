# Kasm Nix walkthrough

## A. Pre-requisite:

1. Docker &gt;= 28 is required for testing dynamic loading of applications
2. *If* testing layer deduplication on a Docker host (*optional*) note that `/etc/docker/daemon.json` needs `"features": { "containerd-snapshotter": true }` and a docker restart. This will change your image store so any images you already have will need to be pulled fresh. For example:

```json
{
    "features": { "containerd-snapshotter": true },
    ...
}
```

3. Add the nix registry to your Kasm install (must be amd64, not arm64): <https://kasm-nix-registry.emrul.dev>

## B. Testing a single-app image

1. Test the Chrome workspace image by installing it and running it. Observe that:

- It runs in Chrome's sandbox thanks to integrated seccomp profile
- It starts faster, stops faster and uses less memory

## C. Testing desktop images with dynamic app loading

1. Install the [fat-store](https://kasm-nix-registry.emrul.dev/1.1/new/Tml4IEZhdCBTdG9yZSAoYWxsIGFwcHMp/) from the registry. It should install as a *hidden* workspace into Kasm and is *not* launchable as a workspace on its own.


2) Install one or more of the desktops: [Ubuntu](https://kasm-nix-registry.emrul.dev/1.1/new/Tml4IERlc2t0b3AgKHNlbGVjdCBhcHBzKQ%3D%3D/), [Alpine](https://kasm-nix-registry.emrul.dev/1.1/new/Tml4IERlc2t0b3AgQWxwaW5lIChzZWxlY3QgYXBwcyk%3D/), [Fedora](https://kasm-nix-registry.emrul.dev/1.1/new/Tml4IERlc2t0b3AgRmVkb3JhIChzZWxlY3QgYXBwcyk%3D/).


3. Launch a desktop workspace using the configured launch form to select your application set.

### C.i. Testing layer dedup

1. With the `fat-store` installed from step C1, head over to a terminal on the agent host and try pulling another single-app image from the registry - for example: VLC, OnlyOffice, Firefox.
   - Observe that the application layers should already be on disk, and immediately start to extract. The only layers that are downloaded from the OCI image registry (gitlab) should be some small (few kilobyte) metadata layers.

## D. Looking into CI/CD

1. Head over to GitLab pipelines [https://gitlab.com/kasm-technologies/labs-sandbox/kasm-nix/-/pipelines](https://gitlab.com/kasm-technologies/labs-sandbox/kasm-nix/-/pipelines) and find a Passed and completed run.

2. Click the download dropdown next to the row and download the `publish` job's build artifacts.

3. There should be 2 artifacts `nix-build-report.md` and `nix-build-report.json` which report details about what was built and pushed during the run.


