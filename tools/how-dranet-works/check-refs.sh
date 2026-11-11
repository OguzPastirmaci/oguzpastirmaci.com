#!/usr/bin/env bash
# Checks every file:line reference in the how-dranet-works page against a dranet tag.
# Usage: check-refs.sh <dranet checkout> [tag]   (the tag defaults to RELEASE in the page)
set -euo pipefail

page="$(cd "$(dirname "$0")/../.." && pwd)/static/how-dranet-works/index.html"
repo="${1:?usage: check-refs.sh <dranet checkout> [tag]}"
tag="${2:-$(sed -n 's/.*var RELEASE = "\([^"]*\)";.*/\1/p' "$page")}"

git -C "$repo" rev-parse -q --verify "$tag^{commit}" >/dev/null || {
  echo "tag $tag not found in $repo (run: git -C $repo fetch --tags)" >&2
  exit 2
}

# A link to another tag means the tag replace in the page was incomplete.
if grep -oE 'kubernetes-sigs/dranet/(blob|tree)/[^/"]+' "$page" | grep -v "/$tag\$"; then
  echo "FAIL: the page links to a tag other than $tag" >&2
  exit 1
fi

fail=0
check() { # name path line
  local name="$1" path="$2" line="$3" src want
  src="$(git -C "$repo" show "$tag:$path" 2>/dev/null | sed -n "${line}p" | sed 's/^[[:space:]]*//')" || true
  if [ -z "$src" ]; then
    echo "FAIL    $path:$line ($name): no such line at $tag"
    fail=1
    return
  fi
  # A name that is a Go identifier must appear on its line. Other names need a look.
  if [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_.]*$ ]]; then
    want="${name##*.}"
    if [[ "$src" == *"$want"* ]]; then
      echo "ok      $path:$line  $name"
    else
      echo "FAIL    $path:$line ($name): ${src:0:90}"
      fail=1
    fi
  else
    echo "REVIEW  $path:$line ($name): ${src:0:90}"
  fi
}

# Step player references: ["name", "path", line]
while IFS=$'\t' read -r name path line; do
  check "$name" "$path" "$line"
done < <(grep -oE '\["[^"]+", "[A-Za-z][A-Za-z0-9_./-]+\.(go|yaml)", [0-9]+\]' "$page" |
  sed -E 's/\["([^"]+)", "([^"]+)", ([0-9]+)\]/\1\t\2\t\3/' | sort -u)

# Reference section links: .../blob/<tag>/path#L<line>">label</a>. A label of the form
# <code>name</code> or "<code>name</code> file.go:line" is checked by name.
while IFS=$'\t' read -r path line label; do
  if [[ "$label" =~ ^\<code\>([A-Za-z_][A-Za-z0-9_.]*)\</code\>(\ [A-Za-z_]+\.go:[0-9]+)?$ ]]; then
    name="${BASH_REMATCH[1]}"
  else
    name="link: $(sed -E 's/<[^>]+>//g' <<<"$label")"
  fi
  check "$name" "$path" "$line"
done < <(perl -ne 'while (m{blob/\Q'"$tag"'\E/([A-Za-z0-9_./-]+)#L(\d+)"[^>]*>(.*?)</a>}g) { print "$1\t$2\t$3\n" }' "$page" | sort -u)

if [ "$fail" -ne 0 ]; then
  echo "Some references do not match $tag. Fix the line numbers in $page." >&2
  exit 1
fi
echo "All references resolve at $tag. Read the REVIEW lines once."
