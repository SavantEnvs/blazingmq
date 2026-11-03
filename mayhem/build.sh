#!/usr/bin/env bash
#
# mayhem/build.sh — build BlazingMQ's fuzz harnesses (s_bmqfuzz_*), their -standalone reproducers and the unit-test suite.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

BB=/opt/toolchains/bb
[ -e "$BB/.complete" ] || { echo "missing $BB (BDE + ntf-core): mayhem/build-deps.sh must run at image build time" >&2; exit 1; }

# BDE + ntf-core live in $BB (built once in the image, not sanitized). Both builds below use BDE's clang toolchain
# file and read their compile flags from CFLAGS/CXXFLAGS.
export CC=clang CXX=clang++
export PKG_CONFIG_PATH="$BB/lib64/pkgconfig:$BB/lib/pkgconfig:$(pkg-config --variable pc_path pkg-config)"

configure() { # <build-dir> <assert-level> <flags> [extra cmake args...]
  local dir="$1" level="$2" flags="$3"; shift 3
  CFLAGS="$flags" CXXFLAGS="$flags" cmake --preset fuzz-tests -B "$dir" -S . -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$BB/src/bde-tools/BdeBuildSystem/toolchains/linux/clang-default.cmake" \
    -DCMAKE_MODULE_PATH="$BB/src/bde-tools/cmake;$BB/src/bde-tools/BdeBuildSystem" \
    -DCMAKE_PREFIX_PATH="$BB;$BB/src/bde-tools/BdeBuildSystem" \
    -DBMQ_ASSERT_LEVEL="$level" "$@"
}

# 1) The project (bmq + mqb libraries and the s_bmqfuzz harness objects), sanitized, DWARF 3. The harness
#    executables are NOT built by cmake: the harnesses define no main, so each is linked by hand in step 2.
# Assert level: upstream's Release default is OPT, and BSLS_ASSERT_SAFE aborts (internal invariants, often
# followed by graceful handling) do not exist in the shipped broker, so the fuzz build uses OPT.
configure build/fuzz OPT "-fPIC $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS"

# Not shipped: s_bmqfuzz_bmqp_ackmessageiterator and s_bmqfuzz_bmqp_rejectmessageiterator. AckMessageIterator::next()
# and RejectMessageIterator::next() never return when the header declares perMessageWords=0 (advance(0) succeeds
# forever; ConfirmMessageIterator::next() rejects that case with rc_INVALID_ADVANCE_LENGTH, these two do not), and
# neither header documents a nonzero precondition to guard with. libFuzzer exits on the first timeout and hits the
# case within ~20 execs, so the targets ran at 4-8 exec/s with no defect reported. Upstream bug.
TARGETS="$(cd src/standalones/s_bmqfuzz && ls s_bmqfuzz_*.fuzz.cpp | sed 's/\.fuzz\.cpp$//' | grep -v -E '^s_bmqfuzz_bmqp_(ack|reject)messageiterator$')"
OBJS=""
for t in $TARGETS; do OBJS="$OBJS src/standalones/s_bmqfuzz/CMakeFiles/$t.dir/$t.fuzz.cpp.o"; done
ninja -C build/fuzz -j"$MAYHEM_JOBS" src/groups/bmq/libbmq.a src/groups/mqb/libmqb.a $OBJS

# 2) Link every harness against the fuzzing engine, and again against the run-once standalone driver.
mkdir -p build/obj
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o build/obj/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build/obj/standalone_main.o
# The sancov callbacks the -fsanitize=fuzzer-no-link objects reference normally come from libFuzzer or the
# ASan runtime; an empty SANITIZER_FLAGS standalone link needs this stub for them.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/sancov_stub.c -o build/obj/sancov_stub.o

# s_bmqfuzz_bmqu_blobutil_readnbytes memcpy()s an empty std::vector's null data() on every input that
# consumes zero bytes (harness line 50), which halting UBSan reports as nonnull-attribute; recompile that one
# harness object with that single check relaxed (everything else keeps the full ASan+UBSan set).
relaxed_object() { # <target> <flags> -> path of the recompiled harness object
  local t="$1" flags="$2" obj="src/standalones/s_bmqfuzz/CMakeFiles/$1.dir/$1.fuzz.cpp.o" cmd
  cmd="$(ninja -C build/fuzz -t commands "$obj" | tail -1 | sed -e "s| -o $obj | -o $SRC/build/obj/$t.o |" -e 's| -MD -MT [^ ]* -MF [^ ]*||')"
  (cd build/fuzz && eval "$cmd $flags") >&2
  echo "$SRC/build/obj/$t.o"
}

link_one() { # <target>
  local t="$1" libs
  # The library list is whatever cmake would have linked into the harness executable.
  libs="$(ninja -C build/fuzz -t commands "$t" | tail -1 | sed -e "s|^.* -o [^ ]* ||" -e 's| *&& *: *$||')"
  local obj="$SRC/build/fuzz/src/standalones/s_bmqfuzz/CMakeFiles/$t.dir/$t.fuzz.cpp.o"
  case "$t" in s_bmqfuzz_bmqu_blobutil_readnbytes) obj="$(relaxed_object "$t" -fno-sanitize=nonnull-attribute)";; esac
  (cd build/fuzz && $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -m64 "$obj" "$SRC/build/obj/lsan_off.o" $libs $LIB_FUZZING_ENGINE -o "/mayhem/$t") &&
  (cd build/fuzz && $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -m64 "$obj" "$SRC/build/obj/lsan_off.o" "$SRC/build/obj/standalone_main.o" \
      $([ -n "$SANITIZER_FLAGS" ] || echo "$SRC/build/obj/sancov_stub.o") $libs -o "/mayhem/$t-standalone")
}
export -f link_one relaxed_object
export SRC
printf '%s\n' $TARGETS | xargs -P "$(( MAYHEM_JOBS < 4 ? MAYHEM_JOBS : 4 ))" -I{} bash -c 'link_one {}'

# 3) The unit-test suite, with the project's NORMAL flags, in its own tree (test.sh only runs it).
TESTS="bmqt_uri bmqp_crc32c bmqu_stringutil bmqeval_simpleevaluator bmqp_ackmessageiterator bmqp_messageproperties
       bmqp_protocolutil bmqp_putmessageiterator bmqp_optionutil bmqu_blobiterator"
# The test build keeps upstream's own Debug-build level (SAFE), as its CI does.
configure build/test SAFE "-fPIC $COVERAGE_FLAGS" -DINSTALL_TARGETS="bmq;mqb"
ninja -C build/test -j"$MAYHEM_JOBS" $(for t in $TESTS; do echo "$t.t"; done)
