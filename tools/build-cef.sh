#!/usr/bin/env bash
# Builds CEF's minimal binary distribution for macOS on Apple silicon from
# source, with the H.264, AAC and HEVC decoders the official builds leave out.
# .github/workflows/build.yml runs it on GitHub's hosted Mac runners, where one
# build takes a chain of jobs. Each command is one stage of such a job:
#
#   prepare                 select Xcode, free disk space on the runner
#   fetch                   check out CEF and Chromium, patch, configure (job 1)
#   restore                 unpack the tree the previous job packed (jobs 2+)
#   build                   run ninja until the job's time is nearly up
#   distrib                 make cef_binary_<version>_macosarm64_minimal.tar.bz2
#   save                    pack the tree for the next job
#   release-state           is the release made already (a re-run)?
#   publish                 create the release with the distribution
#   drop-artifacts <prefix> delete this run's artifacts named <prefix>...
#
# Settings come from the environment, which the workflow sets: CEF_VERSION
# (required), CEF_REVISION, DEPOT_TOOLS_COMMIT, XCODE_VERSION, JOB_START,
# BUILD_UNTIL_MINUTE, and CEF_WORK for a local build.
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

# The same path in every job: the build files refer to it. CEF_WORK moves it,
# for a build on a Mac of our own with an external disk.
WORK="${CEF_WORK:-$HOME/cef}"
SRC="$WORK/chromium/src"
OUT="$SRC/out/Release_GN_arm64"
NINJA="$SRC/third_party/ninja/ninja"
XCODE_APP=/Applications/Xcode-cef.app
STATE_DIR="${RUNNER_TEMP:-/tmp}/cef-state"
DIST_DIR="${RUNNER_TEMP:-/tmp}/cef-distrib"
DIST_NAME="cef_binary_${CEF_VERSION}_macosarm64_minimal"
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
#                                        Macs encode H.264 in hardware.
#   symbol_level=0                       no debug symbols: a smaller tree.
#   treat_warnings_as_errors=false       a newer macOS SDK than Chromium was
#                                        tested with must not stop the build.
gn_defines() {
  echo "is_official_build=true proprietary_codecs=true ffmpeg_branding=Chrome" \
    "media_use_openh264=false symbol_level=0 treat_warnings_as_errors=false"
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
  local free_gb
  free_gb="$(df -g "$HOME" | awk 'NR == 2 { print $4 }')"
  if ((free_gb < 80)); then
    echo "::warning::Only $free_gb GB free; the build tree grows to about 45 GB, and packing it needs room too."
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
  : "${DEPOT_TOOLS_COMMIT:?DEPOT_TOOLS_COMMIT is required}"
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
  xcodebuild -version > "$WORK/xcode-version"

  # CEF's checkout tool: depot_tools, CEF at the commit, the Chromium version
  # CEF names in CHROMIUM_BUILD_COMPATIBILITY.txt (without git history, which
  # saves tens of GB), Chromium's hooks (clang, rust ...) and the PGO profiles
  # official builds optimise with. It would also build, but cannot stop and
  # resume, so that is done below.
  python3 "$WORK/automate-git.py" --download-dir="$WORK" \
    --depot-tools-dir="$WORK/depot_tools" --branch="$CEF_BRANCH" \
    --checkout="$CEF_COMMIT" --no-chromium-history --with-pgo-profiles \
    --no-depot-tools-update --arm64-build --no-debug-build --no-build --no-distrib
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
  for patch in "$(cd "$(dirname "$0")/.." && pwd)"/patches/*.patch; do
    echo "Applying $(basename "$patch")"
    git -C "$SRC/cef" apply "$patch" || fail "$(basename "$patch") does not apply to CEF $CEF_VERSION."
  done

  # What automate-git.py does before it builds: translate CEF's API files,
  # apply CEF's patches to Chromium, write args.gn and run gn gen. Only the
  # Release arm64 configuration.
  (cd "$SRC/cef" && GN_DEFINES="$(gn_defines)" GN_OUT_CONFIGS=Release_GN_arm64 \
    CEF_ENABLE_ARM64=1 python3 tools/gclient_hook.py)
  cat "$OUT/args.gn"
  check_args

  prune
  echo "Disk: $(disk)"
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
  if "$NINJA" -C "$OUT" -n cefclient > /dev/null; then
    rm -rf "$trash"
    return
  fi
  echo "::warning::The build needs files from $PRUNE_DIRS; keeping them."
  for dir in $PRUNE_DIRS; do
    if [[ -d "$trash/$dir" ]]; then mv "$trash/$dir" "$SRC/$dir"; fi
  done
  rm -rf "$trash"
}

# Builds cefclient, which make_distrib.py takes the framework from, until
# BUILD_UNTIL_MINUTE minutes after JOB_START. Sets the step output "status"
# to "finished", or to "running" when the next job has to carry on.
build() {
  use_depot_tools
  # Scripts the build starts as `env python3` (the linker driver) get
  # Chromium's own Python. /usr/bin/python3 asks xcodebuild for one, and
  # Xcode 27 rejects the SDK link that rustc passes it in SDKROOT.
  export PATH="$SRC/third_party/cpython3/host/bin:$PATH"
  local stop budget stopped="${RUNNER_TEMP:-/tmp}/ninja-stopped" ninja_pid watchdog rc=0
  stop=$((${JOB_START:?JOB_START is required} + ${BUILD_UNTIL_MINUTE:-300} * 60))
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
  NINJA_STATUS="[%p %f/%t %e] " "$NINJA" -C "$OUT" -j "$(sysctl -n hw.ncpu)" cefclient &
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
# args.gn into DIST_DIR.
distrib() {
  use_depot_tools
  local out="$WORK/distrib"
  rm -rf "$out" "$DIST_DIR"
  mkdir -p "$out" "$DIST_DIR"
  (cd "$SRC/cef/tools" && CEF_ARCHIVE_FORMAT=tar.bz2 python3 make_distrib.py \
    --output-dir="$out" --ninja-build --arm64-build --minimal --no-symbols --no-docs)
  [[ -f "$out/$DIST_NAME.tar.bz2" ]] || fail "Expected $DIST_NAME.tar.bz2, got: $(ls "$out")"
  mv "$out/$DIST_NAME.tar.bz2" "$DIST_DIR/"
  (cd "$DIST_DIR" && shasum -a 256 "$DIST_NAME.tar.bz2" > "$DIST_NAME.tar.bz2.sha256")
  cp "$OUT/args.gn" "$DIST_DIR/args.gn"
  # What else went into it, for the release notes.
  {
    echo "depot_tools $(git -C "$WORK/depot_tools" rev-parse HEAD)"
    tr '\n' ' ' < "$WORK/xcode-version"
    echo
    echo "runner: ${RUNNER_ENVIRONMENT:-unknown} ${ImageOS:-} ${ImageVersion:-}"
  } > "$DIST_DIR/build-info.txt"
  cat "$DIST_DIR/build-info.txt" "$DIST_DIR/$DIST_NAME.tar.bz2.sha256"
  ls -lh "$DIST_DIR"
}

# Packs WORK into 1 GB parts in STATE_DIR. Each file is deleted as soon as it
# is packed, so the tree and its archive never need the disk at once.
save() {
  rm -rf "$STATE_DIR"
  mkdir -p "$STATE_DIR"
  gtar -C "$(dirname "$WORK")" --remove-files -cf - "$(basename "$WORK")" |
    zstd -q -T0 -10 --long=27 |
    split -b 1024m - "$STATE_DIR/cef.tar.zst.part-"
  (cd "$STATE_DIR" && shasum -a 256 cef.tar.zst.part-* > SHA256SUMS)
  du -sh "$STATE_DIR"
}

# Unpacks what save packed. Each part is deleted once it has been read.
restore() {
  local part
  (cd "$STATE_DIR" && shasum -a 256 -c SHA256SUMS)
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

# Sets the step output "state": "new" when RELEASE_TAG has no release yet,
# "published" when it holds this very file (a re-run after the release was
# made). A release with another file is an error: releases are never
# replaced, since Magnetite pins the archive's hash.
release_state() {
  local local_hash remote
  local_hash="$(cut -d' ' -f1 "$DIST_DIR/$DIST_NAME.tar.bz2.sha256")"
  if ! remote="$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$RELEASE_TAG" \
    --jq ".assets[] | select(.name == \"$DIST_NAME.tar.bz2\") | .digest" 2> /dev/null)"; then
    # No release; a tag of that name would be taken as it is, wherever it
    # points.
    if gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/$RELEASE_TAG" > /dev/null 2>&1; then
      fail "Tag $RELEASE_TAG exists without a release. Build it again as a new revision."
    fi
    output state=new
  elif [[ "$remote" == "sha256:$local_hash" ]]; then
    output state=published
  else
    fail "Release $RELEASE_TAG exists with another file. Build it again as a new revision."
  fi
}

# Creates the release with the distribution and its SHA-256: as a draft with
# all files, then published, so an immutable release is complete.
publish() {
  local file="$DIST_DIR/$DIST_NAME.tar.bz2" notes="${RUNNER_TEMP:-/tmp}/release-notes.md"
  (cd "$DIST_DIR" && shasum -a 256 -c "$DIST_NAME.tar.bz2.sha256")
  cat > "$notes" << EOF
CEF $CEF_VERSION, the minimal distribution for macOS on Apple silicon, built from source with the H.264, AAC and HEVC decoders that the official builds leave out.

- Built by $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID from $GITHUB_SHA
- Check it: \`gh attestation verify $DIST_NAME.tar.bz2 --repo $GITHUB_REPOSITORY --signer-workflow $GITHUB_REPOSITORY/.github/workflows/build.yml --source-ref refs/heads/main\`

\`\`\`
$(cat "$DIST_DIR/build-info.txt")
\`\`\`

args.gn:

\`\`\`
$(cat "$DIST_DIR/args.gn")
\`\`\`
EOF
  gh release create "$RELEASE_TAG" "$file" "$file.sha256" --draft --target "$GITHUB_SHA" \
    --title "CEF $RELEASE_TAG with H.264 and AAC" --notes-file "$notes"
  # GitHub renames some characters in asset names; "+" must survive. (Read
  # whole first: grep -q stopping early would fail the pipe.)
  local names
  names="$(gh release view "$RELEASE_TAG" --json assets --jq '.assets[].name')"
  grep -qxF "$DIST_NAME.tar.bz2" <<< "$names" || fail "The draft has no asset named $DIST_NAME.tar.bz2."
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
    echo "usage: $0 prepare|fetch|restore|build|distrib|save|release-state|publish|drop-artifacts <prefix>" >&2
    exit 2
    ;;
esac
