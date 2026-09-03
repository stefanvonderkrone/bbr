#!/bin/sh
set -eu

# Report a fixture test failure and stop.
fail() {
    printf '%s\n' "release validation test: $1" >&2
    exit 1
}

# Create a tagged Git repository for one release validation scenario.
make_fixture() {
    name=$1
    tag=$2
    package_version=$3
    prior_sequences=${4:-}
    source_mismatch=${5:-0}
    fixture=$tmp/$name

    mkdir "$fixture"
    git -C "$fixture" init -q
    printf '.{\n    .name = .bbr,\n    .version = "%s",\n}\n' "$package_version" >"$fixture/build.zig.zon"
    printf '%s\n' source >"$fixture/source.txt"
    if [ "$source_mismatch" = 1 ]; then
        : >"$fixture/force-source-mismatch"
    fi
    git -C "$fixture" add --all
    GIT_AUTHOR_DATE='@1711283696 +0000' GIT_COMMITTER_DATE='@1711283696 +0000' \
        git -C "$fixture" -c user.name=bbr -c user.email=bbr@example.invalid commit -q -m base

    for sequence in $prior_sequences; do
        git -C "$fixture" -c user.name=bbr -c user.email=bbr@example.invalid \
            tag -a "v2024.3.24-$sequence" -m release
    done
    GIT_AUTHOR_DATE='@1711283696 +0000' GIT_COMMITTER_DATE='@1711283696 +0000' \
        git -C "$fixture" -c user.name=bbr -c user.email=bbr@example.invalid \
        commit -q --allow-empty -m release
    git -C "$fixture" -c user.name=bbr -c user.email=bbr@example.invalid tag -a "$tag" -m release
}

# Require the validator to accept a fixture.
expect_pass() {
    name=$1
    tag=$2
    if ! (cd "$tmp/$name" && PATH="$tmp/bin:$PATH" sh "$validator" "$tag"); then
        fail "$name was rejected"
    fi
}

# Require the validator to reject a fixture.
expect_fail() {
    name=$1
    tag=$2
    if (cd "$tmp/$name" && PATH="$tmp/bin:$PATH" sh "$validator" "$tag") >/dev/null 2>&1; then
        fail "$name was accepted"
    fi
}

root=$(pwd)
validator=$root/tests/validate_release.sh
tmp=$(mktemp -d "${TMPDIR:-/tmp}/bbr-release.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"

cat >"$tmp/bin/zig" <<'EOF'
#!/bin/sh
set -eu
mkdir -p zig-out/bin
if [ "${BBR_VERSION_COMMIT:-}" ]; then
    commit=$BBR_VERSION_COMMIT
else
    commit=$(git rev-parse HEAD)
fi
package_version=
while IFS= read -r line; do
    case "$line" in
        *'.version = "'*)
            value=${line#*\"}
            package_version=${value%%\"*}
            ;;
    esac
done <build.zig.zon
if [ "${BBR_VERSION_COMMIT:-}" ]; then
    : "${SOURCE_DATE_EPOCH:?}"
    : "${BBR_VERSION_SEQUENCE:?}"
    : "${BBR_VERSION_DIRTY:?}"
    [ "$SOURCE_DATE_EPOCH" = 1711283696 ]
    [ "$BBR_VERSION_SEQUENCE" = "${package_version##*-}" ]
    [ "$BBR_VERSION_DIRTY" = 0 ]
fi
version="bbr $package_version+g$(printf '%.12s' "$commit")"
if [ "${BBR_VERSION_COMMIT:-}" ] && [ -f force-source-mismatch ]; then
    version="$version-mismatch"
fi
cat >zig-out/bin/bbr <<EOF_INNER
#!/bin/sh
printf '%s\\n' '$version'
EOF_INNER
chmod +x zig-out/bin/bbr
EOF
chmod +x "$tmp/bin/zig"

make_fixture valid v2024.3.24-2 2024.3.24-2 1
expect_pass valid v2024.3.24-2

make_fixture dirty v2024.3.24-1 2024.3.24-1
printf '%s\n' dirty >>"$tmp/dirty/source.txt"
expect_fail dirty v2024.3.24-1

make_fixture malformed v2024.03.24-1 2024.03.24-1
expect_fail malformed v2024.03.24-1

make_fixture conflicting v2024.3.24-1 2024.3.24-1
git -C "$tmp/conflicting" -c user.name=bbr -c user.email=bbr@example.invalid \
    tag -a v2024.3.24-2 -m release
expect_fail conflicting v2024.3.24-1

make_fixture wrong-date v2024.3.25-1 2024.3.25-1
expect_fail wrong-date v2024.3.25-1

make_fixture reused-sequence v2024.3.24-2 2024.3.24-2 '1 3'
expect_fail reused-sequence v2024.3.24-2

make_fixture skipped-sequence v2024.3.24-3 2024.3.24-3 1
expect_fail skipped-sequence v2024.3.24-3

make_fixture package-mismatch v2024.3.24-1 2024.3.24-2
expect_fail package-mismatch v2024.3.24-1

make_fixture lightweight v2024.3.24-1 2024.3.24-1
git -C "$tmp/lightweight" tag -d v2024.3.24-1 >/dev/null
git -C "$tmp/lightweight" tag v2024.3.24-1
expect_fail lightweight v2024.3.24-1

make_fixture indirect v2024.3.24-1 2024.3.24-1
GIT_AUTHOR_DATE='@1711283696 +0000' GIT_COMMITTER_DATE='@1711283696 +0000' \
    git -C "$tmp/indirect" -c user.name=bbr -c user.email=bbr@example.invalid \
    commit -q --allow-empty -m later
expect_fail indirect v2024.3.24-1

make_fixture source-mismatch v2024.3.24-1 2024.3.24-1 '' 1
expect_fail source-mismatch v2024.3.24-1
