#!/bin/sh
# VM test skeleton: build the workstation VM and boot it to activation.
#
#   tests/nix/run-vm.sh
#
# Builds nixosConfigurations.vm-test.config.system.build.vm, boots it
# headless and greps the serial log for the workstation activation
# markers + a reached multi-user target. KVM is used when available;
# otherwise qemu falls back to tcg (slow but real). Requires nix with
# flakes; the golden CI surface runs this where a builder exists.
set -eu
repo_root=$(CDPATH='' cd -P "$(dirname "$0")/../.." && pwd -P)
cd "$repo_root"
log="${1:-/tmp/workstation-vm-boot.log}"

export NIX_CONFIG="extra-experimental-features = nix-command flakes"

echo "== building the VM closure =="
nix build --print-build-logs \
  ".#nixosConfigurations.vm-test.config.system.build.vm" \
  --out-link tests/nix/vm-result
run_script=$(ls tests/nix/vm-result/bin/run-*-vm)

echo "== booting $run_script to activation + live E2E =="
# 1200s: tcg (no KVM) boots slow, and the live E2E runs after multi-user
# (daemon user unit + wire handshake + an apply-driven switch + the
# journal receipt). The VM never exits; the timeout IS the boot bound.
timeout 1200 "$run_script" -nographic </dev/null >"$log" 2>&1 || {
  status=$?
  [ "$status" -eq 124 ] || { cat "$log"; exit $status; }
}

echo "== assertions =="
grep -q 'workstation: engine staged' "$log" \
  || { echo 'FAIL: workstation system-activation marker missing' >&2; exit 1; }
grep -q 'workstation: home plane active' "$log" \
  || { echo 'FAIL: home-manager activation never completed' >&2; exit 1; }
grep -q 'workstation: boot-to-activation proof complete' "$log" \
  || { echo 'FAIL: VM never reached multi-user' >&2; exit 1; }

# The live proof: daemon user unit up, wire handshake, apply-driven
# switch, the `system` domain receipt in the daemon's journal, consumer
# smoke — all inside the VM, asserted by tests/nix/vm-e2e.nix's driver.
if grep -q 'workstation-e2e: .* FAIL' "$log"; then
  grep 'workstation-e2e:' "$log" >&2
  echo 'FAIL: the workstation E2E failed inside the VM' >&2
  exit 1
fi
grep -q 'workstation-e2e: OK' "$log" \
  || { echo 'FAIL: the workstation E2E never completed (no OK marker)' >&2; exit 1; }
grep 'workstation-e2e:' "$log"

echo 'VM boot-to-activation + live E2E: OK'
