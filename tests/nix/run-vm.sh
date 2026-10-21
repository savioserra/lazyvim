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

echo "== booting $run_script to activation =="
timeout 420 "$run_script" -nographic </dev/null >"$log" 2>&1 || {
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

# The daemon USER unit starts inside the user manager (journal, not the
# serial console); its live startup proof belongs to the P2 real-host leg.

echo 'VM boot-to-activation: OK'
