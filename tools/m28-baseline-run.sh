#!/bin/sh
# Runs the M28 baseline on the five PullRequests. Run it again to resume.
# The harness exits with 1 for a transient failure and 3 for a permanent one.
# `zig build bench-file-cache` turns every failure into 1, so the script runs the binary.
set -u

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
	echo "usage: $0 <run-label> <network-label> [output-dir]" >&2
	exit 2
fi
run=$1
network=$2
dir=${3:-$HOME/m28-runs}

mkdir -p "$dir" || exit 1
dir=$(cd "$dir" && pwd) || exit 1
cd "$(dirname "$0")/.." || exit 1
zig build install-bench-file-cache || exit 1
bench=$PWD/zig-out/bin/bbr-file-cache-bench

for pr in ${M28_PULLREQUESTS:?set M28_PULLREQUESTS to the PullRequest ids}; do
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
