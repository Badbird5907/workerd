#!/usr/bin/env bash
#
# Local dev helper: build workerd.exe on Windows with the pinned LLVM 19 toolchain.
#
# This captures the environment and flags needed to build this fork on Windows.
# It is NOT an upstream-supported build path -- it works around several issues that
# come up when building with clang-cl 19 + MSVC BuildTools from a Git-bash shell:
#
#   * tclsh: SQLite's build generates opcodes via `tclsh`, which ships with Git for
#     Windows in mingw64/bin but is dropped from bazel's default genrule PATH. We
#     forward a PATH (via --action_env) that includes it (plus the compiler/linker
#     dirs so compile/link actions are unaffected).
#   * clang-cl optimizer crash: clang-cl 19 segfaults optimizing workerd's KJ
#     coroutine code at -c opt (e.g. startEgressListener). We build src/workerd/ with
#     /Od (optimization off) while V8/external stay optimized. workerd's own code is
#     therefore unoptimized -- fine for dev.
#   * ~/.cargo/config leakage: rules_rust refuses an inherited cargo config found in a
#     parent of its temp splice workspace. We point temp + CARGO_HOME off the home
#     drive so cargo's parent-dir search doesn't find ~/.cargo/config.
#   * The /std:c++latest flag for clang-cl is set in .bazelrc (committed separately);
#     upstream's /std:c++23preview is ignored by clang-cl 19.
#
# Usage:
#   bash build-windows.sh                       # builds //src/workerd/server:workerd
#   bash build-windows.sh //some/other:target   # builds a different target
#   bash build-windows.sh //t:t --verbose_failures   # extra args are passed to bazel
#
# Override any of the paths below by exporting the matching variable before running.

set -euo pipefail

# --- Toolchain locations (Windows-style paths; override via env if yours differ) ---
: "${BAZEL_LLVM:=C:\\Program Files\\LLVM}"
: "${BAZEL_SH:=C:\\Program Files\\Git\\usr\\bin\\bash.exe}"
: "${BAZEL_VC:=C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC}"
: "${BAZEL_WINSDK_FULL_VERSION:=10.0.26100.0}"
export BAZEL_LLVM BAZEL_SH BAZEL_VC BAZEL_WINSDK_FULL_VERSION

# --- Temp + CARGO_HOME off the home drive (see cargo note above) ---
: "${WORKERD_BAZEL_TMP:=D:\\bazeltmp}"
export TMP="$WORKERD_BAZEL_TMP" TEMP="$WORKERD_BAZEL_TMP" TMPDIR="$WORKERD_BAZEL_TMP"
export CARGO_HOME="${WORKERD_BAZEL_TMP}\\cargohome"
if command -v cygpath >/dev/null 2>&1; then
	mkdir -p "$(cygpath -u "$WORKERD_BAZEL_TMP")/cargohome"
fi

# --- Detect the installed MSVC toolset version (latest under VC/Tools/MSVC) ---
msvc_ver=""
if command -v cygpath >/dev/null 2>&1; then
	msvc_tools_root="$(cygpath -u "$BAZEL_VC")/Tools/MSVC"
	if [ -d "$msvc_tools_root" ]; then
		msvc_ver="$(ls "$msvc_tools_root" 2>/dev/null | sort -V | tail -1)"
	fi
fi
if [ -z "$msvc_ver" ]; then
	echo "warning: could not detect MSVC toolset under $BAZEL_VC\\Tools\\MSVC" >&2
fi

# --- PATH forwarded to bazel actions so genrules find tclsh (Git mingw64/bin).
# Includes the compiler/linker/SDK dirs too so it can't disturb compile/link actions. ---
git_root="C:\\Program Files\\Git"
action_path="${BAZEL_LLVM}\\bin"
if [ -n "$msvc_ver" ]; then
	action_path="${action_path};${BAZEL_VC}\\Tools\\MSVC\\${msvc_ver}\\bin\\Hostx64\\x64"
fi
action_path="${action_path};C:\\Program Files (x86)\\Windows Kits\\10\\bin\\${BAZEL_WINSDK_FULL_VERSION}\\x64"
action_path="${action_path};${git_root}\\mingw64\\bin;${git_root}\\usr\\bin;${git_root}\\bin"
action_path="${action_path};C:\\Windows\\System32;C:\\Windows"

# --- Locate bazel/bazelisk ---
if [ -n "${WORKERD_BAZEL:-}" ]; then
	bazel_bin="$WORKERD_BAZEL"
elif command -v bazelisk >/dev/null 2>&1; then
	bazel_bin="bazelisk"
elif command -v bazel >/dev/null 2>&1; then
	bazel_bin="bazel"
else
	bazel_bin="${LOCALAPPDATA}/Microsoft/WinGet/Links/bazelisk.exe"
fi

target="${1:-//src/workerd/server:workerd}"
shift || true

echo "Building ${target} with:"
echo "  bazel : ${bazel_bin}"
echo "  LLVM  : ${BAZEL_LLVM}"
echo "  MSVC  : ${BAZEL_VC} (toolset ${msvc_ver:-unknown})"
echo "  WinSDK: ${BAZEL_WINSDK_FULL_VERSION}"
echo "  tmp   : ${WORKERD_BAZEL_TMP}"
echo

"$bazel_bin" build "$target" \
	-c opt \
	--action_env=PATH="$action_path" \
	--per_file_copt='src/workerd/@/Od' \
	"$@"

echo
echo "Done. Binary: bazel-bin/src/workerd/server/workerd.exe"
echo "Point Miniflare at it with:"
echo "  export MINIFLARE_WORKERD_PATH=\"\$(pwd)/bazel-bin/src/workerd/server/workerd.exe\""
