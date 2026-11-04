# Managed by the workstation substrate — the network domain's darwin
# cutover: a previous Tailscale install goes before services.tailscale
# (nix-darwin) takes the node. Runs as root in the system activation.
#
# | Previous install | Step |
# | --- | --- |
# | `/Applications/Tailscale.app` (Standalone / App Store) | the console user deactivates its system extension (macOS asks for approval), the app quits and moves aside |
# | `/usr/local/bin/tailscale` (the app's CLI shim) | moves aside |
# | the brew formula `tailscale` | `brew services stop` + `brew uninstall` as the console user |
#
# - Moved items land in /var/lib/workstation/tailscale-pre-substrate-<stamp>/.
# - The app's node identity stays with the app: the substrate daemon logs
#   in as a new node (`tailscale up`).
# - A failed extension removal exits 1: the activation stops with the
#   previous install still serving the tailnet.
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH
export PATH

app=/Applications/Tailscale.app
shim=/usr/local/bin/tailscale
brew=/opt/homebrew/bin/brew

say() {
	printf 'workstation: tailscale %s\n' "$*"
}

# the BSD stat (GNU stat reads -f as filesystem status)
user=$(/usr/bin/stat -f %Su /dev/console 2>/dev/null)
has_brew=0
if [ -n "$user" ] && [ "$user" != root ] && [ -x "$brew" ] &&
	sudo -u "$user" "$brew" list --formula tailscale >/dev/null 2>&1; then
	has_brew=1
fi
has_shim=0
if [ -f "$shim" ] && grep -q 'Tailscale.app' "$shim" 2>/dev/null; then
	has_shim=1
fi
if [ ! -d "$app" ] && [ "$has_shim" = 0 ] && [ "$has_brew" = 0 ]; then
	exit 0
fi

backup=/var/lib/workstation/tailscale-pre-substrate-$(date -u +%Y%m%dT%H%M%SZ)

if [ -d "$app" ]; then
	if [ -z "$user" ] || [ "$user" = root ] || [ "$user" = loginwindow ]; then
		say 'previous install (Tailscale.app): removing its system extension needs a logged-in console user — log in at the Mac, then apply again'
		exit 1
	fi
	uid=$(id -u "$user")
	say "previous install (Tailscale.app): deactivating its system extension — approve the macOS dialog on the Mac ($user)"
	# bounded: an unanswered approval dialog stops the cutover, not the host
	if ! launchctl asuser "$uid" sudo -u "$user" perl -e 'alarm shift; exec @ARGV' 300 \
		"$app/Contents/MacOS/tailscale" configure sysext deactivate; then
		say 'deactivating the system extension failed or was not approved — the previous install keeps the tailnet; apply again to retry'
		exit 1
	fi
	launchctl asuser "$uid" sudo -u "$user" osascript -e 'quit app "Tailscale"' >/dev/null 2>&1 || true
	pkill -x Tailscale >/dev/null 2>&1 || true
	mkdir -p "$backup" && mv "$app" "$backup/" && say "moved $app to $backup"
fi
if [ "$has_shim" = 1 ]; then
	mkdir -p "$backup" && mv "$shim" "$backup/" && say "moved the app's CLI shim $shim to $backup"
fi
if [ "$has_brew" = 1 ]; then
	sudo -u "$user" "$brew" services stop tailscale >/dev/null 2>&1 || true
	sudo -u "$user" "$brew" uninstall tailscale >/dev/null 2>&1 &&
		say 'removed the previous install (brew formula tailscale)'
fi
say 'previous install removed — the substrate daemon (services.tailscale) takes over; log in with: sudo tailscale up'
