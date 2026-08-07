.PHONY: install install-linux install-macos apply capture restore restore-tmux check update sync lock-mason

install:
	./scripts/install

install-linux:
	./scripts/install-linux

install-macos:
	./scripts/install-macos

apply:
	./scripts/apply

capture:
	./scripts/capture

restore:
	./scripts/restore

restore-tmux:
	./scripts/restore-tmux

check:
	./scripts/check

update:
	./scripts/update

sync:
	./scripts/sync

lock-mason:
	./scripts/lock-mason
