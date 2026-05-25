.PHONY: help seccomp-regen seccomp-audit seccomp-audit-strict

help:  ## Print available targets
	@awk 'BEGIN { FS = ":.*## " } /^[a-zA-Z_-]+:.*## / { printf "  %-22s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

# ───── Seccomp profile ────────────────────────────────────────────────
# The chrome.json profile is Docker/moby's default seccomp profile
# with a small, named patch (drop unprivileged clone/clone3
# restrictions; allow clone/clone3/unshare/setns unconditionally) so
# nested user-namespace sandboxes — Chrome, Electron, bwrap, glycin —
# can run without --no-sandbox. See docs/seccomp-how-to.md.

SECCOMP_PROFILE := src/common/seccomp/chrome.json
SECCOMP_BASELINE_TAG := $(shell jq -r '._baseline' $(SECCOMP_PROFILE) 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "v25.0.6")
SECCOMP_BASELINE_URL := https://raw.githubusercontent.com/moby/moby/$(SECCOMP_BASELINE_TAG)/profiles/seccomp/default.json

seccomp-regen:  ## Regenerate chrome.json from pinned upstream Docker baseline
	@bin/regen-seccomp.sh

seccomp-audit:  ## Diff chrome.json against its declared upstream baseline
	@echo "Baseline: $(SECCOMP_BASELINE_TAG)"
	@echo "Source:   $(SECCOMP_BASELINE_URL)"
	@echo
	@tmp=$$(mktemp -d) && trap "rm -rf $$tmp" EXIT && \
	  curl -fsSL "$(SECCOMP_BASELINE_URL)" \
	    | jq -S 'del(._baseline, ._patch, ._regen)' > $$tmp/baseline.json && \
	  jq -S 'del(._baseline, ._patch, ._regen)' $(SECCOMP_PROFILE) > $$tmp/ours.json && \
	  diff -u --label "moby $(SECCOMP_BASELINE_TAG)/profiles/seccomp/default.json" \
	          --label "$(SECCOMP_PROFILE)" \
	          $$tmp/baseline.json $$tmp/ours.json || true
	@echo
	@echo "Default action: $$(jq -r '.defaultAction' $(SECCOMP_PROFILE))"
	@echo "Total rule entries: $$(jq '.syscalls | length' $(SECCOMP_PROFILE))"

seccomp-audit-strict:  ## Fail (exit 1) if diff against baseline contains anything beyond the documented 4-syscall patch
	@tmp=$$(mktemp -d) && trap "rm -rf $$tmp" EXIT && \
	  curl -fsSL "$(SECCOMP_BASELINE_URL)" > $$tmp/baseline.json && \
	  jq -S 'del(._baseline, ._patch, ._regen)' $(SECCOMP_PROFILE) > $$tmp/ours.json && \
	  bin/regen-seccomp.sh >/dev/null 2>&1 && \
	  jq -S 'del(._baseline, ._patch, ._regen)' $(SECCOMP_PROFILE) > $$tmp/regen.json && \
	  if ! diff -q $$tmp/ours.json $$tmp/regen.json >/dev/null; then \
	    echo "FAIL: $(SECCOMP_PROFILE) is not the output of bin/regen-seccomp.sh against MOBY_TAG=$(SECCOMP_BASELINE_TAG)." >&2; \
	    echo "      Either rerun the script or update the baseline." >&2; \
	    diff -u $$tmp/regen.json $$tmp/ours.json >&2; \
	    exit 1; \
	  fi; \
	  echo "✓ chrome.json matches regen output for moby $(SECCOMP_BASELINE_TAG)"
