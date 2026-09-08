#!/bin/sh
# One-shot retirement of the removed Go subagents daemon service. Runs before
# apply deletes the unit/plist so no dangling service-manager state remains.
# Remove this script once every supported host has applied past it.
set -eu

if command -v systemctl >/dev/null 2>&1; then
	systemctl --user disable --now workstation-subagents.service 2>/dev/null || true
	systemctl --user daemon-reload 2>/dev/null || true
elif command -v launchctl >/dev/null 2>&1; then
	launchctl bootout "gui/$(id -u)/com.workstation.subagents" 2>/dev/null || true
fi
