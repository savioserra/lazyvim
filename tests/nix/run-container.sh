#!/bin/sh
# The container E2E: THE behavioral verification lane. A throwaway nix
# container (nixos/nix) receives the flake source, builds the e2e persona's
# home plane and the proof driver inside, stages the boot home, then runs
# the driver — the retirement proof (no daemon unit, no socket), the
# consumer smokes (the launcher shim, the nvim headless boot with the
# languages composed, the lazy-lock merge, the theme tokens, the agent and
# terminal planes, the rc lane order), the adopt rehearsal, the
# apply-driven switch and the receipt — every step loud on the log the
# host script greps. This is the fresh-host parity proof: a bare home, one
# apply from the flake, the resulting home matching the declared
# expectations.
#
#   tests/nix/run-container.sh [log-path]
#
# Sources: WORKSTATION_E2E_FLAKE_SRC (the staged form — the check's
# produced entry, bin/run-container-e2e, records the flake source it
# mounts) or a `git archive HEAD` extraction of the checkout (proving the
# committed tree, never the dirty working tree; worktree gitdirs do not
# resolve in containers and the extraction lands in the scratch dir, never
# inside the repo).
#
# The gate: without a usable docker this lane refuses loudly with the
# named reason and the alternative — a container run without docker is not
# a degraded run, it is no run (the acceleration-gate contract: a lane
# that cannot accelerate is a denial-of-service against the host, never a
# "slow but real" pass).
set -eu

log=${1:-${TMPDIR:-/tmp}/workstation-container-e2e.log}
image=nixos/nix:2.35.3
volume=${WORKSTATION_E2E_STORE_VOLUME:-workstation-e2e-store}

if ! command -v docker >/dev/null 2>&1; then
	echo "no docker — the container E2E cannot run here; use a host with" >&2
	echo "docker (CI's ubuntu runners carry it) or run the eval gates" >&2
	echo "(nix flake check: the declared surface) instead" >&2
	exit 1
fi
if ! docker info >/dev/null 2>&1; then
	echo "docker is present but unusable (daemon unreachable, or no" >&2
	echo "permission on the socket) — the container E2E refuses to run;" >&2
	echo "fix the daemon or use a docker-capable host" >&2
	exit 1
fi

self_dir=$(CDPATH='' cd -P "$(dirname "$0")" && pwd -P)
src=${WORKSTATION_E2E_FLAKE_SRC:-}
if [ -z "$src" ] && [ -f "$self_dir/../share/flake-src" ]; then
	# the staged form: the check's entry records the flake source it mounts
	src=$(cat "$self_dir/../share/flake-src")
fi
if [ -z "$src" ]; then
	# the checkout form: prove the committed tree, never the dirty working
	# tree — a git archive HEAD extraction in the scratch dir
	repo_root=$(CDPATH='' cd -P "$self_dir/../.." && pwd -P)
	src=${TMPDIR:-/tmp}/workstation-e2e-src
	rm -rf "$src"
	mkdir -p "$src"
	(cd "$repo_root" && git archive HEAD) | tar -x -C "$src"
fi

echo "== the container E2E: $image, store volume $volume, source $src =="
# Inner script — the container's root with HOME at the persona home (the
# nix image runs single-user; the residual — user-plane separation and the
# service-manager probes — is named in docs/testing.md). The two build
# attrs are the lane's ONE wiring point: the flake's e2e checks
# output, plus the persona home the apply step targets.
docker run --rm \
	-v "$src:/workstation:ro" \
	-v "$volume:/nix" \
	"$image" /bin/sh -c '
		set -eu
		# capped parallelism: the lane runs on shared small hosts where an
		# unconstrained build burst OOMs (a signal-9 builder is a killed
		# host, not a failed test); NIX_CONFIG is newline-separated
		export NIX_CONFIG="extra-experimental-features = nix-command flakes
max-jobs = 2
cores = 2"
		echo "== container: building the persona home + the proof driver =="
		nix build --print-build-logs \
			"/workstation#checks.x86_64-linux.e2e-home" \
			--out-link /tmp/e2e-home
		nix build --print-build-logs \
			"/workstation#checks.x86_64-linux.e2e-driver" \
			--out-link /tmp/e2e-driver
		echo "workstation: container staged (the persona closure is realized)"
		home=/home/e2e
		export HOME=$home
		# the persona identity: the activation checks USER against
		# home.username and the container shell carries root
		export USER=e2e
		mkdir -p "$home"
		# the profile dirs the activation registers the generation into
		# (a bare container has neither until a first switch makes them)
		mkdir -p "$home/.local/state/nix/profiles" /nix/var/nix/profiles/per-user/e2e
		echo "== container: staging the boot home =="
		/tmp/e2e-home/activate
		nix-env --profile "${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-manager" \
			--set "$(readlink -f /tmp/e2e-home)"
		echo "workstation: home plane active (the boot home is staged)"
		echo "== container: the live proof (the driver) =="
		/tmp/e2e-driver/bin/workstation-e2e
	' >"$log" 2>&1 || {
	status=$?
	cat "$log"
	exit "$status"
}

echo "== assertions =="
grep -q 'workstation: container staged' "$log" \
	|| { echo 'FAIL: the persona closure never realized' >&2; exit 1; }
grep -q 'workstation: home plane active' "$log" \
	|| { echo 'FAIL: the boot home was never staged' >&2; exit 1; }
if grep -q 'workstation-e2e: .* FAIL' "$log"; then
	grep 'workstation-e2e:' "$log" >&2
	echo 'FAIL: the workstation E2E failed inside the container' >&2
	exit 1
fi
grep -q 'workstation-e2e: OK' "$log" \
	|| { echo 'FAIL: the workstation E2E never completed (no OK marker)' >&2; exit 1; }
grep 'workstation-e2e:' "$log"

echo 'container E2E (home plane, consumer smokes, the receipt): OK'
