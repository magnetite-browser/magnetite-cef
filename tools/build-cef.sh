#!/usr/bin/env bash
# Builds CEF's minimal binary distribution from source, with the H.264, AAC
# and HEVC decoders the official builds leave out, for the machine it runs on:
# macOS on Apple silicon (macosarm64) or Linux on x86_64 (linux64).
#
#   local                   check out or update the tree, build, distrib
#   publish-local           create the release from this machine
#   release-state           is the release made already (a re-run)?
#   publish                 create the release with every platform's archive
#
# An untested experiment: with CEF_TARGET=windows64 on Linux, `local` builds
# for Windows on x86_64 (windows64) instead, in a tree of its own
# (README, "Windows, built on Linux"). It has three stages of its own:
#
#   win-toolchain           on Windows: package Visual Studio and the SDK
#   win-toolchain-unpack    on Linux: take that package into the tree's folder
#   win-check               on Windows: does the archive's libcef.dll load?
#
# .github/workflows/build-windows.yml runs them; it releases nothing.
#
# .github/workflows/build.yml runs `local` on our own runners, one per
# platform, and the last two in its publish job. On a machine of your own, `local` and `publish-local`
# do the same without the workflow (README, "Building on a machine of our
# own").
#
# Settings come from the environment: CEF_VERSION (required), CEF_REVISION,
# DEPOT_TOOLS_COMMIT, CEF_WORK for the folder to build in (default ~/cef, for
# CEF_TARGET=windows64 ~/cef-windows64) and CEF_FRESH=true to delete that
# folder first.
# Written for bash 3.2, the bash of macOS.
#
# Based on OpenArch's scripts/cef-codecs.sh
# (https://github.com/dpfaffenbauer/OpenArch), Copyright (c) 2026 Dominik
# Pfaffenbauer, MIT licence: LICENSES/OpenArch-MIT.txt.
set -euo pipefail

CEF_VERSION="${CEF_VERSION:?CEF_VERSION is required}"
# 156.0.26+g8ea0c73+chromium-156.0.8078.88, as in Magnetite's Cargo.lock.
if [[ ! "$CEF_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+g[0-9a-f]{7,}\+chromium-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::error::CEF_VERSION is not a full CEF version (156.0.26+g8ea0c73+chromium-156.0.8078.88): $CEF_VERSION" >&2
  exit 1
fi
SHORT_VERSION="${CEF_VERSION%%+*}"             # 156.0.26
# The Chromium version to build with. It is the one the CEF commit names
# (CHROMIUM_BUILD_COMPATIBILITY.txt) or a later one of the same branch: a
# Chromium security release that CEF has not followed yet.
CHROMIUM_VERSION="${CEF_VERSION##*+chromium-}" # 156.0.8078.88
# CEF names its release branches after Chromium's build number (8078) ...
CEF_BRANCH="$(echo "$CHROMIUM_VERSION" | cut -d. -f3)"
# ... and its versions after the commit ("+gcf671c0+").
commit="${CEF_VERSION#*+g}"
CEF_COMMIT="${commit%%+*}"

# depot_tools: the commit the CEF version's CHROMIUM_BUILD_COMPATIBILITY.txt
# names as depot_tools_checkout (automate-git.py leaves it to us with
# --no-depot-tools-update). For a version that names none, pick one on
# purpose (git ls-remote https://chromium.googlesource.com/chromium/tools/depot_tools.git main).
# The release notes record it.
DEPOT_TOOLS_COMMIT="${DEPOT_TOOLS_COMMIT:-132599ebbd8d22d1b1bd5ea703a6d3bc493edd71}"

# What differs between the platforms:
#   ARCH         CEF's name for the architecture: automate-git.py's and
#                make_distrib.py's --<arch>-build, out/Release_GN_<arch>
#   PLATFORM     the archive's platform name
#   TARGETS      what ninja builds; make_distrib.py takes the files from them
#   PLATFORM_GN  GN args of CEF's official builds for the platform
#                (AutomatedBuildSetup in CEF's wiki): on Linux, Chromium's
#                Debian sysroot instead of the host's libraries, and no CFI.
OS="$(uname -s)"
CEF_TARGET="${CEF_TARGET:-}"
case "$OS-$(uname -m):$CEF_TARGET" in
  Darwin-arm64:)
    ARCH=arm64 PLATFORM=macosarm64 TARGETS=cefclient PLATFORM_GN=""
    ;;
  Linux-x86_64:)
    # Not cefclient: it needs GTK's headers, which CEF leaves out with
    # use_sysroot=true, and the distribution takes nothing from it.
    ARCH=x64 PLATFORM=linux64 TARGETS="libcef chrome_sandbox"
    PLATFORM_GN="use_sysroot=true is_cfi=false"
    ;;
  # The experiment. On Linux the build; under Git Bash on Windows only
  # win-toolchain and win-check.
  Linux-x86_64:windows64 | MINGW*-x86_64:windows64)
    # The targets of CEF's official builds (automate-git.py).
    ARCH=x64 PLATFORM=windows64 TARGETS="cefclient bootstrap bootstrapc"
    # Chromium's cross build (docs/win_cross.md). Its tools for the build
    # machine use the Debian sysroot, GN's default.
    PLATFORM_GN="target_os=win"
    # CEF's tools take the platform from the machine they run on; with
    # patches/cross/ they take it from here.
    export MAGNETITE_TARGET_PLATFORM=windows
    # The Windows SDK that Chromium's build/vs_toolchain.py asks for
    # (SDK_VERSION) and GitHub's Windows image lacks: Microsoft's installer
    # for it, as winget's Microsoft.WindowsSDK.10.0.28000 names it.
    WIN_SDK_VERSION=10.0.28000.0
    WIN_SDK_URL=https://download.microsoft.com/download/e6cfffdc-0d3e-4c6c-96d7-d491da459a07/KIT_BUNDLE_WINDOWSSDK_MEDIACREATION/winsdksetup.exe
    WIN_SDK_SHA256=e8e264aca8bc34abdf592352bf09f986a85cdb96db0efba405ca9e149181fe61
    ;;
  *)
    echo "::error::This builds CEF on macOS on Apple silicon or Linux on x86_64 (with CEF_TARGET=windows64: for Windows), not $OS $(uname -m) with CEF_TARGET='$CEF_TARGET'." >&2
    exit 1
    ;;
esac

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# The tree: depot_tools, Chromium with CEF in it, and the build output. It
# stays between builds, so the next one only does what changed.
WORK="${CEF_WORK:-$HOME/cef${CEF_TARGET:+-$CEF_TARGET}}"
# Git Bash gets the runner's folders as Windows paths; tar takes "D:" for a
# machine's name.
if [[ "$OS" == MINGW* && -n "${RUNNER_TEMP:-}" ]]; then
  RUNNER_TEMP="$(cygpath -u "$RUNNER_TEMP")"
fi
# The cross build's Visual Studio and Windows SDK, packaged by win-toolchain:
# <the toolchain Chromium asks for>/<the package's hash>.zip. Next to the
# tree, so CEF_FRESH leaves it.
WIN_TOOLCHAIN="$WORK-toolchain"
# patches/ and, for a cross build, the changes to CEF's tools on top.
PATCHES=("$REPO_DIR"/patches/*.patch)
if [[ -n "$CEF_TARGET" ]]; then PATCHES+=("$REPO_DIR"/patches/cross/*.patch); fi
SRC="$WORK/chromium/src"
OUT="$SRC/out/Release_GN_$ARCH"
NINJA="$SRC/third_party/ninja/ninja"
# In a workflow job the runner's temp folder, which the next step uploads
# from; otherwise next to the tree (/tmp is emptied on restart). Each
# platform's files go into a folder of their own in it (DIST_DIR/PLATFORM),
# so the publish job can hold all of them.
DIST_DIR="${RUNNER_TEMP:-$WORK}/cef-distrib"
DIST_NAME="cef_binary_${CEF_VERSION}_${PLATFORM}_minimal"
# A release is never replaced: another build of a version is a revision of it.
CEF_REVISION="${CEF_REVISION:-}"
if [[ -n "$CEF_REVISION" && ! "$CEF_REVISION" =~ ^([2-9]|[1-9][0-9]+)$ ]]; then
  echo "::error::The revision must be empty or a number from 2: $CEF_REVISION" >&2
  exit 1
fi
RELEASE_TAG="$SHORT_VERSION${CEF_REVISION:+-$CEF_REVISION}"

# For the stages that build: depot_tools first on PATH, no self-updates.
# Never for the ones that call gh with a token.
use_depot_tools() {
  export PATH="$WORK/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0
}

# sha256sum on Linux, shasum on macOS; each one's -c reads what the other wrote.
sha256() {
  if command -v sha256sum > /dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

# Free GB on the disk that holds $1.
free_gb() {
  df -Pk "$1" | awk 'NR == 2 { print int($4 / 1048576) }'
}

host_os() {
  if [[ "$OS" == Darwin ]]; then
    echo "macOS $(sw_vers -productVersion)"
  else
    # shellcheck disable=SC1091
    (. /etc/os-release && echo "$PRETTY_NAME, Linux $(uname -r)")
  fi
}

output() {
  echo "$1"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$1" >> "$GITHUB_OUTPUT"; fi
}

fail() {
  echo "::error::$*" >&2
  exit 1
}

disk() {
  df -h "$WORK" | awk 'NR == 2 { print $4 " free of " $2 }'
}

# The GN args on top of what CEF sets itself (tools/gn_args.py).
#   proprietary_codecs, ffmpeg_branding  H.264, AAC and HEVC; the point of it.
#                                        With them Chromium also builds the
#                                        OpenH264 encoder (media_use_openh264,
#                                        rtc_use_h264), which WebRTC needs to
#                                        send H.264 at all: without it, it
#                                        does not offer the hardware encoder
#                                        either (seen: a screen shared in a
#                                        Microsoft Teams call did not arrive).
#   symbol_level=0                       no debug symbols: a smaller tree.
#   treat_warnings_as_errors=false       a newer macOS SDK than Chromium was
#                                        tested with must not stop the build.
# And the platform's own, PLATFORM_GN.
gn_defines() {
  echo "is_official_build=true proprietary_codecs=true ffmpeg_branding=Chrome" \
    "symbol_level=0 treat_warnings_as_errors=false $PLATFORM_GN"
}

# The GN args the release must have, as `gn args --short` prints them.
EXPECTED_ARGS='proprietary_codecs = true
ffmpeg_branding = "Chrome"
media_use_openh264 = true
rtc_use_h264 = true'

# Brings the tree in WORK to CEF_VERSION with patches/ applied, and
# configures it. The first time that is a full checkout of Chromium with its
# git history, which an update needs. After that it is an update in place:
# git rewrites only the files that differ between the versions, and ninja
# builds only what depends on them.
sync() {
  echo "CEF $CEF_VERSION: branch $CEF_BRANCH, commit $CEF_COMMIT"
  mkdir -p "$WORK"
  # From here to the end the tree is in no state to build from.
  rm -f "$WORK/patches-applied"
  # The commit's own checkout tool, not the branch's newest.
  curl -fsSL -o "$WORK/automate-git.orig.py" \
    "https://raw.githubusercontent.com/chromiumembedded/cef/$CEF_COMMIT/tools/automate/automate-git.py"
  # In an update in place the tool applies CEF's runhooks patch for the hooks
  # and then once more with all the others, which stops it as "already
  # applied" (issue #6). Take the patch back in between.
  local hooks='  run("gclient runhooks", chromium_dir)'
  [[ "$(grep -cxF -- "$hooks" "$WORK/automate-git.orig.py")" == 1 ]] ||
    fail "automate-git.py has changed: no single line '$hooks' to fix it at (issue #6)"
  # A cross build's .gclient also names the platform it is for, so gclient
  # fetches what a build for Windows needs (Chromium's docs/win_cross.md).
  # The tool writes the file once, with the first checkout.
  local gclient='      "}]"'
  [[ -z "$CEF_TARGET" || "$(grep -cxF -- "$gclient" "$WORK/automate-git.orig.py")" == 1 ]] ||
    fail "automate-git.py has changed: no single line '$gclient' to end .gclient at"
  GCLIENT_END="      \"}]\\ntarget_os = ['win']\"" awk -v hooks="$hooks" \
    -v gclient="$gclient" -v cross="$CEF_TARGET" '
    cross != "" && $0 == gclient { print ENVIRON["GCLIENT_END"]; next }
    { print }
    $0 == hooks {
      print "  if cef_dir == cef_src_dir:"
      print "    run_patch_updater(\"--revert --patch runhooks\")"
    }' "$WORK/automate-git.orig.py" > "$WORK/automate-git.py"
  # depot_tools, set up as update_depot_tools would (its packages and
  # Python), without moving it (its scripts do not run under `set -u`).
  get_depot_tools
  (
    set +u
    cd "$WORK/depot_tools"
    # shellcheck disable=SC1091
    source ./cipd_bin_setup.sh
    cipd_bin_setup > /dev/null
    # shellcheck disable=SC1091
    source ./bootstrap_python3
    bootstrap_python3
  )
  use_depot_tools
  if [[ -n "$CEF_TARGET" ]]; then
    # Chromium's hooks unpack the toolchain; the tree may still be another
    # version's, or not there.
    fetch_vs_toolchain
    use_win_toolchain "$WORK/vs_toolchain.py"
  fi

  # Our own changes to Chromium come out first: the magnetite_* patches that
  # patches/ adds to CEF's list. CEF's tool takes out the patches of CEF's
  # list as git has it, which the reset below brings back, so ours would stay
  # in Chromium through the update. A file that CEF patches as well is then
  # restored and the others are not, and putting the patch back fails as
  # neither applied nor missing. Only our own hunks are taken back, file by
  # file: a file may carry CEF's changes too, and after a build that stopped
  # a patch may be there in part. A hunk that is there and does not come out
  # stops the build.
  if [[ -d "$SRC/cef" ]]; then
    local ours file
    for ours in "$SRC"/cef/patch/patches/magnetite_*.patch; do
      [[ -f "$ours" ]] || continue
      echo "Taking $(basename "$ours") out of Chromium"
      sed -n 's|^+++ ||p' "$ours" | while IFS= read -r file; do
        # Not there is fine; there but not coming out (a full disk, a file
        # that cannot be written) is not: nothing later would find it.
        if git -C "$SRC" apply -p0 -R --ignore-whitespace --check --include="$file" "$ours" 2> /dev/null; then
          git -C "$SRC" apply -p0 -R --ignore-whitespace --include="$file" "$ours" ||
            fail "$(basename "$ours") does not come out of $file: see git's message above (disk space, the file's permissions), then run the build again; if that does not help, run it with \"fresh\"."
        else
          echo "  $file: not in it, left as it is"
        fi
      done
    done
  fi

  # The update below wants CEF's files as git has them: take the last
  # build's patches/ out again.
  if [[ -d "$SRC/cef" ]]; then
    git -C "$SRC/cef" reset --quiet --hard
    git -C "$SRC/cef" clean --quiet -fd
  fi

  # CEF's checkout tool: CEF at the commit, Chromium at CHROMIUM_VERSION,
  # Chromium's hooks (clang, rust ...) and the PGO profiles official builds
  # optimise with. For a Chromium version other than the one CEF names, the
  # tool puts CEF's patches onto it and stops when one does not apply; CEF
  # then has to follow first. With --fast-update it
  # moves an existing tree to the version: it takes CEF's patches out of
  # Chromium, checks out, puts them back, and restores every patched file
  # that came out the same, so ninja does not build it again. It keeps the
  # build output while CEF's branch (Chromium's build number) is the same and
  # drops it for a new one. It would also build; that is done by build.
  python3 "$WORK/automate-git.py" --download-dir="$WORK" \
    --depot-tools-dir="$WORK/depot_tools" --branch="$CEF_BRANCH" \
    --checkout="$CEF_COMMIT" --chromium-checkout="refs/tags/$CHROMIUM_VERSION" \
    --with-pgo-profiles --fast-update \
    --no-depot-tools-update "--$ARCH-build" --no-debug-build --no-build --no-distrib
  # The first checkout clones CEF there and copies it to src/cef; build
  # output of other branches is parked there.
  rm -rf "$WORK/cef" "$WORK"/out_*
  [[ -z "$CEF_TARGET" ]] || grep -q target_os "$WORK/chromium/.gclient" ||
    fail "$WORK/chromium/.gclient names no target_os: the tree was not checked out for a cross build. Build with CEF_FRESH=true."

  # The version is computed from git, as make_distrib.py will do; it names
  # the archive, so a mismatch is better found now than after the build.
  local actual
  actual="$(python3 "$SRC/cef/tools/cef_version.py" current)"
  [[ "$actual" == "$CEF_VERSION" ]] || fail "The checkout is CEF $actual, not $CEF_VERSION."
  # The Chromium version CEF made the commit for, for the release notes.
  sed -n "s|.*'chromium_checkout': 'refs/tags/\(.*\)'.*|\1|p" \
    "$SRC/cef/CHROMIUM_BUILD_COMPATIBILITY.txt" > "$WORK/cef-chromium-version"
  [[ -s "$WORK/cef-chromium-version" ]] || fail "No chromium_checkout in CEF's CHROMIUM_BUILD_COMPATIBILITY.txt."

  # Magnetite's own changes to CEF (patches/, see the README), before CEF's
  # files are translated and configured. They change no commit, so the
  # version stays the one checked above.
  local patch
  for patch in "${PATCHES[@]}"; do
    echo "Applying $(basename "$patch")"
    git -C "$SRC/cef" apply "$patch" || fail "$(basename "$patch") does not apply to CEF $CEF_VERSION."
  done

  # What automate-git.py does before it builds: translate CEF's API files,
  # apply CEF's patches to Chromium (those already there are skipped), write
  # args.gn and run gn gen. Only the Release configuration of this machine's
  # architecture. On Linux it also installs the sysroot (CEF_INSTALL_SYSROOT);
  # without it, gn_args.py has no configuration to generate.
  (cd "$SRC/cef" && GN_DEFINES="$(gn_defines)" GN_OUT_CONFIGS="Release_GN_$ARCH" \
    CEF_ENABLE_ARM64=1 CEF_INSTALL_SYSROOT="$ARCH" python3 tools/gclient_hook.py)
  cat "$OUT/args.gn"
  check_args

  patches_hash > "$WORK/patches-applied"
  echo "Disk: $(disk)"
}

# One hash over PATCHES and the GN args: what a tree was made and configured
# with. A tree kept from a build with other args is configured again.
patches_hash() {
  { cat "${PATCHES[@]}" && gn_defines; } | sha256 | cut -d' ' -f1
}

# depot_tools in WORK at DEPOT_TOOLS_COMMIT.
get_depot_tools() {
  if [[ ! -d "$WORK/depot_tools" ]]; then
    git clone --quiet https://chromium.googlesource.com/chromium/tools/depot_tools.git "$WORK/depot_tools"
  else
    git -C "$WORK/depot_tools" fetch --quiet origin
  fi
  git -C "$WORK/depot_tools" checkout --quiet "$DEPOT_TOOLS_COMMIT"
}

# Downloads the Chromium version's build/vs_toolchain.py to WORK: it names
# the Visual Studio and Windows SDK Chromium wants, before there is a tree.
fetch_vs_toolchain() {
  mkdir -p "$WORK"
  curl -fsSL "https://chromium.googlesource.com/chromium/src/+/refs/tags/$CHROMIUM_VERSION/build/vs_toolchain.py?format=TEXT" |
    base64 -d > "$WORK/vs_toolchain.py"
}

# Prints what a vs_toolchain.py ($2) sets $1 to: TOOLCHAIN_HASH = '3bfcb536c8'.
vs_toolchain_value() {
  sed -n "s/^$1 = '\(.*\)'$/\1/p" "$2"
}

# Points Chromium's hooks and GN at our package of Visual Studio and the
# Windows SDK instead of Google's own, which only Google can download
# (docs/win_cross.md, "If you're not at Google"). $1 is the vs_toolchain.py
# that names the toolchain Chromium wants.
use_win_toolchain() {
  local wanted zips
  wanted="$(vs_toolchain_value TOOLCHAIN_HASH "$1")"
  [[ -n "$wanted" ]] || fail "$1 names no TOOLCHAIN_HASH."
  zips=("$WIN_TOOLCHAIN/$wanted"/*.zip)
  [[ -f "${zips[0]}" ]] ||
    fail "No package of Visual Studio for Chromium's toolchain $wanted in $WIN_TOOLCHAIN. Run the workflow with \"toolchain\" ticked."
  export DEPOT_TOOLS_WIN_TOOLCHAIN=1 DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL="$WIN_TOOLCHAIN/$wanted"
  export "GYP_MSVS_HASH_$wanted=$(basename "${zips[0]}" .zip)"
}

# Fails unless GN resolved the codec args as EXPECTED_ARGS says.
check_args() {
  local actual
  actual="$(cd "$SRC" && for arg in proprietary_codecs ffmpeg_branding media_use_openh264 rtc_use_h264; do
    gn args "$OUT" --short --list="$arg"
  done)"
  echo "$actual"
  [[ "$actual" == "$EXPECTED_ARGS" ]] ||
    fail "GN resolved the codec args differently (above); expected: $(echo "$EXPECTED_ARGS" | tr '\n' ';')"
  [[ -z "$CEF_TARGET" || "$(cd "$SRC" && gn args "$OUT" --short --list=target_os)" == 'target_os = "win"' ]] ||
    fail "GN did not configure a build for Windows."
}

# Builds TARGETS, which make_distrib.py takes the files from. Ninja
# builds only what is out of date, so after an interruption it carries on
# where it stopped.
build() {
  use_depot_tools
  # Scripts the build starts as `env python3` (the linker driver) get
  # Chromium's own Python. /usr/bin/python3 asks xcodebuild for one, and
  # Xcode 27 rejects the SDK link that rustc passes it in SDKROOT.
  export PATH="$SRC/third_party/cpython3/host/bin:$PATH"
  if [[ -n "$CEF_TARGET" ]]; then
    use_win_toolchain "$SRC/build/vs_toolchain.py"
    # The toolchain is in a folder that ignores case (ciopfs, a FUSE mount),
    # as the SDK's headers need; a restart unmounts it. This mounts it again
    # and unpacks nothing that is there.
    (cd "$SRC" && python3 build/vs_toolchain.py update --force)
  fi
  # shellcheck disable=SC2086 # TARGETS is a list
  NINJA_STATUS="[%p %f/%t %e] " "$NINJA" -C "$OUT" -j "$(getconf _NPROCESSORS_ONLN)" $TARGETS ||
    fail "ninja failed with exit code $?."
  echo "Disk: $(disk)"
}

# Makes the minimal distribution, the kind Magnetite's build otherwise
# downloads from CEF's CDN, and puts it with its SHA-256 and the build's
# args.gn into DIST_DIR/PLATFORM.
distrib() {
  use_depot_tools
  local out="$WORK/distrib" dist="$DIST_DIR/$PLATFORM"
  rm -rf "$out" "$dist"
  mkdir -p "$out" "$dist"
  # The folder only: the archive is made below, once the patch list is in.
  (cd "$SRC/cef/tools" && python3 make_distrib.py --output-dir="$out" --ninja-build \
    "--$ARCH-build" --minimal --no-symbols --no-docs --no-archive)
  [[ -d "$out/$DIST_NAME/Release" ]] || fail "Expected $DIST_NAME/Release, got: $(ls "$out")"
  # Which of our patches this build has, one file name a line, next to the
  # library: Magnetite reads from it what its CEF can do (Wayland).
  (cd "$REPO_DIR/patches" && ls -- *.patch) > "$out/$DIST_NAME/Release/magnetite-patches.txt"
  # COPYFILE_DISABLE: no ._ files from macOS' tar.
  COPYFILE_DISABLE=1 tar -C "$out" -cjf "$out/$DIST_NAME.tar.bz2" "$DIST_NAME"
  mv "$out/$DIST_NAME.tar.bz2" "$dist/"
  (cd "$dist" && sha256 "$DIST_NAME.tar.bz2" > "$DIST_NAME.tar.bz2.sha256")
  cp "$OUT/args.gn" "$dist/args.gn"
  # What else went into it, for the release notes.
  {
    echo "depot_tools $(git -C "$WORK/depot_tools" rev-parse HEAD)"
    if [[ "$(cat "$WORK/cef-chromium-version")" != "$CHROMIUM_VERSION" ]]; then
      echo "Chromium $CHROMIUM_VERSION; CEF $SHORT_VERSION was made for $(cat "$WORK/cef-chromium-version")"
    fi
    if [[ "$OS" == Darwin ]]; then
      tr '\n' ' ' < "$WORK/xcode-version"
      echo
    fi
    if [[ -n "$CEF_TARGET" ]]; then
      echo "built on Linux with Visual Studio and Windows SDK package $(basename "$WIN_TOOLCHAIN"/*/*.zip .zip)"
    fi
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
      echo "runner: our own, $(host_os)"
    else
      echo "machine: our own, $(host_os)"
    fi
  } > "$dist/build-info.txt"
  cat "$dist/build-info.txt" "$dist/$DIST_NAME.tar.bz2.sha256"
  ls -lh "$dist"
}

# Sets ARCHIVES to the archives in DIST_DIR, one per platform folder.
find_archives() {
  local archive
  ARCHIVES=""
  for archive in "$DIST_DIR"/*/cef_binary_*_minimal.tar.bz2; do
    if [[ -f "$archive" ]]; then ARCHIVES="$ARCHIVES $archive"; fi
  done
  [[ -n "$ARCHIVES" ]] || fail "No distribution in $DIST_DIR."
}

# Sets the step output "state": "new" when RELEASE_TAG has no release yet,
# "published" when it holds these very files (a re-run after the release
# was made). A release with other files is an error: releases are never
# replaced, since Magnetite pins the archives' hashes.
release_state() {
  local assets archive name
  find_archives
  if ! assets="$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$RELEASE_TAG" \
    --jq '.assets[] | .name + " " + .digest' 2> /dev/null)"; then
    # No release; a tag of that name would be taken as it is, wherever it
    # points.
    if gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/$RELEASE_TAG" > /dev/null 2>&1; then
      fail "Tag $RELEASE_TAG exists without a release. Build it again as a new revision."
    fi
    output state=new
    return
  fi
  for archive in $ARCHIVES; do
    name="$(basename "$archive")"
    grep -qxF "$name sha256:$(cut -d' ' -f1 "$archive.sha256")" <<< "$assets" ||
      fail "Release $RELEASE_TAG exists without this $name. Build it again as a new revision."
  done
  output state=published
}

# Is the tree in WORK this version with these patches, configured? Then
# there is nothing to check out, only to build.
tree_is_current() {
  [[ -f "$OUT/args.gn" ]] || return 1
  [[ "$(cat "$WORK/patches-applied" 2> /dev/null)" == "$(patches_hash)" ]] || return 1
  [[ "$(use_depot_tools && python3 "$SRC/cef/tools/cef_version.py" current)" == "$CEF_VERSION" ]]
}

# The whole build: checks out or updates the tree unless it is this version
# already, builds and makes the distribution. Run again after an
# interruption, it carries on where it stopped.
local_build() {
  [[ "$OS" != MINGW* ]] || fail "The build for Windows runs on Linux; Windows does win-toolchain and win-check."
  if [[ -n "$CEF_TARGET" ]]; then
    # Chromium mounts the Windows SDK with ciopfs, which it brings along.
    command -v fusermount > /dev/null || fail "fusermount is missing (the package fuse, FUSE 2)."
  fi
  if [[ "$OS" == Darwin ]]; then
    # ANGLE compiles its Metal shaders with it; from Xcode 27 on it is a
    # download of its own, and the build fails hours in without it.
    xcrun -f metal > /dev/null 2>&1 ||
      fail "Xcode's Metal toolchain is missing. Get it with: xcodebuild -downloadComponent MetalToolchain"
  else
    # Chromium's pkg-config wrapper runs the host's on the sysroot.
    command -v pkg-config > /dev/null || fail "pkg-config is missing (the package pkgconf or pkg-config)."
  fi
  if [[ "${CEF_FRESH:-}" == true ]]; then
    # A cross build leaves the Windows SDK mounted in the tree (ciopfs, in
    # the depot_tools Chromium brings along), which rm cannot delete.
    # Looked for in its parent's listing: a mount whose ciopfs died cannot be
    # looked at itself, but is listed. (Read whole first: grep -q stopping
    # early would fail the pipe.)
    local sdk="$SRC/third_party/depot_tools/win_toolchain/vs_files" mounted=0 listing=""
    if [[ -n "$CEF_TARGET" && -d "$(dirname "$sdk")" ]]; then
      listing="$(ls -A "$(dirname "$sdk")")" ||
        fail "Cannot list $(dirname "$sdk") to look for the Windows SDK's mount. Make it readable or unmount the SDK (fusermount -u $sdk), then build with CEF_FRESH=true again."
    fi
    if grep -qxF vs_files <<< "$listing"; then
      # 0 mounted, 32 not; anything else (no mountpoint, a dead mount) is
      # no answer, and rm would delete the SDK through the mount.
      mountpoint -q "$sdk" || mounted=$?
      case "$mounted" in
        0)
          fusermount -u "$sdk" ||
            fail "Cannot unmount the Windows SDK at $sdk. Stop what uses it (fuser -m $sdk) or restart the machine, then build with CEF_FRESH=true again."
          ;;
        32) ;;
        *) fail "Cannot tell whether the Windows SDK is mounted at $sdk (mountpoint, of util-linux, exited with $mounted). Unmount it (fusermount -u $sdk) or restart the machine, then build with CEF_FRESH=true again." ;;
      esac
    fi
    echo "Deleting $WORK"
    rm -rf "${WORK:?}"
  fi
  mkdir -p "$WORK"
  local free
  if [[ ! -e "$WORK/chromium" && ! -e "$WORK/depot_tools" ]]; then
    free="$(free_gb "$WORK")"
    ((free >= 200)) || fail "Only $free GB free at $WORK; the tree needs about 200."
  elif [[ ! -d "$SRC/cef" ]]; then
    fail "$WORK holds a checkout that never finished. Build with CEF_FRESH=true (the workflow's \"fresh\") to start over."
  elif [[ "$(git -C "$SRC" rev-parse --is-shallow-repository)" == true ]]; then
    fail "The tree in $WORK has no git history (an older version of this script made it) and cannot be updated. Build with CEF_FRESH=true (the workflow's \"fresh\")."
  fi
  if [[ "$OS" == Darwin ]]; then
    # The compile commands name the SDK's path, not its version: ninja would
    # not notice another Xcode and mix two SDKs in one build.
    if [[ -f "$WORK/xcode-version" && "$(xcodebuild -version)" != "$(cat "$WORK/xcode-version")" ]]; then
      echo "Xcode changed since the last build: building everything again."
      rm -rf "$SRC/out"
    fi
    xcodebuild -version > "$WORK/xcode-version"
  fi

  if tree_is_current; then
    echo "The tree in $WORK is CEF $CEF_VERSION already"
  else
    sync
  fi
  build
  distrib
  echo "Made $DIST_DIR/$PLATFORM/$DIST_NAME.tar.bz2."
}

# On Windows with Visual Studio 2026 (GitHub's runner): packages it and the
# Windows SDK Chromium asks for, as Chromium's docs/win_cross.md says, and
# encrypts the package with WIN_TOOLCHAIN_KEY into
# RUNNER_TEMP/win-toolchain/<the toolchain Chromium asks for>/. Encrypted,
# because the workflow hands it to the Linux job as an artifact, which anyone
# can download, and Microsoft's files are not ours to give away.
win_toolchain() {
  [[ "$OS" == MINGW* ]] || fail "win-toolchain runs on Windows, under Git Bash."
  : "${WIN_TOOLCHAIN_KEY:?WIN_TOOLCHAIN_KEY is required}"
  local vs="$WORK/vs_toolchain.py" kits="/c/Program Files (x86)/Windows Kits/10" sdk wanted zips out
  local vs_path dir extra aside="$WORK/msvc-aside" status=0
  fetch_vs_toolchain
  wanted="$(vs_toolchain_value TOOLCHAIN_HASH "$vs")"
  sdk="$(vs_toolchain_value SDK_VERSION "$vs")"
  [[ -n "$wanted" ]] || fail "$vs names no TOOLCHAIN_HASH."
  [[ "$sdk" == "$WIN_SDK_VERSION" ]] ||
    fail "Chromium $CHROMIUM_VERSION wants the Windows SDK $sdk, not $WIN_SDK_VERSION: change WIN_SDK_VERSION, WIN_SDK_URL and WIN_SDK_SHA256."
  if [[ ! -d "$kits/Include/$sdk" || ! -d "$kits/Debuggers" ]]; then
    echo "Installing the Windows SDK $sdk"
    curl -fsSL -o "$WORK/winsdksetup.exe" "$WIN_SDK_URL"
    echo "$WIN_SDK_SHA256  $WORK/winsdksetup.exe" | sha256 -c
    # Every feature: the package wants the debuggers. Git Bash would turn
    # /q into a path.
    MSYS_NO_PATHCONV=1 "$WORK/winsdksetup.exe" /features + /q /norestart
  fi
  get_depot_tools
  # Writes <the package's hash>.zip next to itself. It knows one Visual
  # Studio, the one Chromium wants.
  rm -f "$WORK"/depot_tools/win_toolchain/*.zip
  # It also wants one MSVC toolset and one redistributable in that Visual
  # Studio, and GitHub's image has several: all but the newest of each wait
  # in $aside while it runs, and go back whether it worked or not.
  vs_path="$("/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe" \
    -prerelease -version '[18,19)' -property installationPath | tr -d '\r')"
  # One line, so it is the one the script takes.
  [[ -n "$vs_path" && "$vs_path" != *$'\n'* ]] ||
    fail "vswhere finds no Visual Studio 2026, or more than one: ${vs_path:-none}"
  vs_path="$(cygpath -u "$vs_path")"
  for dir in Tools redist; do
    mkdir -p "$aside/$dir"
    ls -d "$vs_path/VC/$dir/MSVC"/14.*.* | sort -V | sed '$d' | while IFS= read -r extra; do
      echo "Setting aside $extra"
      mv "$extra" "$aside/$dir/"
    done
  done
  (cd "$WORK/depot_tools/win_toolchain" &&
    python package_from_installed.py 2026 -w "$sdk" --allow_multiple_vs_installs) || status=$?
  for dir in Tools redist; do
    for extra in "$aside/$dir"/*; do
      [[ ! -d "$extra" ]] || mv "$extra" "$vs_path/VC/$dir/MSVC/" ||
        echo "::warning::$extra did not go back to $vs_path/VC/$dir/MSVC: move it by hand."
    done
  done
  [[ "$status" == 0 ]] || fail "package_from_installed.py failed ($status)."
  zips=("$WORK"/depot_tools/win_toolchain/*.zip)
  [[ -f "${zips[0]}" ]] || fail "package_from_installed.py made no zip."
  out="${RUNNER_TEMP:-$WORK}/win-toolchain/$wanted"
  rm -rf "$out"
  mkdir -p "$out"
  openssl enc -aes-256-cbc -pbkdf2 -pass env:WIN_TOOLCHAIN_KEY \
    -in "${zips[0]}" -out "$out/$(basename "${zips[0]}").enc"
  ls -lh "$out"
}

# On Linux: decrypts the package the workflow's Windows job made (downloaded
# to RUNNER_TEMP/win-toolchain) into WIN_TOOLCHAIN, in place of the one there.
win_toolchain_unpack() {
  : "${WIN_TOOLCHAIN_KEY:?WIN_TOOLCHAIN_KEY is required}"
  local enc dir
  for enc in "${RUNNER_TEMP:?}"/win-toolchain/*/*.zip.enc; do
    [[ -f "$enc" ]] || fail "No packaged toolchain in $RUNNER_TEMP/win-toolchain."
    dir="$WIN_TOOLCHAIN/$(basename "$(dirname "$enc")")"
    # Decrypted first: a wrong key must not cost the package that is there.
    openssl enc -d -aes-256-cbc -pbkdf2 -pass env:WIN_TOOLCHAIN_KEY \
      -in "$enc" -out "${enc%.enc}"
    rm -rf "$WIN_TOOLCHAIN"
    mkdir -p "$dir"
    mv "${enc%.enc}" "$dir/"
    ls -lh "$dir"
  done
}

# On Windows: the archive local made is whole, and Windows loads its
# libcef.dll (a 64-bit library whose imports all resolve). Whether CEF works
# only Magnetite shows.
win_check() {
  [[ "$OS" == MINGW* ]] || fail "win-check runs on Windows, under Git Bash."
  local dist="$DIST_DIR/$PLATFORM" out="$WORK/check"
  (cd "$dist" && sha256 -c "$DIST_NAME.tar.bz2.sha256")
  rm -rf "$out"
  mkdir -p "$out"
  tar -C "$out" -xjf "$dist/$DIST_NAME.tar.bz2"
  ls -lh "$out/$DIST_NAME/Release"
  python -c 'import ctypes, sys; ctypes.WinDLL(sys.argv[1])' \
    "$(cygpath -w "$out/$DIST_NAME/Release/libcef.dll")" ||
    fail "Windows does not load libcef.dll."
  echo "Windows loads libcef.dll."
}

# Publishes what local made, from this machine: gh must be signed in with
# write access. The release names the commit of this checkout, so that has
# to be origin's main with nothing changed.
publish_local() {
  [[ -z "${GITHUB_ACTIONS:-}" ]] || fail "publish-local is for a machine of our own."
  [[ -z "$(git -C "$REPO_DIR" status --porcelain)" ]] || fail "This checkout has changes that are not committed."
  git -C "$REPO_DIR" fetch --quiet origin main
  GITHUB_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
  [[ "$GITHUB_SHA" == "$(git -C "$REPO_DIR" rev-parse FETCH_HEAD)" ]] ||
    fail "This checkout is not at origin's main; the release would name a commit nobody can see there."
  [[ "$(cat "$WORK/patches-applied" 2> /dev/null)" == "$(patches_hash)" ]] ||
    fail "The tree in $WORK was made with other patches or build settings than this commit has. Build it again (tools/build-cef.sh local), then publish."
  GITHUB_REPOSITORY="$(cd "$REPO_DIR" && gh repo view --json nameWithOwner --jq .nameWithOwner)"
  export GH_REPO="$GITHUB_REPOSITORY"
  local state
  state="$(release_state)"
  if [[ "$state" == state=published ]]; then
    echo "Release $RELEASE_TAG holds this file already."
    return
  fi
  publish
}

# Creates the release with every platform's distribution in DIST_DIR and
# their SHA-256s: as a draft with all files, then published, so an immutable
# release is complete.
publish() {
  local notes="${RUNNER_TEMP:-/tmp}/release-notes.md" origin archive dir names files=() platforms=""
  find_archives
  for archive in $ARCHIVES; do
    (cd "$(dirname "$archive")" && sha256 -c "$(basename "$archive").sha256")
    files+=("$archive" "$archive.sha256")
    platforms="$platforms, $(basename "$(dirname "$archive")")"
  done
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    origin="- Built by $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID from $GITHUB_SHA
- Check an archive: \`gh attestation verify <archive> --repo $GITHUB_REPOSITORY --signer-workflow $GITHUB_REPOSITORY/.github/workflows/build.yml --source-ref refs/heads/main\`"
  else
    origin="- Built from $GITHUB_SHA with \`tools/build-cef.sh local\` on a machine of the Magnetite maintainers, not by the workflow, so it has no attestation. Each SHA-256 is in the file next to its archive."
  fi
  {
    echo "CEF $CEF_VERSION, the minimal distribution (${platforms#, }; macosarm64 is macOS on Apple silicon, linux64 Linux on x86_64), built from source with the H.264, AAC and HEVC decoders that the official builds leave out."
    echo
    echo "$origin"
    for archive in $ARCHIVES; do
      dir="$(dirname "$archive")"
      # shellcheck disable=SC2016 # backticks for Markdown
      printf '\n### %s\n\n```\n%s\n```\n\nargs.gn:\n\n```\n%s\n```\n' \
        "$(basename "$dir")" "$(cat "$dir/build-info.txt")" "$(cat "$dir/args.gn")"
    done
  } > "$notes"
  gh release create "$RELEASE_TAG" "${files[@]}" --draft --target "$GITHUB_SHA" \
    --title "CEF $RELEASE_TAG with H.264 and AAC" --notes-file "$notes"
  # GitHub renames some characters in asset names; "+" must survive. (Read
  # whole first: grep -q stopping early would fail the pipe.)
  names="$(gh release view "$RELEASE_TAG" --json assets --jq '.assets[].name')"
  for archive in $ARCHIVES; do
    grep -qxF "$(basename "$archive")" <<< "$names" || fail "The draft has no asset named $(basename "$archive")."
  done
  gh release edit "$RELEASE_TAG" --draft=false
  echo "Published $RELEASE_TAG"
}

case "${1:-}" in
  local) local_build ;;
  publish-local) publish_local ;;
  release-state) release_state ;;
  publish) publish ;;
  win-toolchain) win_toolchain ;;
  win-toolchain-unpack) win_toolchain_unpack ;;
  win-check) win_check ;;
  *)
    echo "usage: $0 local|publish-local|release-state|publish|win-toolchain|win-toolchain-unpack|win-check" >&2
    exit 2
    ;;
esac
