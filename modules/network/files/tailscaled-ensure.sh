# Managed by the workstation substrate — the network domain's tailscaled on
# a standalone linux leg (systemd, not NixOS; NixOS and darwin run the
# system module's services.tailscale).
#
#   workstation-tailscaled on    the substrate daemon; any previous install goes
#   workstation-tailscaled off   retract the substrate daemon (the state stays)
#
# | Surface | Owner |
# | --- | --- |
# | `/etc/systemd/system/tailscaled.service` | the substrate unit (the marker line), rewritten each apply |
# | `/nix/var/nix/gcroots/workstation-tailscaled` | the GC root of the running package |
# | `/var/lib/tailscale` | the node state — kept across the cutover, never deleted |
# | `/var/lib/workstation/tailscale-pre-substrate-<stamp>/` | the state copy and the moved-aside sources/units of a previous install |
#
# - A previous install (apt/dnf/pacman package, snap, a foreign unit) is
#   stopped, removed and replaced; package removal never purges (the apt
#   purge deletes /var/lib/tailscale, the node's identity).
# - Converged hosts need no root: the checks read world-readable state;
#   a change re-executes under sudo (non-interactive, or a prompt on a
#   terminal) and otherwise defers naming the exact command.
# - TAILSCALE_PKG (prepended by the build) is the tailscale package.
set -u
# the host's service and package managers live outside an activation PATH
PATH=$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin
export PATH

unit=/etc/systemd/system/tailscaled.service
marker='# managed by the workstation substrate (the network domain)'
gcroot=/nix/var/nix/gcroots/workstation-tailscaled
state_dir=/var/lib/tailscale
tailscaled=$TAILSCALE_PKG/bin/tailscaled

say() {
	printf 'workstation: tailscaled %s\n' "$*"
}

want=${1:-}
case $want in
on | off) ;;
*)
	printf 'usage: workstation-tailscaled on|off\n' >&2
	exit 2
	;;
esac

[ "$(uname -s)" = Linux ] || exit 0
if [ -e /etc/NIXOS ]; then
	exit 0
fi

render() {
	cat <<EOF
$marker — rewritten by every apply
[Unit]
Description=Tailscale node agent (workstation substrate)
Documentation=https://tailscale.com/kb/
Wants=network-pre.target
After=network-pre.target NetworkManager.service systemd-resolved.service

[Service]
ExecStart=$tailscaled --state=$state_dir/tailscaled.state --socket=/run/tailscale/tailscaled.sock --port=41641
ExecStopPost=$tailscaled --cleanup
Restart=on-failure
RuntimeDirectory=tailscale
RuntimeDirectoryMode=0755
StateDirectory=tailscale
StateDirectoryMode=0700
CacheDirectory=tailscale
CacheDirectoryMode=0750
Type=notify

[Install]
WantedBy=multi-user.target
EOF
}

ours() {
	[ -f "$unit" ] && [ ! -L "$unit" ] && grep -qF "$marker" "$unit"
}

foreign_pkg() {
	# the package manager owning a previous install (empty: none)
	if command -v dpkg-query >/dev/null 2>&1 &&
		dpkg-query -W -f='${Status}' tailscale 2>/dev/null | grep -q 'install ok installed'; then
		echo apt
	elif command -v pacman >/dev/null 2>&1 && pacman -Q tailscale >/dev/null 2>&1; then
		echo pacman
	elif command -v rpm >/dev/null 2>&1 && rpm -q tailscale >/dev/null 2>&1; then
		echo rpm
	elif command -v snap >/dev/null 2>&1 && snap list tailscale >/dev/null 2>&1; then
		echo snap
	fi
}

converged() {
	ours && render | cmp -s - "$unit" && [ -z "$(foreign_pkg)" ] &&
		systemctl is-active -q tailscaled.service && systemctl is-enabled -q tailscaled.service &&
		[ "$(readlink "$gcroot" 2>/dev/null)" = "$TAILSCALE_PKG" ]
}

# --- the cheap answer: nothing to do needs no root ---------------------------
if [ "$want" = on ]; then
	if [ ! -d /run/systemd/system ]; then
		say "provision deferred — systemd is not running here (start the daemon by hand: $tailscaled)"
		exit 0
	fi
	if converged; then
		say "already provisioned ($("$TAILSCALE_PKG/bin/tailscale" version 2>/dev/null | head -n 1), substrate unit, active)"
		exit 0
	fi
elif ! ours; then
	exit 0
fi

if [ "$(id -u)" != 0 ]; then
	if command -v sudo >/dev/null 2>&1 && { sudo -n true 2>/dev/null || [ -t 0 ]; }; then
		exec sudo "$0" "$want"
	fi
	say "provision deferred — needs root; run: sudo $0 $want"
	exit 0
fi

if [ "$want" = off ]; then
	systemctl disable --now tailscaled.service >/dev/null 2>&1
	rm -f "$unit" "$gcroot"
	systemctl daemon-reload
	say "stopped and removed (the substrate unit; the node state stays in $state_dir)"
	exit 0
fi

# --- a previous install goes ------------------------------------------------
backup=/var/lib/workstation/tailscale-pre-substrate-$(date -u +%Y%m%dT%H%M%SZ)
backup_state() {
	if [ -d "$state_dir" ] && [ ! -d "$backup/var-lib-tailscale" ]; then
		mkdir -p "$backup" && cp -a "$state_dir" "$backup/var-lib-tailscale" &&
			say "node state copied to $backup/var-lib-tailscale"
	fi
}

pm=$(foreign_pkg)
foreign_unit=0
if [ -e "$unit" ] || [ -L "$unit" ]; then
	ours || foreign_unit=1
fi
if [ -n "$pm" ] || [ "$foreign_unit" = 1 ]; then
	backup_state
	systemctl disable --now tailscaled.service >/dev/null 2>&1
fi
case $pm in
apt)
	# remove, never purge: the purge deletes /var/lib/tailscale
	DEBIAN_FRONTEND=noninteractive apt-get remove -y -q tailscale >/dev/null 2>&1 ||
		{ say 'removing the apt package tailscale failed — run: apt-get remove tailscale'; exit 1; }
	say 'removed the previous install (apt package tailscale)'
	for f in /etc/apt/sources.list.d/tailscale.list /etc/apt/sources.list.d/tailscale.sources \
		/usr/share/keyrings/tailscale-archive-keyring.gpg; do
		if [ -e "$f" ]; then
			mkdir -p "$backup" && mv "$f" "$backup/" && say "moved the apt source $f to $backup"
		fi
	done
	;;
pacman)
	pacman -R --noconfirm tailscale >/dev/null 2>&1 ||
		{ say 'removing the pacman package tailscale failed — run: pacman -R tailscale'; exit 1; }
	say 'removed the previous install (pacman package tailscale)'
	;;
rpm)
	{ dnf remove -y tailscale || yum remove -y tailscale; } >/dev/null 2>&1 ||
		{ say 'removing the rpm package tailscale failed — run: dnf remove tailscale'; exit 1; }
	f=/etc/yum.repos.d/tailscale.repo
	if [ -e "$f" ]; then
		mkdir -p "$backup" && mv "$f" "$backup/" && say "moved the repo $f to $backup"
	fi
	say 'removed the previous install (rpm package tailscale)'
	;;
snap)
	# the snap keeps its state under /var/snap: carried over first
	snap_state=/var/snap/tailscale/common/tailscaled.state
	if [ -f "$snap_state" ] && [ ! -f "$state_dir/tailscaled.state" ]; then
		mkdir -p "$state_dir" && chmod 0700 "$state_dir" && cp -a "$snap_state" "$state_dir/tailscaled.state" &&
			say "node state carried over from the snap ($snap_state)"
	fi
	snap remove tailscale >/dev/null 2>&1 ||
		{ say 'removing the snap tailscale failed — run: snap remove tailscale'; exit 1; }
	say 'removed the previous install (snap tailscale)'
	;;
esac
# a foreign unit at the substrate's path (a hand-written unit, the package's
# removal mask) moves aside
if { [ -e "$unit" ] || [ -L "$unit" ]; } && ! ours; then
	mkdir -p "$backup" && mv "$unit" "$backup/" && say "moved the previous unit $unit to $backup"
fi

# --- the substrate daemon ----------------------------------------------------
mkdir -p "${gcroot%/*}" && ln -sfn "$TAILSCALE_PKG" "$gcroot"
changed=0
if ! ours || ! render | cmp -s - "$unit"; then
	tmp=$unit.workstation.$$
	if ! { render >"$tmp" && chmod 0644 "$tmp" && mv "$tmp" "$unit"; }; then
		say "writing $unit failed"
		exit 1
	fi
	changed=1
	systemctl daemon-reload
fi
systemctl enable tailscaled.service >/dev/null 2>&1
if [ "$changed" = 1 ] || ! systemctl is-active -q tailscaled.service; then
	if systemctl restart tailscaled.service; then
		say "running $("$TAILSCALE_PKG/bin/tailscale" version 2>/dev/null | head -n 1) (substrate unit; state $state_dir)"
	else
		say 'start failed — journalctl -u tailscaled'
		exit 1
	fi
else
	say 'already provisioned (substrate unit, active)'
fi
