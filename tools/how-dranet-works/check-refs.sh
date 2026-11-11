#!/usr/bin/env bash
# Checks every file:line reference in the how-dranet-works page against a dranet tag.
# Usage: check-refs.sh <dranet checkout> [tag]
# The tag is the one the page must already use. It defaults to RELEASE in the page.
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
checked=0
check() { # name path line
  local name="$1" path="$2" line="$3" src want def
  checked=$((checked + 1))
  src="$(git -C "$repo" show "$tag:$path" 2>/dev/null | sed -n "${line}p" | sed 's/^[[:space:]]*//')" || true
  if [ -z "$src" ]; then
    echo "FAIL    $path:$line ($name): no such file or line at $tag, or the line is blank"
    fail=1
    return
  fi
  # A name that is a Go identifier must be defined on its line (func or type),
  # or be called there by its full dotted name, as in kubeletplugin.Start(.
  if [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_.]*$ ]]; then
    want="${name##*.}"
    def="^(func (\\([^)]*\\) )?${want}\\(|type ${want} )"
    if [[ "$src" =~ $def ]] || [[ "$name" == *.* && "$src" == *"$name("* ]]; then
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
done < <(perl -ne 'while (m{\["([^"]+)", "([A-Za-z][A-Za-z0-9_./-]+\.(?:go|yaml))", (\d+)\]}g) { print "$1\t$2\t$3\n" }' "$page" | sort -u)
steps_checked=$checked

# Every array that looks like a reference must have been parsed above.
loose="$(perl -ne 'while (m{\[\s*["\x27][^"\x27]+["\x27]\s*,\s*["\x27][^"\x27]+\.[a-z]+["\x27]\s*,\s*\d+\s*\]}g) { print "$&\n" }' "$page" | sort -u | wc -l | tr -d ' ')"
if [ "$steps_checked" -eq 0 ] || [ "$steps_checked" -ne "$loose" ]; then
  echo "FAIL    parsed $steps_checked step references, but the page has $loose"
  fail=1
fi

# Reference section links: .../blob/<tag>/path#L<line>">label</a>. A label of the form
# <code>name</code> or "<code>name</code> file.go:line" is checked by name. A line
# number in the label must equal the one in the link.
while IFS=$'\t' read -r path line label; do
  if [[ "$label" =~ ([A-Za-z_]+\.go):([0-9]+)$ ]]; then
    if [ "${BASH_REMATCH[1]}" != "${path##*/}" ] || [ "${BASH_REMATCH[2]}" != "$line" ]; then
      echo "FAIL    $path:$line: the link text says ${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
      fail=1
    fi
  fi
  if [[ "$label" =~ ^\<code\>([A-Za-z_][A-Za-z0-9_.]*)\</code\>(\ [A-Za-z_]+\.go:[0-9]+)?$ ]]; then
    name="${BASH_REMATCH[1]}"
  else
    name="link: $(sed -E 's/<[^>]+>//g' <<<"$label")"
  fi
  check "$name" "$path" "$line"
done < <(perl -ne 'while (m{blob/\Q'"$tag"'\E/([A-Za-z0-9_./-]+)#L(\d+)"[^>]*>(.*?)</a>}g) { print "$1\t$2\t$3\n" }' "$page" | sort -u)

anchors="$(grep -oE "blob/[^\"]+#L[0-9]+\"" "$page" | sort -u | wc -l | tr -d ' ')"
if [ $((checked - steps_checked)) -eq 0 ] || [ $((checked - steps_checked)) -lt "$anchors" ]; then
  echo "FAIL    parsed $((checked - steps_checked)) reference links, but the page has $anchors"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "Some references do not match $tag. Fix the line numbers in $page." >&2
  exit 1
fi
echo "All $checked references resolve at $tag. Read the REVIEW lines once."
