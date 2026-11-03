#!/usr/bin/env bash
#
# mayhem/build-deps.sh — fetch, pin and install BlazingMQ's build dependencies (BDE + ntf-core, which
# Debian does not package) into the in-image, $HOME-independent prefix /opt/toolchains/bb.
#
# Runs ONCE, online, from mayhem/Dockerfile (before the source tree is copied in). mayhem/build.sh then
# resolves everything from this prefix, so the air-gapped PATCH re-run never touches the network.
# Idempotent: a finished install (marker file) is a no-op.
set -euo pipefail

: "${BB_PREFIX:=/opt/toolchains/bb}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
# Shipping assert level (upstream builds BDE as opt_64_*): BSLS_ASSERT_SAFE inside BDE's own .cpp files
# (e.g. bdlbb::BlobUtil::append) is compiled out of a shipped broker, so it must not abort the fuzzers either.
# opt_dbg = optimized, with DWARF symbols.
: "${UFID:=opt_dbg_64_cpp17}"

# Pinned upstream revisions (tags 4.39.0.0 / 4.39.0.0 / 2.6.12 of bloomberg/*), matching bin/build-ubuntu.sh.
BDE_TOOLS_REV=2ee08743d08748c6ea237ffc3aec0a3edf4783d4
BDE_REV=6511e64b2f19fb55aa45c6f4e2db51cc659a4216
NTF_REV=a4c0a2acd70ec05347562c94151f99f8dbe4835c

SRCDIR="$BB_PREFIX/src"
BLDDIR="$BB_PREFIX/build"
mkdir -p "$SRCDIR" "$BLDDIR"

if [ -e "$BB_PREFIX/.complete" ]; then
  echo "deps already installed in $BB_PREFIX"
  exit 0
fi

fetch() { # <repo> <rev>
  local dir="$SRCDIR/$1"
  [ -d "$dir/.git" ] && return 0
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" fetch -q --depth 1 "https://github.com/bloomberg/$1.git" "$2"
  git -C "$dir" checkout -q FETCH_HEAD
}
fetch bde-tools "$BDE_TOOLS_REV"
fetch bde "$BDE_REV"
fetch ntf-core "$NTF_REV"

# Dependencies are NOT sanitizer-instrumented (the fuzzed project code is); they only need position
# independent code (they are linked into PIE executables) and DWARF < 4 so the final binaries carry no
# DWARF-5 compile units.
export CC=clang CXX=clang++
export CFLAGS="-fPIC $DEBUG_FLAGS" CXXFLAGS="-fPIC $DEBUG_FLAGS"
unset SOURCE_DATE_EPOCH

export PATH="$SRCDIR/bde-tools/bin:$PATH"
pushd "$SRCDIR/bde" >/dev/null
eval "$(bbs_build_env -p clang -u "$UFID" -b "$BLDDIR/bde" -i "$BB_PREFIX")"
bbs_build configure --prefix="$BB_PREFIX"
bbs_build build --prefix="$BB_PREFIX" -j"$MAYHEM_JOBS"
bbs_build install --install_dir="/" --prefix="$BB_PREFIX"
eval "$(bbs_build_env unset)"
popd >/dev/null

# bbs_build_env unset clears CC/CXX/CFLAGS/CXXFLAGS; ntf-core's toolchain.cmake falls back to gcc without them,
# and a gcc-built libnts references a different bsls::Atomic type than the clang-built BDE provides.
export CC=clang CXX=clang++
export CFLAGS="-fPIC $DEBUG_FLAGS" CXXFLAGS="-fPIC $DEBUG_FLAGS"

pushd "$SRCDIR/ntf-core" >/dev/null
./configure --prefix "$BB_PREFIX" \
  --output "$BLDDIR/ntf" \
  --without-warnings-as-errors \
  --without-usage-examples \
  --without-applications \
  --with-zlib \
  --without-zstd \
  --without-lz4 \
  --ufid "$UFID"
make -j"$MAYHEM_JOBS"
make install
popd >/dev/null

touch "$BB_PREFIX/.complete"
