#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# make-fixtures.sh — build the disc images the tests read.
#
# Written by `hdiutil`, which ships with macOS and is not this plugin. That is the whole point: a
# reader and a writer from the same hand agree with each other and prove nothing. Every fixture is
# produced by Apple's tool, and the tests additionally compare the listing against `bsdtar`, a
# third independent implementation — except for the UDF-only image, which bsdtar cannot read at
# all, and which is therefore the one fixture that exists to show what this plugin adds.
#
# The manifest records each image's sha256 and the exact command that produced it, so a fixture
# that changes is visible in the diff rather than silently different.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="Tests/ISOPluginTests/Fixtures"
mkdir -p "$OUT"

SRC="$(mktemp -d)"
trap 'rm -rf "$SRC"' EXIT
TREE="$SRC/tree"

mkdir -p "$TREE/subdir" "$TREE/a-directory-with-a-long-name"
printf 'Hello from a disc image.\n'  > "$TREE/README.TXT"
printf 'nested contents\n'           > "$TREE/subdir/NESTED.TXT"
printf 'A file whose name plain ISO 9660 cannot spell.\n' \
     > "$TREE/a-directory-with-a-long-name/long name with spaces.txt"
# Large enough to span many 2048-byte sectors and more than one read chunk, and generated from a
# fixed seed so the fixture is reproducible.
/usr/bin/perl -e 'srand(20260906); print pack("C", int(rand(256))) for 1..300000' > "$TREE/BIG.BIN"
ln -s README.TXT "$TREE/link-to-readme"

MANIFEST="$OUT/manifest.txt"
{
  echo "# Fixtures for the Peach Commander ISO / UDF plugin."
  echo "# Written by hdiutil (macOS), never by this plugin. Regenerate with Tools/make-fixtures.sh."
  echo
} > "$MANIFEST"

emit() {  # $1 = output name, rest = hdiutil flags
  local name="$1"; shift
  local path="$OUT/$name"
  rm -f "$path"
  hdiutil makehybrid -quiet -o "$path" "$@" "$TREE"
  local sum; sum="$(shasum -a 256 "$path" | cut -d' ' -f1)"
  {
    echo "file:    $name"
    echo "sha256:  $sum"
    echo "command: hdiutil makehybrid -o $name $* <tree>"
    echo
  } >> "$MANIFEST"
  printf 'built %s (%s bytes)\n' "$path" "$(stat -f%z "$path")"
}

emit iso9660.iso -iso                 # plain ISO 9660 (hdiutil adds Rock Ridge)
emit joliet.iso  -iso -joliet         # …plus a Joliet supplementary descriptor
emit udf.iso     -udf                 # UDF only — bsdtar opens nothing here
emit hybrid.iso  -iso -joliet -udf    # all three at once, which is what a real disc looks like

echo
echo "Fixtures and manifest written to $OUT"
