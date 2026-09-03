#!/bin/sh
set -eu

# Report a release validation failure and stop.
fail() {
    printf '%s\n' "release validation: $1" >&2
    exit 1
}

[ "$#" = 1 ] || fail "expected one triggering tag"
tag=$1
case "$tag" in
    v*) ;;
    *) fail "triggering tag must start with v" ;;
esac
printf '%s\n' "$tag" | grep -Eq '^v[0-9]{4}\.([1-9]|1[0-2])\.([1-9]|[12][0-9]|3[01])-[1-9][0-9]*$' \
    || fail "triggering tag must match vYYYY.M.D-N"

[ -z "$(git status --porcelain=v1 --untracked-files=all --ignored=no)" ] \
    || fail "checkout is dirty"

head=$(git rev-parse HEAD)
exact_count=0
exact_type=
while read -r exact_tag object_type; do
    case "$exact_tag" in
        v*)
            exact_count=$((exact_count + 1))
            [ "$exact_tag" = "$tag" ] || fail "conflicting release tag points at HEAD"
            exact_type=$object_type
            ;;
    esac
done <<EOF
$(git for-each-ref --points-at="$head" --format='%(refname:short) %(objecttype)' refs/tags)
EOF
[ "$exact_count" = 1 ] || fail "triggering tag must be the only release tag at HEAD"
[ "$exact_type" = tag ] || fail "triggering tag must be annotated"

tag_object=
tag_type=
while read -r field value rest; do
    case "$field" in
        object) tag_object=$value ;;
        type) tag_type=$value ;;
        '') break ;;
    esac
done <<EOF
$(git cat-file tag "$tag")
EOF
[ "$tag_type" = commit ] && [ "$tag_object" = "$head" ] \
    || fail "triggering tag must point directly at HEAD"

release=${tag#v}
release_date=${release%-*}
sequence=${release##*-}
epoch=$(git show -s --format=%ct HEAD)
if utc_date=$(date -u -d "@$epoch" '+%Y %m %d' 2>/dev/null); then
    :
else
    utc_date=$(date -u -r "$epoch" '+%Y %m %d')
fi
read -r year month day <<EOF
$utc_date
EOF
commit_date="$year.${month#0}.${day#0}"
[ "$release_date" = "$commit_date" ] || fail "tag date does not match the UTC committer date"

prior_count=0
prior_max=0
for prior_tag in $(git tag --list "v$release_date-*"); do
    [ "$prior_tag" = "$tag" ] && continue
    printf '%s\n' "$prior_tag" | grep -Eq '^v[0-9]{4}\.([1-9]|1[0-2])\.([1-9]|[12][0-9]|3[01])-[1-9][0-9]*$' \
        || fail "malformed release tag exists for $release_date"
    prior_sequence=${prior_tag##*-}
    prior_count=$((prior_count + 1))
    if [ "$prior_sequence" -gt "$prior_max" ]; then
        prior_max=$prior_sequence
    fi
done
[ "$prior_count" = "$prior_max" ] || fail "release sequence history has a reuse or skip"
expected_sequence=$((prior_max + 1))
[ "$sequence" = "$expected_sequence" ] \
    || fail "release sequence must be $expected_sequence for $release_date"

package_version=
package_count=0
while IFS= read -r line; do
    case "$line" in
        *'.version = "'*)
            value=${line#*\"}
            package_version=${value%%\"*}
            package_count=$((package_count + 1))
            ;;
    esac
done <build.zig.zon
[ "$package_count" = 1 ] && [ "$package_version" = "$release" ] \
    || fail "package version must equal $release"

short_commit=$(printf '%.12s' "$head")
expected="bbr $release+g$short_commit"
zig build
git_version=$(./zig-out/bin/bbr --version)
[ "$git_version" = "$expected" ] || fail "Git build version '$git_version' does not equal '$expected'"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/bbr-release-source.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
git archive --format=tar HEAD | tar -xf - -C "$tmp"
[ ! -e "$tmp/.git" ] || fail "source copy contains Git metadata"
(
    cd "$tmp"
    SOURCE_DATE_EPOCH=$epoch \
    BBR_VERSION_COMMIT=$head \
    BBR_VERSION_SEQUENCE=$sequence \
    BBR_VERSION_DIRTY=0 \
        zig build
)
explicit_version=$("$tmp/zig-out/bin/bbr" --version)
[ "$explicit_version" = "$expected" ] \
    || fail "source-copy version '$explicit_version' does not equal '$expected'"
