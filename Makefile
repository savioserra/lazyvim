.PHONY: install install-linux install-macos restore check update sync lock-mason

install:
	./scripts/install

install-linux:
	./scripts/install-linux

install-macos:
	./scripts/install-macos

restore:
	./scripts/restore

check:
	./scripts/check

update:
	./scripts/update

sync:
	./scripts/sync

lock-mason:
	./scripts/lock-mason
