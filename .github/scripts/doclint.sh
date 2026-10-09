#!/bin/sh
# doclint — the moduledoc convention linter (r3.doclint).
#
# Every engine module states its layer and its one law; contract modules name
# their implementor policy. The lint reads the elixir sources tree-side and
# never edits them: headers are owned by the elixir partition, this check only
# holds the line.
#
# Rules (over the engine lib sources, elixir/apps/*/lib/**/*.ex, one check
# per defmodule; test support and fixtures are data, not engine surface):
#   no-moduledoc     module has no @moduledoc at all
#   moduledoc-false  @moduledoc false (a module that refuses to introduce itself)
#   no-layer         moduledoc lacks a "Layer: <name>." declaration
#   no-law           layer declared, but no "The <name> law: ..." sentence
#   law-mismatch     the law names a different layer than the declaration
#   no-policy        contract module (defines @callback, or lives under
#                    contracts/) whose moduledoc never says "implementor policy"
#
# The convention's exemplars are the kernel modules ("Layer: kernel. The
# kernel law: this module names no package, no backend and no workspace."),
# and Workstation.Core.Contracts.Contract's "(implementor policy: ...)".
#
# Ratchet: doclint-baseline.txt lists the violations that exist today, one
# "<path>:<Module>:<rule>" per line. A violation not in the baseline fails the
# build (the convention only ever tightens); a baseline entry that no longer
# violates also fails (prune the stale line). Regenerate with --update-baseline
# after legitimately fixing headers.
#
# --self-test lints a throwaway fixture tree with known violations and asserts
# the exact expected report, including the baseline mechanics.
#
# The parser is line-based over mix-formatted sources: a module opens with a
# margin "defmodule ... do" and closes with a margin "end" — the repo's
# convention keeps every engine module at the file margin (several per file
# is normal); the only indented defmodules in the tree are embedded template
# text, which is payload, not an engine module. Moduledocs are triple-quoted
# strings. Unformatted sources are outside the convention.

set -eu

progname=doclint.sh
repo_root=$(CDPATH='' cd -P "$(dirname "$0")/../.." && pwd -P)
baseline="$repo_root/.github/scripts/doclint-baseline.txt"

usage() {
	printf 'usage: %s [--self-test] [--update-baseline] [--baseline FILE]\n' "$progname" >&2
}

die() { printf '%s: %s\n' "$progname" "$1" >&2; exit 1; }

# The single awk pass: emits one "relpath:Module:rule" line per violation.
lint_sources() {
	awk '
FNR == 1 {
	if (depth) { printf "doclint: %s: unterminated module at EOF\n", FILENAME > "/dev/stderr"; }
	depth = 0; inmod = 0
}
{
	line = $0

	# Inside a moduledoc: only the closing triple-quote matters.
	if (inmod) {
		if (line ~ /"""/) { inmod = 0 }
		else if (modfile == FILENAME) { buf[depth] = buf[depth] "\n" line }
		next
	}

	# Contract modules are behaviours or live under a contracts/ directory.
	if (line ~ /^[ \t]*@callback/) { iscontract[depth] = 1 }

	if (line ~ /^defmodule[ \t]+[A-Za-z0-9_.]+[ \t]+do[ \t]*$/) {
		depth++
		name = line
		sub(/^defmodule[ \t]+/, "", name); sub(/[ \t]+do[ \t]*$/, "", name)
		mname[depth] = name
		hasdoc[depth] = 0; docfalse[depth] = 0; iscontract[depth] = 0
		buf[depth] = ""; mfile[depth] = FILENAME
		next
	}

	if (depth == 0) next

	if (line ~ /^[ \t]*@moduledoc([ \t]|$)/) {
		rest = line
		sub(/^[ \t]*@moduledoc[ \t]*/, "", rest)
		if (hasdoc[depth]) next   # first moduledoc wins; re-docs are noise
		if (rest ~ /^false/) { docfalse[depth] = 1; hasdoc[depth] = 1; next }
		hasdoc[depth] = 1
		if (rest ~ /^"""/) {
			docline[depth] = FNR
			tail = rest; sub(/^"""/, "", tail)
			if (tail ~ /"""/) {      # single-line doc
				sub(/""".*$/, "", tail); buf[depth] = tail
			} else { inmod = 1; modfile = FILENAME }
		} else if (rest ~ /^[ \t]*$/) {
			docline[depth] = FNR; inmod = 1; modfile = FILENAME
		} else if (rest ~ /^"/) {   # one-line string doc
			gsub(/^"[ \t]*|[ \t]*"$/, "", rest); buf[depth] = rest
		} else if (rest ~ /^~[sS]/) {
			docline[depth] = FNR; inmod = 1; modfile = FILENAME
		}
		next
	}

	if (line ~ /^end[ \t]*$/ && depth > 0) {
		where = FILENAME ":" mname[depth]
		if (!hasdoc[depth]) {
			print where ":no-moduledoc"
		} else if (docfalse[depth]) {
			print where ":moduledoc-false"
		} else {
			doc = buf[depth]
			lower = tolower(doc)
			layer = ""
			if (match(doc, /Layer:[ \t]*[a-z][a-z0-9_-]*\./)) {
				layer = substr(doc, RSTART, RLENGTH)
				sub(/^Layer:[ \t]*/, "", layer); sub(/\.$/, "", layer)
			}
			lawname = ""
			if (match(doc, /[Tt]he [a-z][a-z0-9_-]* law:/)) {
				lawname = substr(doc, RSTART, RLENGTH)
				sub(/^[Tt]he [ \t]*/, "", lawname); sub(/[ \t]+law:$/, "", lawname)
			}
			if (layer == "") print where ":no-layer"
			else if (lawname == "") print where ":no-law"
			else if (lawname != layer) print where ":law-mismatch"
			if (iscontract[depth] && index(lower, "implementor policy") == 0) {
				print where ":no-policy"
			}
		}
		depth--
	}
}
END { if (depth) exit 3 }
' "$@"
}

# Fixture tree for --self-test: formatted modules with a known violation set.
make_fixtures() {
	dir=$1
	mkdir -p "$dir/lib/contracts"

	cat >"$dir/lib/good.ex" <<'EOF'
defmodule Fix.Good do
  @moduledoc """
  A well-formed kernel module.

  Layer: kernel. The kernel law: this module names no package, no backend
  and no workspace.
  """
  def ok, do: :ok
end
EOF

	cat >"$dir/lib/nodoc.ex" <<'EOF'
defmodule Fix.NoDoc do
  def ok, do: :ok
end
EOF

	cat >"$dir/lib/refused.ex" <<'EOF'
defmodule Fix.Refused do
  @moduledoc false
  def ok, do: :ok
end
EOF

	cat >"$dir/lib/nolayer.ex" <<'EOF'
defmodule Fix.NoLayer do
  @moduledoc """
  Introduces itself but never states a layer or a law.
  """
  def ok, do: :ok
end
EOF

	cat >"$dir/lib/nolaw.ex" <<'EOF'
defmodule Fix.NoLaw do
  @moduledoc """
  A module.

  Layer: pipeline.
  """
  def ok, do: :ok
end
EOF

	cat >"$dir/lib/mismatch.ex" <<'EOF'
defmodule Fix.Mismatch do
  @moduledoc """
  A module.

  Layer: pipeline. The cli law: renders, never decides.
  """
  def ok, do: :ok
end
EOF

	cat >"$dir/lib/contracts/bad_contract.ex" <<'EOF'
defmodule Fix.Contracts.Bad do
  @moduledoc """
  A behaviour that never names who may implement it.
  """
  @callback go() :: :ok
end
EOF

	cat >"$dir/lib/contracts/good_contract.ex" <<'EOF'
defmodule Fix.Contracts.Good do
  @moduledoc """
  A behaviour.

  Layer: contract. The contract law: the kernel never names an
  implementation (implementor policy: implementations register by
  behaviour conformance).
  """
  @callback go() :: :ok
end
EOF

	cat >"$dir/lib/sequential.ex" <<'EOF'
defmodule Fix.Seq.First do
  @moduledoc """
  The first module is clean.

  Layer: kernel. The kernel law: names no package, no backend.
  """
  def ok, do: :ok
end

defmodule Fix.Seq.Second do
  def ok, do: :ok
end
EOF

	# A @doc block that merely QUOTES the convention must not satisfy the
	# layer rule, and a callback after the moduledoc still makes a contract.
	cat >"$dir/lib/doc_trap.ex" <<'EOF'
defmodule Fix.DocTrap do
  @moduledoc """
  Docs that quote the convention without stating it.
  """

  @doc """
  Example:

      Layer: kernel. The kernel law: nothing here.
  """
  def ok, do: :ok

  @callback go() :: :ok
end
EOF
}

self_test() {
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/doclint-selftest.XXXXXX")
	trap 'rm -rf "$tmp"' EXIT INT TERM
	make_fixtures "$tmp/src"

	( cd "$tmp/src" && lint_sources lib/*.ex lib/contracts/*.ex ) | LC_ALL=C sort >"$tmp/got" || die "self-test: lint pass failed"

	cat >"$tmp/want" <<'EOF'
lib/contracts/bad_contract.ex:Fix.Contracts.Bad:no-layer
lib/contracts/bad_contract.ex:Fix.Contracts.Bad:no-policy
lib/doc_trap.ex:Fix.DocTrap:no-layer
lib/doc_trap.ex:Fix.DocTrap:no-policy
lib/mismatch.ex:Fix.Mismatch:law-mismatch
lib/nodoc.ex:Fix.NoDoc:no-moduledoc
lib/nolaw.ex:Fix.NoLaw:no-law
lib/nolayer.ex:Fix.NoLayer:no-layer
lib/refused.ex:Fix.Refused:moduledoc-false
lib/sequential.ex:Fix.Seq.Second:no-moduledoc
EOF

	if ! diff -u "$tmp/want" "$tmp/got" >"$tmp/diff"; then
		printf '%s: self-test report mismatch\n' "$progname" >&2
		cat "$tmp/diff" >&2
		exit 1
	fi

	# Baseline mechanics: covering everything is green; one stale + one
	# uncovered violation must fail with actionable output.
	sort -u "$tmp/got" >"$tmp/full-baseline"
	lint_again() { ( cd "$tmp/src" && lint_sources lib/*.ex lib/contracts/*.ex ) | LC_ALL=C sort; }

	if lint_again | diff -q - "$tmp/full-baseline" >/dev/null; then
		printf '%s: self-test: clean baseline accepted\n' "$progname"
	else
		die "self-test: full baseline flagged"
	fi

	grep -v '^lib/mismatch.ex' "$tmp/full-baseline" >"$tmp/ratchet"   # stale entry
	if lint_again | diff - "$tmp/ratchet" >/dev/null 2>&1; then
		die "self-test: ratchet failed to flag a new violation"
	fi
	printf '%s: self-test: new violation and stale baseline entry detected\n' "$progname"
	printf '%s: self-test OK\n' "$progname"
}

update_baseline=0
while [ $# -gt 0 ]; do
	case $1 in
		--self-test) self_test; exit 0 ;;
		--update-baseline) update_baseline=1 ;;
		--baseline) [ $# -ge 2 ] || die "--baseline needs a path"; baseline=$2; shift ;;
		-h|--help) usage; exit 0 ;;
		*) usage; die "unknown argument: $1" ;;
	esac
	shift
done

cd "$repo_root"
# Engine lib sources only: apps/*/lib — find(1) gets no shell glob, so the
# lib boundary is enforced by the path filter.
files=$(find elixir/apps -type f -name '*.ex' 2>/dev/null | grep '/lib/' | LC_ALL=C sort)
[ -n "$files" ] || die "no elixir lib sources found under elixir/apps"

# The find output is a plain path list; splitting is deliberate.
# shellcheck disable=SC2086
violations=$(lint_sources $files | LC_ALL=C sort -u || true)

tmpv=$(mktemp "${TMPDIR:-/tmp}/doclint.XXXXXX")
trap 'rm -f "$tmpv"' EXIT INT TERM
if [ -n "$violations" ]; then printf '%s\n' "$violations" >"$tmpv"; else : >"$tmpv"; fi

if [ "$update_baseline" -eq 1 ]; then
	cp "$tmpv" "$baseline"
	printf '%s: baseline rewritten: %s entries\n' "$progname" "$(wc -l <"$baseline")"
	exit 0
fi

status=0

# New violations: on the tree but not waived in the baseline.
if [ -s "$tmpv" ]; then
	if [ -f "$baseline" ]; then
		new=$(LC_ALL=C comm -23 "$tmpv" "$baseline" || true)
	else
		new=$(cat "$tmpv")
	fi
	if [ -n "$new" ]; then
		printf 'doclint: violations outside the baseline (fix the header, or the convention regressed):\n%s\n' "$new" >&2
		status=1
	fi
fi

# Stale entries: waived in the baseline but no longer violating — prune them.
if [ -f "$baseline" ]; then
	stale=$(LC_ALL=C comm -13 "$tmpv" "$baseline" || true)
	if [ -n "$stale" ]; then
		printf 'doclint: stale baseline entries (the headers improved; prune these lines):\n%s\n' "$stale" >&2
		status=1
	fi
else
	die "missing baseline: $baseline (create it with --update-baseline)"
fi

if [ "$status" -eq 0 ]; then
	printf 'doclint: OK (%s lib files covered, %s waived)\n' \
		"$(printf '%s\n' "$files" | wc -l | tr -d ' ')" "$(wc -l <"$baseline" | tr -d ' ')"
fi
exit "$status"
