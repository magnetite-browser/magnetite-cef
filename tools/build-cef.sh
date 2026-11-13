#!/usr/bin/env bash
# Builds CEF's minimal binary distribution for macOS on Apple silicon from
# source, with the H.264, AAC and HEVC decoders the official builds leave out.
#
#   local                   check out or update the tree, build, distrib
#   publish-local           create the release from this machine
#   release-state           is the release made already (a re-run)?
#   publish                 create the release with the distribution
#
# .github/workflows/build.yml runs `local` on our own Mac runner and the last
# two in its publish job. On a Mac of your own, `local` and `publish-local`
# do the same without the workflow (README, "Building on a machine of our
# own").
#
# Settings come from the environment: CEF_VERSION (required), CEF_REVISION,
# DEPOT_TOOLS_COMMIT, CEF_WORK for the folder to build in (default ~/cef) and
# CEF_FRESH=true to delete that folder first.
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

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# The tree: depot_tools, Chromium with CEF in it, and the build output. It
# stays between builds, so the next one only does what changed.
WORK="${CEF_WORK:-$HOME/cef}"
SRC="$WORK/chromium/src"
OUT="$SRC/out/Release_GN_arm64"
NINJA="$SRC/third_party/ninja/ninja"
# In a workflow job the runner's temp folder, which the next step uploads
# from; otherwise next to the tree (/tmp is emptied on restart).
DIST_DIR="${RUNNER_TEMP:-$WORK}/cef-distrib"
DIST_NAME="cef_binary_${CEF_VERSION}_macosarm64_minimal"
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
  curl -fsSL -o "$WORK/automate-git.py" \
    "https://raw.githubusercontent.com/chromiumembedded/cef/$CEF_COMMIT/tools/automate/automate-git.py"
  # depot_tools at DEPOT_TOOLS_COMMIT, set up as update_depot_tools would
  # (its packages and Python), without moving it (its scripts do not run
  # under `set -u`).
  if [[ ! -d "$WORK/depot_tools" ]]; then
    git clone --quiet https://chromium.googlesource.com/chromium/tools/depot_tools.git "$WORK/depot_tools"
  else
    git -C "$WORK/depot_tools" fetch --quiet origin
  fi
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

  # The update below wants CEF's files as git has them: take the last
  # build's patches/ out again.
  if [[ -d "$SRC/cef" ]]; then
    git -C "$SRC/cef" reset --quiet --hard
    git -C "$SRC/cef" clean --quiet -fd
  fi

  # CEF's checkout tool: CEF at the commit, the Chromium version CEF names in
  # CHROMIUM_BUILD_COMPATIBILITY.txt, Chromium's hooks (clang, rust ...) and
  # the PGO profiles official builds optimise with. With --fast-update it
  # moves an existing tree to the version: it takes CEF's patches out of
  # Chromium, checks out, puts them back, and restores every patched file
  # that came out the same, so ninja does not build it again. It keeps the
  # build output while CEF's branch (Chromium's build number) is the same and
  # drops it for a new one. It would also build; that is done by build.
  python3 "$WORK/automate-git.py" --download-dir="$WORK" \
    --depot-tools-dir="$WORK/depot_tools" --branch="$CEF_BRANCH" \
    --checkout="$CEF_COMMIT" --with-pgo-profiles --fast-update \
    --no-depot-tools-update --arm64-build --no-debug-build --no-build --no-distrib
  # The first checkout clones CEF there and copies it to src/cef; build
  # output of other branches is parked there.
  rm -rf "$WORK/cef" "$WORK"/out_*

  # The version is computed from git, as make_distrib.py will do; it names
  # the archive, so a mismatch is better found now than after the build.
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

  # What automate-git.py does before it builds: translate CEF's API files,
  # apply CEF's patches to Chromium (those already there are skipped), write
  # args.gn and run gn gen. Only the Release arm64 configuration.
  (cd "$SRC/cef" && GN_DEFINES="$(gn_defines)" GN_OUT_CONFIGS=Release_GN_arm64 \
    CEF_ENABLE_ARM64=1 python3 tools/gclient_hook.py)
  cat "$OUT/args.gn"
  check_args

  patches_hash > "$WORK/patches-applied"
  echo "Disk: $(disk)"
}

# One hash over patches/: which patches a tree was made with.
patches_hash() {
  cat "$REPO_DIR"/patches/*.patch | shasum -a 256 | cut -d' ' -f1
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

# Builds cefclient, which make_distrib.py takes the framework from. Ninja
# builds only what is out of date, so after an interruption it carries on
# where it stopped.
build() {
  use_depot_tools
  # Scripts the build starts as `env python3` (the linker driver) get
  # Chromium's own Python. /usr/bin/python3 asks xcodebuild for one, and
  # Xcode 27 rejects the SDK link that rustc passes it in SDKROOT.
  export PATH="$SRC/third_party/cpython3/host/bin:$PATH"
  NINJA_STATUS="[%p %f/%t %e] " "$NINJA" -C "$OUT" -j "$(sysctl -n hw.ncpu)" cefclient ||
    fail "ninja failed with exit code $?."
  echo "Disk: $(disk)"
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
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
      echo "runner: our own, macOS $(sw_vers -productVersion)"
    else
      echo "machine: our own, macOS $(sw_vers -productVersion)"
    fi
  } > "$DIST_DIR/build-info.txt"
  cat "$DIST_DIR/build-info.txt" "$DIST_DIR/$DIST_NAME.tar.bz2.sha256"
  ls -lh "$DIST_DIR"
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
  # ANGLE compiles its Metal shaders with it; from Xcode 27 on it is a
  # download of its own, and the build fails hours in without it.
  xcrun -f metal > /dev/null 2>&1 ||
    fail "Xcode's Metal toolchain is missing. Get it with: xcodebuild -downloadComponent MetalToolchain"
  if [[ "${CEF_FRESH:-}" == true ]]; then
    echo "Deleting $WORK"
    rm -rf "${WORK:?}"
  fi
  mkdir -p "$WORK"
  local free_gb
  if [[ ! -e "$WORK/chromium" && ! -e "$WORK/depot_tools" ]]; then
    free_gb="$(df -g "$WORK" | awk 'NR == 2 { print $4 }')"
    ((free_gb >= 200)) || fail "Only $free_gb GB free at $WORK; the tree needs about 200."
  elif [[ ! -d "$SRC/cef" ]]; then
    fail "$WORK holds a checkout that never finished. Build with CEF_FRESH=true (the workflow's \"fresh\") to start over."
  elif [[ "$(git -C "$SRC" rev-parse --is-shallow-repository)" == true ]]; then
    fail "The tree in $WORK has no git history (an older version of this script made it) and cannot be updated. Build with CEF_FRESH=true (the workflow's \"fresh\")."
  fi
  # The compile commands name the SDK's path, not its version: ninja would
  # not notice another Xcode and mix two SDKs in one build.
  if [[ -f "$WORK/xcode-version" && "$(xcodebuild -version)" != "$(cat "$WORK/xcode-version")" ]]; then
    echo "Xcode changed since the last build: building everything again."
    rm -rf "$SRC/out"
  fi
  xcodebuild -version > "$WORK/xcode-version"

  if tree_is_current; then
    echo "The tree in $WORK is CEF $CEF_VERSION already"
  else
    sync
  fi
  build
  distrib
  echo "Made $DIST_DIR/$DIST_NAME.tar.bz2."
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

# Creates the release with the distribution and its SHA-256: as a draft with
# all files, then published, so an immutable release is complete.
publish() {
  local file="$DIST_DIR/$DIST_NAME.tar.bz2" notes="${RUNNER_TEMP:-/tmp}/release-notes.md" origin
  (cd "$DIST_DIR" && shasum -a 256 -c "$DIST_NAME.tar.bz2.sha256")
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    origin="- Built by $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID from $GITHUB_SHA
- Check it: \`gh attestation verify $DIST_NAME.tar.bz2 --repo $GITHUB_REPOSITORY --signer-workflow $GITHUB_REPOSITORY/.github/workflows/build.yml --source-ref refs/heads/main\`"
  else
    origin="- Built from $GITHUB_SHA with \`tools/build-cef.sh local\` on a machine of the Magnetite maintainers, not by the workflow, so it has no attestation. Its SHA-256 is in the file next to it."
  fi
  cat > "$notes" << EOF
CEF $CEF_VERSION, the minimal distribution for macOS on Apple silicon, built from source with the H.264, AAC and HEVC decoders that the official builds leave out.

$origin

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

case "${1:-}" in
  local) local_build ;;
  publish-local) publish_local ;;
  release-state) release_state ;;
  publish) publish ;;
  *)
    echo "usage: $0 local|publish-local|release-state|publish" >&2
    exit 2
    ;;
esac
