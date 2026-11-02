#!/bin/sh
# Runs the M28 baseline on the PullRequests of a local file. Run it again to resume.
# The PullRequest ids stay outside the repository, one id per line. A `#` starts a comment.
# The default file is pullrequests.txt in the folder that holds the repository checkout.
# The harness exits with 1 for a transient failure and 3 for a permanent one.
# `zig build bench-file-cache` turns every failure into 1, so the script runs the binary.
set -u

usage() {
	echo "usage: $0 [--pullrequests <file>] <run-label> <network-label> [output-dir]" >&2
	exit 2
}

list=${M28_PULLREQUESTS_FILE:-$(cd "$(dirname "$0")/../.." && pwd -P)/pullrequests.txt}
if [ "${1:-}" = "--pullrequests" ]; then
	[ "$#" -ge 2 ] || usage
	list=$2
	shift 2
fi
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
	usage
fi
run=$1
network=$2
dir=${3:-$HOME/m28-runs}

if [ ! -f "$list" ] || [ ! -r "$list" ]; then
	echo "m28: PullRequest file $list is missing or unreadable, stop" >&2
	exit 2
fi
pullrequests=$(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$list") || exit 2
if [ -z "$pullrequests" ]; then
	echo "m28: PullRequest file $list holds no PullRequest id, stop" >&2
	exit 2
fi
bad=$(printf '%s\n' "$pullrequests" | grep -v -x '[1-9][0-9]*' | head -n 1)
if [ -n "$bad" ]; then
	echo "m28: PullRequest file $list holds the malformed id '$bad', stop" >&2
	exit 2
fi

mkdir -p "$dir" || exit 1
dir=$(cd "$dir" && pwd) || exit 1
cd "$(dirname "$0")/.." || exit 1
zig build install-bench-file-cache || exit 1
bench=$PWD/zig-out/bin/bbr-file-cache-bench

for pr in $pullrequests; do
	attempt=1
	while :; do
		"$bench" remote pr-webapp "$pr" \
			--run-label "$run" --network-label "$network" --output-dir "$dir"
		code=$?
		[ "$code" -eq 0 ] && break
		if [ "$code" -eq 3 ]; then
			echo "m28: #$pr failed permanently, stop" >&2
			exit 3
		fi
		if [ "$attempt" -ge 6 ]; then
			echo "m28: #$pr failed $attempt times, stop" >&2
			exit 1
		fi
		echo "m28: #$pr failed attempt $attempt of 6 with exit code $code, retry in 900 s" >&2
		attempt=$((attempt + 1))
		sleep 900
	done
done
echo "m28: $run done" >&2
