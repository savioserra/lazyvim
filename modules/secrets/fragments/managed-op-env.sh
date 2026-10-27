# Workstation secrets fragment: the op environment (host-owned env file).
# shellcheck source=/dev/null
[ -r /etc/pi/op.env ] && { set -a; . /etc/pi/op.env; set +a; }
