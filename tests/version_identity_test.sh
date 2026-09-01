#!/bin/sh
set -eu

fail() {
    printf '%s\n' "version identity test: $1" >&2
    exit 1
}

assert_dirty() {
    path=$1
    if [ "$path" = tests/version-input.tmp ]; then
        : >"$tmp/git/$path"
    else
        printf '\n' >>"$tmp/git/$path"
    fi
    TZ=UTC zig build --build-file "$tmp/git/build.zig"
    value=$($tmp/git/zig-out/bin/bbr --version)
    case "$value" in
        *.dirty) ;;
        *) fail "$path did not mark the version dirty" ;;
    esac
    if [ "$path" = tests/version-input.tmp ]; then
        rm "$tmp/git/$path"
    else
        git -C "$tmp/git" show "HEAD:$path" >"$tmp/git/$path"
    fi
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/bbr-version.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

git ls-files -co --exclude-standard >"$tmp/files"
tar -cf "$tmp/source.tar" -T "$tmp/files"
mkdir "$tmp/git" "$tmp/source-copy"
tar -xf "$tmp/source.tar" -C "$tmp/git"
tar -xf "$tmp/source.tar" -C "$tmp/source-copy"

git -C "$tmp/git" init -q
git -C "$tmp/git" add --all
GIT_AUTHOR_DATE='@1711283696 +0000' GIT_COMMITTER_DATE='@1711283696 +0000' \
    git -C "$tmp/git" -c user.name=bbr -c user.email=bbr@example.invalid commit -q -m fixture

commit=$(git -C "$tmp/git" rev-parse HEAD)
epoch=$(git -C "$tmp/git" log -1 --format=%ct HEAD)

TZ=UTC zig build --build-file "$tmp/git/build.zig"
utc=$($tmp/git/zig-out/bin/bbr --version)
sleep 1
TZ=Pacific/Honolulu zig build --build-file "$tmp/git/build.zig"
honolulu=$($tmp/git/zig-out/bin/bbr --version)
[ "$utc" = "$honolulu" ] || fail "wall clock or time zone changed the version"

printf '\n' >>"$tmp/git/README.md"
: >"$tmp/git/src/.DS_Store"
TZ=Europe/Berlin zig build --build-file "$tmp/git/build.zig"
excluded=$($tmp/git/zig-out/bin/bbr --version)
[ "$utc" = "$excluded" ] || fail "documentation or ignored files marked the version dirty"

SOURCE_DATE_EPOCH=$epoch BBR_VERSION_COMMIT=$commit BBR_VERSION_SEQUENCE=0 BBR_VERSION_DIRTY=0 \
    TZ=Asia/Tokyo zig build --build-file "$tmp/source-copy/build.zig"
explicit=$($tmp/source-copy/zig-out/bin/bbr --version)
[ "$utc" = "$explicit" ] || fail "Git '$utc' and explicit '$explicit' source-copy versions differ"

assert_dirty build.zig
assert_dirty build.zig.zon
assert_dirty build/version.zig
assert_dirty src/main.zig
assert_dirty tests/version-input.tmp
assert_dirty vendors/sqlite/sqlite3.c
assert_dirty .github/workflows/ci.yml

git -C "$tmp/git" -c user.name=bbr -c user.email=bbr@example.invalid tag -a v2024.3.24-1 -m release
TZ=UTC zig build --build-file "$tmp/git/build.zig"
release=$($tmp/git/zig-out/bin/bbr --version)
short=$(printf '%.12s' "$commit")
[ "$release" = "bbr 2024.3.24-1+g$short" ] || fail "annotated release tag produced '$release'"
printf '\n' >>"$tmp/git/src/main.zig"
TZ=UTC zig build --build-file "$tmp/git/build.zig"
dirty_release=$($tmp/git/zig-out/bin/bbr --version)
[ "$dirty_release" = "bbr 2024.3.24-1+g$short.dirty" ] || fail "dirty release tag produced '$dirty_release'"
