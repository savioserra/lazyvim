#!/bin/sh
# Managed by the workstation engine — the agent package's hermes launcher.
#
# The engine provisions the full stack: the pinned interpreter at
# .local/opt/hermes/python (download contract, checksum-gated archive) and
# the pinned checkout at .hermes/hermes-agent (git recipe). This launcher
# resolves both at run time (never baked paths), so the bytes stay
# machine-independent. A missing or non-executable interpreter or checkout
# fails closed: the verify lane asserts this exact smoke.
set -eu

checkout=${HERMES_ENGINE_CHECKOUT:-$HOME/.hermes/hermes-agent}
python=$HOME/.local/opt/hermes/python/bin/python3

if [ ! -x "$python" ]; then
  echo "hermes: pinned interpreter missing at $python (run: workstation apply)" >&2
  exit 2
fi
if [ ! -f "$checkout/hermes_cli/main.py" ]; then
  echo "hermes: pinned checkout missing at $checkout (run: workstation apply)" >&2
  exit 2
fi

HERMES_ENGINE_CHECKOUT=$checkout
export HERMES_ENGINE_CHECKOUT
# Same posture as upstream's launcher: isolated interpreter, no inherited
# PYTHON* config, bytecode kept out of the engine-owned checkout.
PYTHONPYCACHEPREFIX=${XDG_CACHE_HOME:-$HOME/.cache}/hermes-pycache
export PYTHONPYCACHEPREFIX

exec "$python" -I -c 'import os, sys
os.environ.pop("PYTHONHOME", None)
os.environ.pop("PYTHONPATH", None)
sys.path.insert(0, os.environ["HERMES_ENGINE_CHECKOUT"])
import hermes_bootstrap
from hermes_cli.main import main
sys.exit(main())' "$@"
