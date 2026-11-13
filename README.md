# magnetite-cef

The build of the Chromium Embedded Framework (CEF) that the
[Magnetite](https://github.com/magnetite-browser/magnetite) browser ships:
CEF as its official builds are, plus the H.264, AAC and HEVC decoders those
leave out. Without them, sites that serve only these formats do not play.

## Patches

`patches/` holds Magnetite's own changes to CEF, applied to the checkout
before it is configured. A patch that no longer applies stops the build.

| Patch | What it changes |
| --- | --- |
| `extension-views-excluded.patch` | Extension popups, side panels, background pages and offscreen documents are hosted by Chrome and never get a CEF browser. CEF waited for one all the same, which delayed every extension popup; with the patch it does not. |

## Releases

One release per CEF version, tagged with it (`156.0.15`; another build of
the same version gets a revision, `156.0.15-2`), with:

- `cef_binary_<version>_macosarm64_minimal.tar.bz2`: the minimal distribution
  for macOS on Apple silicon, laid out like the official one on CEF's CDN;
- `cef_binary_<version>_linux64_minimal.tar.bz2`: the same for Linux on
  x86_64;
- each one's SHA-256 (`.sha256`);
- provenance attestations signed by GitHub, when the workflow built them.

The release notes list each build's GN args, the depot_tools commit, Xcode
(macOS), and where it was built: by the workflow (with the run) or by hand on a
machine of the maintainers.

### Checking a release

For a release the workflow built, the attestation shows which workflow
built the archive, from which branch. Check both before Magnetite pins a new
archive:

```sh
gh attestation verify <archive> --repo magnetite-browser/magnetite-cef \
  --signer-workflow magnetite-browser/magnetite-cef/.github/workflows/build.yml \
  --source-ref refs/heads/main
```

The workflow builds and releases from `main` only; in the repository's
settings, protect `main` (changes by reviewed pull request only) and turn on
immutable releases, so a published archive cannot be replaced.

The workflow builds on machines of ours (below), so the attestation says which
code was built by which workflow, not that the machine was clean.

A release built by hand on a machine of the maintainers has no attestation: GitHub
signs only what its workflows build. Its notes say so and name the commit
it was built from. What can be checked is the SHA-256, which Magnetite pins,
and the build itself, by building that commit again.

## Building a release

Actions → Build CEF → Run workflow on `main`, with the full CEF version, as
CEF names its archives (`156.0.15+gcf671c0+chromium-156.0.8078.80`).

It builds both platforms at once, each in one job on a machine of our own
(below), and publishes one release once both are done. A failed platform
holds the release back. A platform's tree (Chromium with its git history,
CEF, the build output) stays on its machine, so a run does only what changed
since the last one:

- The same version again, with other patches: the patched files are built
  again, the rest is kept.
- A new CEF version on the same Chromium branch (the build number, `8078`):
  git rewrites the files that differ and ninja builds what depends on them.
- A new Chromium branch: the sources are updated in place, the build output
  starts from zero.
- The first run, or a run with "fresh" ticked: everything from zero. Tick
  "fresh" when an update of the tree failed.

If a job fails (a network error, a restart), run it again: it carries on
where it stopped.

A release is never replaced, since Magnetite pins the archive's hash. To
build a version again, run the workflow with a revision (2, 3 …): it
becomes the release `156.0.15-2`. If publishing failed after the release
was made, re-running the publish job finds the release and passes.

### Build settings

`tools/build-cef.sh` uses the options of CEF's official builds
(`automate-git.py`, `is_official_build=true` with PGO profiles; on Linux
Chromium's Debian sysroot, `use_sysroot=true is_cfi=false`) and adds:

- `proprietary_codecs=true ffmpeg_branding=Chrome`: H.264, AAC and HEVC.
- `media_use_openh264=false`: no OpenH264 software encoder; Macs encode
  H.264 in hardware. This also turns off WebRTC's software H.264, so on
  Linux WebRTC sends VP8/VP9.
- `symbol_level=0`: no debug symbols.
- `treat_warnings_as_errors=false`: a newer macOS SDK than Chromium was
  tested with must not stop the build.

Before building, it checks that GN resolved the codec args as intended.

## Building on a machine of our own

The same build without the workflow, for the machine it runs on: a Mac with
Apple silicon or Linux on x86_64. On a MacBook Pro with an M4 Pro (14 cores)
a build of everything took 87 minutes.

It needs about 200 GB of free disk, `git`, `curl` and `python3`, and, to
publish, `gh` signed in with write access to this repository. On a Mac,
Xcode with its Metal toolchain (from Xcode 27 a download of its own:
`xcodebuild -downloadComponent MetalToolchain`); on Linux, `pkg-config`.

```sh
export CEF_VERSION='156.0.26+g8ea0c73+chromium-156.0.8078.88'
export CEF_WORK=/Volumes/Build/cef    # where to build; default ~/cef
tools/build-cef.sh local              # check out or update, build, make the distribution
tools/build-cef.sh publish-local      # create the release
```

- `local` checks out CEF and Chromium into `CEF_WORK`, or updates the tree
  that is there to the version, applies `patches/`, builds and puts the
  archive into `CEF_WORK/cef-distrib/<platform>`. `CEF_FRESH=true` deletes the tree
  first.
- `publish-local` creates the release from that archive. It wants this
  checkout to be `main` as it is on GitHub, with nothing changed, because
  the release notes name the commit. Another build of a released version
  needs a revision (`export CEF_REVISION=2`), as with the workflow. It
  releases only this machine's platform, and a release cannot take files
  later: prefer the workflow, which releases both.

Build releases only on a machine you would trust with Magnetite's signing
key: what it builds ends up in every Magnetite release.

## Our own machines as runners

### Linux

The workflow's Linux build runs on a self-hosted runner with the default
labels `self-hosted`, `Linux`, `X64`. The machine needs what a build on a
machine of our own needs (above): `git`, `curl`, `python3`, `pkg-config`,
and 200 GB free in the runner user's home, where the tree stays (`~/cef`).
Chromium's toolchain and sysroot come with the checkout; nothing else is
installed.

The same holds as for the Mac below: its builds end up in every Magnetite
release, every job runs as the runner's user, and the tree stays between
jobs, so one job could change every later one. Keep the machine to this
repository and physically secure, and run the runner as a user of its own.

### macOS

The workflow's Mac build runs on a Mac of our own, a self-hosted runner with
the label `cef-builder`. `build-server/setup-mac.sh` sets such a Mac up.

Run the script as an admin user at the Mac or over Screen Sharing; it
explains each step, asks before anything destructive and can be run again.
It keeps the Mac awake and starts it again after a power cut, turns FileVault
off so it starts unattended, creates `builder` (a standard user that never
logs in), installs Xcode's tools and starts GitHub's Actions runner at boot
as a launch daemon (`org.magnetitebrowser.actions-runner`). The builds use
the volume `cef`; the workflow keeps its tree in `/Volumes/cef/cef`.

- The machine's builds end up in every Magnetite release: keep it
  physically secure. With FileVault off, anyone who reaches it can change
  its disk.
- Once your laptop's key works, the script turns SSH password login off and
  lets in admins only; `builder` has no login shell. Screen Sharing is for
  your admin user only (a step in System Settings).
- The runner's token goes in through the environment, never on a command
  line (sudo would log it, `ps` would show it).
- Workflows here never start on pull requests, and workflows from forks need
  approval for all external contributors (Settings → Actions → General).
  The build job runs from `main` only, with a read-only token.
- Every job runs as `builder`, who owns the runner and the tree, and the
  tree is kept: a build that was tampered with could change every later
  one. A run with "fresh" starts from an empty tree again.
- An Xcode update changes what is built: the next run notices it and builds
  everything again. The release notes name the Xcode.
- Log: `/Users/builder/Library/Logs/actions-runner.log`. Stop:
  `sudo launchctl bootout system/org.magnetitebrowser.actions-runner`. Start:
  `sudo launchctl bootstrap system /Library/LaunchDaemons/org.magnetitebrowser.actions-runner.plist`.

## Licences

- This repository: European Union Public Licence v1.2 (`LICENSE`). `tools/build-cef.sh`
  is based on [OpenArch](https://github.com/dpfaffenbauer/OpenArch)'s build
  script, under the MIT licence (`LICENSES/OpenArch-MIT.txt`).
- The distributions: CEF is under the BSD licence, Chromium and its
  third-party code under theirs, listed in each archive's `CREDITS.html`.
  FFmpeg is under the LGPL 2.1 or later; its source is Chromium's
  `third_party/ffmpeg` at the Chromium version in the archive's name, and
  this repository holds what it takes to build it again.
