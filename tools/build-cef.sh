#!/usr/bin/env bash
# Builds CEF's minimal binary distribution from source, with the H.264, AAC
# and HEVC decoders the official builds leave out, for the machine it runs on:
# macOS on Apple silicon (macosarm64) or Linux on x86_64 (linux64).
# On a machine of your own (README, "Building on a machine of our own") and
# on the self-hosted Linux runner:
#
#   local                   fetch (unless the tree is there), build, distrib
#   publish-local           create the release from this machine
#
# .github/workflows/build.yml runs the macOS build on GitHub's hosted Mac
# runners, where one build takes a chain of jobs. Each command is one stage
# of such a job:
#
#   prepare                 select Xcode, free disk space on the runner
#   fetch                   check out CEF and Chromium, patch, configure (job 1)
#   restore                 unpack the tree the previous job packed (jobs 2+)
#   build                   run ninja until the job's time is nearly up
#   distrib                 make cef_binary_<version>_<platform>_minimal.tar.bz2
#   save                    pack the tree for the next job
#   release-state           is the release made already (a re-run)?
#   publish                 create the release with every platform's archive
#   drop-artifacts <prefix> delete this run's artifacts named <prefix>...
#
# Settings come from the environment: CEF_VERSION (required), CEF_REVISION,
# DEPOT_TOOLS_COMMIT, and CEF_WORK for the folder to build in (default ~/cef).
# The workflow also sets XCODE_VERSION, JOB_START and BUILD_UNTIL_MINUTE.
# Written for bash 3.2, the bash of the macOS runners.
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
case "$OS-$(uname -m)" in
  Darwin-arm64)
    ARCH=arm64 PLATFORM=macosarm64 TARGETS=cefclient PLATFORM_GN=""
    ;;
  Linux-x86_64)
    # Not cefclient: it needs GTK's headers, which CEF leaves out with
    # use_sysroot=true, and the distribution takes nothing from it.
    ARCH=x64 PLATFORM=linux64 TARGETS="libcef chrome_sandbox"
    PLATFORM_GN="use_sysroot=true is_cfi=false"
    ;;
  *)
    echo "::error::This builds CEF on macOS on Apple silicon or Linux on x86_64, not $OS $(uname -m)." >&2
    exit 1
    ;;
esac

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# The same path in every job: the build files refer to it. CEF_WORK moves it,
# for a build on a machine of our own with an external disk.
WORK="${CEF_WORK:-$HOME/cef}"
SRC="$WORK/chromium/src"
OUT="$SRC/out/Release_GN_$ARCH"
NINJA="$SRC/third_party/ninja/ninja"
XCODE_APP=/Applications/Xcode-cef.app
STATE_DIR="${RUNNER_TEMP:-/tmp}/cef-state"
# Next to the tree on a machine of our own: /tmp is emptied on restart.
# Each platform's files go into a folder of their own in it (DIST_DIR/
# PLATFORM), so the publish job can hold all of them.
DIST_DIR="${RUNNER_TEMP:-$WORK}/cef-distrib"
DIST_NAME="cef_binary_${CEF_VERSION}_${PLATFORM}_minimal"
# A release is never replaced: another build of a version is a revision of it.
CEF_REVISION="${CEF_REVISION:-}"
if [[ -n "$CEF_REVISION" && ! "$CEF_REVISION" =~ ^([2-9]|[1-9][0-9]+)$ ]]; then
  echo "::error::The revision must be empty or a number from 2: $CEF_REVISION" >&2
  exit 1
fi
RELEASE_TAG="$SHORT_VERSION${CEF_REVISION:+-$CEF_REVISION}"

# Test data CEF never builds; dropped after configuring to shrink the tree
# every job packs and unpacks (see prune).
PRUNE_DIRS="third_party/blink/web_tests chrome/test/data content/test/data"

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

output() {
  echo "$1"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$1" >> "$GITHUB_OUTPUT"; fi
}

fail() {
  echo "::error::$*" >&2
  exit 1
}

disk() {
  df -h "$(dirname "$WORK")" | awk 'NR == 2 { print $4 " free of " $2 }'
}

# The GN args on top of what CEF sets itself (tools/gn_args.py).
#   proprietary_codecs, ffmpeg_branding  H.264, AAC and HEVC; the point of it.
#   media_use_openh264=false             no OpenH264 software encoder (it also
#                                        turns off WebRTC's rtc_use_h264).
#                                        Macs encode H.264 in hardware; on
#                                        Linux, WebRTC sends VP8/VP9 instead.
#   symbol_level=0                       no debug symbols: a smaller tree.
#   treat_warnings_as_errors=false       a newer macOS SDK than Chromium was
#                                        tested with must not stop the build.
# And the platform's own, PLATFORM_GN.
gn_defines() {
  echo "is_official_build=true proprietary_codecs=true ffmpeg_branding=Chrome" \
    "media_use_openh264=false symbol_level=0 treat_warnings_as_errors=false $PLATFORM_GN"
}

# The GN args the release must have, as `gn args --short` prints them.
EXPECTED_ARGS='proprietary_codecs = true
ffmpeg_branding = "Chrome"
media_use_openh264 = false
rtc_use_h264 = false'

prepare() {
  # It deletes Xcode versions and SDKs: never on a machine of our own.
  [[ "${RUNNER_ENVIRONMENT:-}" == github-hosted ]] ||
    fail "prepare only runs on GitHub's hosted runners."
  echo "Disk: $(disk)"
  # Spotlight would index the tens of GB the build writes.
  sudo mdutil -a -i off > /dev/null 2>&1 || true
  select_xcode
  free_disk
  echo "Disk: $(disk)"
  local free
  free="$(free_gb "$HOME")"
  if ((free < 80)); then
    echo "::warning::Only $free GB free; the build tree grows to about 45 GB, and packing it needs room too."
  fi
}

# Keeps one Xcode, always at $XCODE_APP: compile commands contain the SDK
# path, and a different path in a later job would make ninja rebuild all.
select_xcode() {
  local want="/Applications/Xcode_${XCODE_VERSION:-}.app" keep app
  if [[ -z "${XCODE_VERSION:-}" || ! -d "$want" ]]; then
    want="$(dirname "$(dirname "$(xcode-select -p)")")"
    echo "::warning::Xcode ${XCODE_VERSION:-} is not on this image, using $want."
  fi
  keep="$(cd "$want" && pwd -P)"
  for app in /Applications/Xcode*.app; do
    if [[ -L "$app" ]]; then
      sudo rm -f "$app"
    elif [[ "$app" != "$keep" ]]; then
      echo "Deleting $app"
      sudo rm -rf "$app"
    fi
  done
  sudo mv "$keep" "$XCODE_APP"
  sudo xcode-select --switch "$XCODE_APP"
  xcodebuild -version
}

# Simulators, the Android and .NET SDKs and other tool caches: tens of GB
# Chromium does not need. Best effort; a failure here only costs space.
free_disk() {
  local tool
  xcrun simctl delete all > /dev/null 2>&1 || true
  sudo xcrun simctl runtime delete all > /dev/null 2>&1 || true
  sudo rm -rf "${ANDROID_HOME:-$HOME/Library/Android/sdk}" "$HOME/.dotnet"
  # Keeps Python, which actions/setup-python installs there.
  for tool in "${RUNNER_TOOL_CACHE:-$HOME/hostedtoolcache}"/*; do
    if [[ "$(basename "$tool")" != Python ]]; then sudo rm -rf "$tool"; fi
  done
}

fetch() {
  echo "CEF $CEF_VERSION: branch $CEF_BRANCH, commit $CEF_COMMIT"
  mkdir -p "$WORK"
  # The commit's own checkout tool, not the branch's newest.
  curl -fsSL -o "$WORK/automate-git.py" \
    "https://raw.githubusercontent.com/chromiumembedded/cef/$CEF_COMMIT/tools/automate/automate-git.py"
  # depot_tools at DEPOT_TOOLS_COMMIT, set up as update_depot_tools would
  # (its packages and Python), without moving it (its scripts do not run
  # under `set -u`).
  git clone --quiet https://chromium.googlesource.com/chromium/tools/depot_tools.git "$WORK/depot_tools"
  git -C "$WORK/depot_tools" checkout --quiet "$DEPOT_TOOLS_COMMIT"
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
  # The Xcode the tree is built with: later jobs must have the same.
  if [[ "$OS" == Darwin ]]; then xcodebuild -version > "$WORK/xcode-version"; fi

  # CEF's checkout tool: depot_tools, CEF at the commit, the Chromium version
  # CEF names in CHROMIUM_BUILD_COMPATIBILITY.txt (without git history, which
  # saves tens of GB), Chromium's hooks (clang, rust ...) and the PGO profiles
  # official builds optimise with. It would also build, but cannot stop and
  # resume, so that is done below.
  python3 "$WORK/automate-git.py" --download-dir="$WORK" \
    --depot-tools-dir="$WORK/depot_tools" --branch="$CEF_BRANCH" \
    --checkout="$CEF_COMMIT" --no-chromium-history --with-pgo-profiles \
    --no-depot-tools-update "--$ARCH-build" --no-debug-build --no-build --no-distrib
  # automate-git.py works on its own clone; src/cef is a copy of it.
  rm -rf "$WORK/cef"

  # The version is computed from git, as make_distrib.py will do; it names
  # the archive, so a mismatch is better found now than in half a day.
  local actual
  actual="$(python3 "$SRC/cef/tools/cef_version.py" current)"
  [[ "$actual" == "$CEF_VERSION" ]] || fail "The checkout is CEF $actual, not $CEF_VERSION."

  # Magnetite's own changes to CEF (patches/, see the README), before CEF's
  # files are translated and configured. They change no commit, so the
  # version stays the one checked above.
  local patch
  for patch in "$REPO_DIR"/patches/*.patch; do
    echo "Applying $(basename "$patch")"
    git -C "$SRC/cef" apply "$patch" || fail "$(basename "$patch") does not apply to CEF $CEF_VERSION."
  done
  patches_hash > "$WORK/patches-applied"

  # What automate-git.py does before it builds: translate CEF's API files,
  # apply CEF's patches to Chromium, write args.gn and run gn gen. Only the
  # Release configuration of this machine's architecture. On Linux it also
  # installs the sysroot (CEF_INSTALL_SYSROOT); without it, gn_args.py has
  # no configuration to generate.
  (cd "$SRC/cef" && GN_DEFINES="$(gn_defines)" GN_OUT_CONFIGS="Release_GN_$ARCH" \
    CEF_ENABLE_ARM64=1 CEF_INSTALL_SYSROOT="$ARCH" python3 tools/gclient_hook.py)
  cat "$OUT/args.gn"
  check_args

  prune
  echo "Disk: $(disk)"
}

# One hash over patches/: which patches a tree was made with.
patches_hash() {
  cat "$REPO_DIR"/patches/*.patch | sha256 | cut -d' ' -f1
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
}

# Moves PRUNE_DIRS out of the tree unless gn read files from them, then lets
# ninja check (dry run) that the build needs nothing that went with them.
# If it does, everything is put back.
prune() {
  local trash="$WORK/pruned" dir
  mkdir -p "$trash"
  for dir in $PRUNE_DIRS; do
    [[ -d "$SRC/$dir" ]] || continue
    if grep -qF " ../../$dir/" "$OUT/build.ninja.d"; then
      echo "Keeping $dir: gn reads files from it"
      continue
    fi
    mkdir -p "$trash/$(dirname "$dir")"
    mv "$SRC/$dir" "$trash/$dir"
  done
  # shellcheck disable=SC2086 # TARGETS is a list
  if "$NINJA" -C "$OUT" -n $TARGETS > /dev/null; then
    rm -rf "$trash"
    return
  fi
  echo "::warning::The build needs files from $PRUNE_DIRS; keeping them."
  for dir in $PRUNE_DIRS; do
    if [[ -d "$trash/$dir" ]]; then mv "$trash/$dir" "$SRC/$dir"; fi
  done
  rm -rf "$trash"
}

# Builds TARGETS, which make_distrib.py takes the files from. In the chain of
# hosted Mac jobs (JOB_START set), only until BUILD_UNTIL_MINUTE minutes after
# JOB_START. Sets the step output "status" to "finished", or to "running"
# when the next job has to carry on.
build() {
  use_depot_tools
  # Scripts the build starts as `env python3` (the linker driver) get
  # Chromium's own Python. /usr/bin/python3 asks xcodebuild for one, and
  # Xcode 27 rejects the SDK link that rustc passes it in SDKROOT.
  export PATH="$SRC/third_party/cpython3/host/bin:$PATH"
  local stop budget stopped="${RUNNER_TEMP:-/tmp}/ninja-stopped" ninja_pid watchdog rc=0 jobs
  jobs="$(getconf _NPROCESSORS_ONLN)"
  if [[ -z "${JOB_START:-}" ]]; then
    # No job to run out of time on a machine of our own.
    # shellcheck disable=SC2086 # TARGETS is a list
    NINJA_STATUS="[%p %f/%t %e] " "$NINJA" -C "$OUT" -j "$jobs" $TARGETS ||
      fail "ninja failed with exit code $?."
    output status=finished
    return
  fi
  stop=$((JOB_START + ${BUILD_UNTIL_MINUTE:-300} * 60))
  budget=$((stop - $(date +%s)))
  rm -f "$stopped"
  if ((budget < 600)); then
    echo "Less than 10 minutes left, leaving the build to the next job"
    output status=running
    return
  fi
  echo "Building for at most $((budget / 60)) minutes. Disk: $(disk)"

  # Ninja is resumable by design: on SIGTERM it stops the compilers, deletes
  # their half-written outputs and exits, and the next job's ninja redoes
  # only those steps. A watchdog sends that signal when the time is up.
  # shellcheck disable=SC2086 # TARGETS is a list
  NINJA_STATUS="[%p %f/%t %e] " "$NINJA" -C "$OUT" -j "$jobs" $TARGETS &
  ninja_pid=$!
  (
    sleep "$budget"
    kill -0 "$ninja_pid" || exit 0
    touch "$stopped"
    kill -TERM "$ninja_pid"
    # Ninja exits within seconds; this is only the backstop.
    sleep 600
    kill -KILL "$ninja_pid"
  ) 2> /dev/null &
  watchdog=$!
  wait "$ninja_pid" || rc=$?
  kill "$watchdog" 2> /dev/null || true
  wait "$watchdog" 2> /dev/null || true

  echo "Disk: $(disk)"
  if [[ -f "$stopped" ]]; then
    output status=running
  elif ((rc == 0)); then
    output status=finished
  else
    fail "ninja failed with exit code $rc."
  fi
}

# Makes the minimal distribution, the kind Magnetite's build otherwise
# downloads from CEF's CDN, and puts it with its SHA-256 and the build's
# args.gn into DIST_DIR/PLATFORM.
distrib() {
  use_depot_tools
  local out="$WORK/distrib" dist="$DIST_DIR/$PLATFORM"
  rm -rf "$out" "$dist"
  mkdir -p "$out" "$dist"
  (cd "$SRC/cef/tools" && CEF_ARCHIVE_FORMAT=tar.bz2 python3 make_distrib.py \
    --output-dir="$out" --ninja-build "--$ARCH-build" --minimal --no-symbols --no-docs)
  [[ -f "$out/$DIST_NAME.tar.bz2" ]] || fail "Expected $DIST_NAME.tar.bz2, got: $(ls "$out")"
  mv "$out/$DIST_NAME.tar.bz2" "$dist/"
  (cd "$dist" && sha256 "$DIST_NAME.tar.bz2" > "$DIST_NAME.tar.bz2.sha256")
  cp "$OUT/args.gn" "$dist/args.gn"
  # What else went into it, for the release notes.
  {
    echo "depot_tools $(git -C "$WORK/depot_tools" rev-parse HEAD)"
    if [[ "$OS" == Darwin ]]; then
      tr '\n' ' ' < "$WORK/xcode-version"
      echo
    fi
    if [[ "${RUNNER_ENVIRONMENT:-}" == github-hosted ]]; then
      echo "runner: GitHub-hosted ${ImageOS:-} ${ImageVersion:-}"
    elif [[ -n "${GITHUB_ACTIONS:-}" ]]; then
      echo "runner: our own, $(host_os)"
    else
      echo "machine: our own, $(host_os)"
    fi
  } > "$dist/build-info.txt"
  cat "$dist/build-info.txt" "$dist/$DIST_NAME.tar.bz2.sha256"
  ls -lh "$dist"
}

host_os() {
  if [[ "$OS" == Darwin ]]; then
    echo "macOS $(sw_vers -productVersion)"
  else
    # shellcheck disable=SC1091
    (. /etc/os-release && echo "$PRETTY_NAME, Linux $(uname -r)")
  fi
}

# Packs WORK into 1 GB parts in STATE_DIR. Each file is deleted as soon as it
# is packed, so the tree and its archive never need the disk at once.
save() {
  rm -rf "$STATE_DIR"
  mkdir -p "$STATE_DIR"
  gtar -C "$(dirname "$WORK")" --remove-files -cf - "$(basename "$WORK")" |
    zstd -q -T0 -10 --long=27 |
    split -b 1024m - "$STATE_DIR/cef.tar.zst.part-"
  (cd "$STATE_DIR" && sha256 cef.tar.zst.part-* > SHA256SUMS)
  du -sh "$STATE_DIR"
}

# Unpacks what save packed. Each part is deleted once it has been read.
restore() {
  local part
  (cd "$STATE_DIR" && sha256 -c SHA256SUMS)
  for part in "$STATE_DIR"/cef.tar.zst.part-*; do
    cat "$part"
    rm "$part"
  done | zstd -d -q --long=27 | gtar -C "$(dirname "$WORK")" -xf -
  [[ -d "$OUT" ]] || fail "The unpacked tree has no $OUT."
  # The compile commands name the SDK: another Xcode would mix two in one
  # build (a refreshed runner image mid-chain).
  [[ "$(xcodebuild -version)" == "$(cat "$WORK/xcode-version")" ]] ||
    fail "This runner's Xcode differs from the one the build started with; start a new run."
  echo "Disk: $(disk)"
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

# Fetches unless this version's tree is in WORK already, then builds and
# makes the distribution: the whole build in one go, on a machine of our own
# or the self-hosted Linux runner. Run again after an interruption, it
# carries on where ninja stopped.
#
# A tree it cannot carry on with (another version, other patches, a fetch
# that stopped half-way) stops it on a machine of our own, where it may be
# someone's work. On the runner the tree is only ever this script's, so it
# is deleted and fetched again.
local_build() {
  [[ "${RUNNER_ENVIRONMENT:-}" != github-hosted ]] ||
    fail "local is for a machine of our own; on hosted runners the workflow runs the stages."
  if [[ "$OS" == Darwin ]]; then
    # ANGLE compiles its Metal shaders with it; from Xcode 27 on it is a
    # download of its own, and the build fails hours in without it.
    xcrun -f metal > /dev/null 2>&1 ||
      fail "Xcode's Metal toolchain is missing. Get it with: xcodebuild -downloadComponent MetalToolchain"
  else
    # Chromium's pkg-config wrapper runs the host's on the sysroot.
    command -v pkg-config > /dev/null || fail "pkg-config is missing (the package pkgconf or pkg-config)."
  fi
  local problem="" actual free
  if [[ -f "$OUT/args.gn" ]]; then
    # ninja would build whatever is there: make sure it is what was asked for.
    use_depot_tools
    actual="$(python3 "$SRC/cef/tools/cef_version.py" current)"
    if [[ "$actual" != "$CEF_VERSION" ]]; then
      problem="The tree in $WORK is CEF $actual, not $CEF_VERSION."
    elif [[ "$(cat "$WORK/patches-applied" 2> /dev/null)" != "$(patches_hash)" ]]; then
      problem="patches/ changed since the tree in $WORK was made."
    fi
  elif [[ -e "$WORK/chromium" || -e "$WORK/depot_tools" ]]; then
    problem="$WORK holds an unfinished checkout."
  fi
  if [[ -n "$problem" && -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "$problem Deleting it."
    rm -rf "$WORK"
  elif [[ -n "$problem" ]]; then
    fail "$problem Delete it or set CEF_WORK to another folder."
  fi
  if [[ -f "$OUT/args.gn" ]]; then
    echo "Carrying on with the tree in $WORK"
  else
    mkdir -p "$WORK"
    free="$(free_gb "$WORK")"
    ((free >= 120)) || fail "Only $free GB free at $WORK; a build needs about 120."
    fetch
  fi
  build
  distrib
  echo "Made $DIST_DIR/$PLATFORM/$DIST_NAME.tar.bz2."
  if [[ -z "${GITHUB_ACTIONS:-}" ]]; then echo "Publish it with: $0 publish-local"; fi
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
    fail "The tree in $WORK was made with other patches than this commit has."
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

# Deletes this workflow run's artifacts whose name starts with $1.
drop_artifacts() {
  local prefix="${1:?usage: build-cef.sh drop-artifacts <name prefix>}" id
  gh api --paginate "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/artifacts" \
    --jq ".artifacts[] | select(.name | startswith(\"$prefix\")) | .id" |
    while read -r id; do
      gh api -X DELETE "repos/$GITHUB_REPOSITORY/actions/artifacts/$id"
      echo "Deleted artifact $id"
    done
}

case "${1:-}" in
  local) local_build ;;
  publish-local) publish_local ;;
  prepare) prepare ;;
  fetch) fetch ;;
  restore) restore ;;
  build) build ;;
  distrib) distrib ;;
  save) save ;;
  release-state) release_state ;;
  publish) publish ;;
  drop-artifacts) drop_artifacts "${2:-}" ;;
  *)
    echo "usage: $0 local|publish-local|prepare|fetch|restore|build|distrib|save|release-state|publish|drop-artifacts <prefix>" >&2
    exit 2
    ;;
esac
