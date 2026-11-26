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
| `card-autofill-touch-bar.patch` | Credit card suggestions in a page no longer end the program on macOS. Before showing them, Chromium hands them to the Touch Bar of the page's window, and took every browser's window for one of Chrome's own: it dereferenced the window's Chrome native widget, which a browser in a CEF Views window does not have (`browser_native_widget()` is null there), so the first click into a card field with a saved card crashed. With the patch such a window gets no Touch Bar suggestions and the page's suggestion list shows as usual. A change to Chromium (`patch/patches/magnetite_card_autofill_touch_bar.patch`, added by this patch). macOS only. Tried on macOS on Apple silicon: a click into the card number field of a form with a saved card ended the program with the unpatched framework, and the program stays up with the patched one; the suggestion list itself was not looked at, as Chromium shows it only in the window in front. |
| `extension-last-active.patch` | Which browser an extension is given as the window focused last (`tabs.query({lastFocusedWindow: true})`, `windows.getLastFocused`; Dark Reader finds the page in front so). Chromium takes the browser that turned active last, and a browser in a child window paints as active whenever its parent window does: all of the application's pages turned active one after the other each time the main window's state changed (on macOS with every extension popup), and the last of them, not the page in front, was handed to the extension; on Linux each page turned active once and never again. With the patch a browser in a child window follows its own window's activation only, and an explicit activation (`BrowserView::Activate`, which DevTools' `Target.activateTarget` and `chrome.windows.update({focused: true})` reach) moves it to the front of that order also when it is active already, synchronously on every platform. A change to Chromium (`patch/patches/magnetite_extension_last_active.patch`, added by this patch). The same code on every platform. Tried on macOS on Apple silicon with real clicks and Dark Reader 4.9.135: the page in front after every tab switch, ten openings in a row, keys still go to the page. Not tried on Linux or Windows. |
| `extension-manifest-v2.patch` | Manifest V2 extensions install and run. Chromium 156 refuses to install one, turns installed ones off at every start and keeps them from being turned on again, and has no switch or policy left to keep them. All three ask `ShouldDisableLegacyExtensions()` in `extensions/browser/manifest_v2_handler.cc`, which the patch makes answer no, for Manifest V2 extensions from every source; an extension Chromium turned off for that reason comes back on at the next start. Chromium's Manifest V2 code itself is still there, and its own tests run it by turning the same check off. The Chrome Web Store no longer offers Manifest V2 extensions, so they are loaded unpacked (`chrome://extensions`, Developer mode), where Chromium still lists a note that Manifest V2 is deprecated under the extension's errors. Chromium also switches every extension added with "Load unpacked" off while Developer mode is off (`ExtensionManagement::IsAllowedByUnpackedDeveloperModePolicy`; `--load-extension` and DevTools' `Extensions.loadUnpacked` are exempt). Started with `--magnetite-keep-unpacked-extensions` (Magnetite passes it when its setting for it is on, off by default), such an extension stays on then, Manifest V3 ones too. That is a risk the user accepts: it also keeps on an unpacked extension another program put into the profile, which the extensions page then only lists for review. A change to Chromium (`patch/patches/magnetite_extension_manifest_v2.patch`, added by this patch). The same code on every platform. Tried on macOS on Apple silicon with uBlock Origin 1.77.0 and a Manifest V2 test extension: both run, block and open their popups, and stay on through a restart; not tried on Linux or Windows. |
| `extension-tab.patch` | The tab an extension opens with `chrome.tabs.create`, and each tab of a normal window it opens with `chrome.windows.create`, is the page the application shows. A browser an application hosts in its own views has no tab strip, so Chromium put such a tab in a Chrome window of its own; Magnetite hid that window, loaded the address again in a tab of its own and closed it, and the extension was left with the id of a closed tab or window. With the patch the tab becomes a popup browser of the page the extension API chose (for a window: the one focused last for its first address, the tab before for each further one): the client is asked in `CefLifeSpanHandler::OnBeforePopup` with `popup_id` -1 (no popup of a page has it), the disposition saying whether the tab is in front, and in `extra_info` the integer `magnetite_tab_index` (the `index` asked for among the opener's tabs, -1 for none; 1 for a window's further addresses) and the boolean `magnetite_tab_pinned`, both taken out again before the browser is made. It gets the tab's view in `CefBrowserViewDelegate::OnPopupBrowserViewCreated`, where it has to put the view in a window at once. Returning true from `OnBeforePopup` leaves the tab to Chromium as before; for a window, leaving its first tab to Chromium leaves the whole window to it. `chrome.windows.create` hands back the first tab's browser as the new window. A tab asked for as pinned is pinned in Chromium as well. When an extension pins or unpins a tab with `chrome.tabs.update`, the tab's client hears of it after the call, through `CefClient::OnProcessMessageReceived`, as the message `magnetite.tab-pinned` with one bool argument and `PID_BROWSER` as its source, which no renderer's message has. A window that is to take an existing tab (`tabId`), has no address, is an app's, is to have its creator as opener (`setSelfAsOpener`) or is in another profile than the window focused last goes Chromium's way. The CEF API stays as it is. A change to Chromium too (`patch/patches/magnetite_extension_tab.patch`, added by this patch). The same code on every platform. Built and tried on macOS on Apple silicon (CEF 156.0.31 with Chromium 156.0.8078.111): `index` 0 and 1 and `pinned` reached the client, the windows from `chrome.windows.create` stayed open with their ids good for `chrome.windows.get`, `chrome.tabs.update` with `pinned` reached the client both ways. Not tried on Linux or Windows. |
| `extension-trigger-action.patch` | DevTools' `Extensions.triggerAction` answers an error for an extension that the tab's browser has no action for, such as one that is not loaded. Chromium dereferenced a null pointer there and ended the whole program; Magnetite opens every extension popup through this call. A change to Chromium (`patch/patches/magnetite_extension_trigger_action.patch`, added by this patch). The same code on every platform. Tried on macOS on Apple silicon with an id that is not loaded; not tried on Linux or Windows. |
| `extension-views-excluded.patch` | Extension popups, side panels, background pages and offscreen documents are hosted by Chrome and never get a CEF browser. CEF waited for one all the same, which delayed every extension popup; with the patch it does not. |
| `extension-window-type.patch` | To extensions, a page's window is a "normal" window. CEF makes the browser an application hosts in its own views as one of Chromium's popup type, to leave out Chrome's controls, and the extension API passed that on: `chrome.windows` called every such window "popup", and `chrome.tabs.query({windowType: "normal"})` found no tab. An extension that looks for the active tab that way (Dark Reader) took the page for `about:blank`. With the patch such a browser counts as "normal"; a window an extension opens with `chrome.windows.create({type: "popup"})` stays "popup". A change to Chromium (`patch/patches/magnetite_extension_window_type.patch`, added by this patch). The same code on every platform; not built or tried on any yet. |
| `rounded-corners.patch` | A window with a parent can have round corners, as Magnetite's pages have on macOS. CEF has no call for it, and a page is a window of its own, so nothing inside the page can round it. With the patch `CefWindow::SetThemeColor` with the colour id -1 (no colour has it) takes the radius in DIP in place of a colour, 0 for square corners, and sets it on the layer of the window, which cuts everything the window shows, anti-aliased. A frameless window with a parent is made translucent, so the parent shows outside the corners. Under X11 without a compositing manager a window cannot be translucent and would show its background outside the corners; there it is cut to them instead (X11's shape extension, without anti-aliasing), and back to a rectangle at radius 0. The CEF API stays as it is. Linux only. |
| `tab-capture-state.patch` | Tells the client when a page starts or stops sharing a tab (`getDisplayMedia` with a tab as the source), so Magnetite can mark the shared tab. CEF has no callback for it. Chrome's tab-sharing UI registers the shared tab as mirrored while it is shared; the patch passes each change to the shared tab's client through `CefClient::OnProcessMessageReceived`, as the message `magnetite.tab-capture` with one bool argument and `PID_BROWSER` as its source, which no renderer's message has. The CEF API stays as it is, so the bindings need no change. The same code on every platform; not built or tried on any yet. |
| `tab-share-instead.patch` | The client can share another tab in place of the tab a page shares, as Chrome's "Share this tab instead" button does. CEF has no call for it. While a page shares a tab, Chrome puts its tab-sharing infobar on every tab of the page's profile, with that button where the switch is possible and allowed. The patch lets the client press it: `CefFrame::SendProcessMessage` with `PID_BROWSER` as the target, which CEF does not take otherwise, and the message `magnetite.share-tab-instead`, sent on a frame of the tab to share, runs the button of that tab's infobar on the UI thread. Where the infobar has no such button (the shared tab itself, the capturing tab, a page that asked for no switching) nothing happens. The CEF API stays as it is. The same code on every platform. Built and tried on macOS on Apple silicon (CEF 156.0.31 with Chromium 156.0.8078.100): Magnetite's sidebar button moved a running tab share to another tab and back, the capture stayed live. Not tried on Linux or Windows. |
| `tab-strip-pinned.patch` | The client says whether a browser's tab is pinned in Chromium, so that extensions see the tabs the application pins as pinned (`tab.pinned`, `chrome.tabs.query({pinned: true})`). An application that hosts every page as a browser of its own keeps its pinned tabs itself, and Chromium's tab of each page was never pinned. With the patch `CefFrame::SendProcessMessage` with `PID_BROWSER` as the target and the message `magnetite.set-tab-pinned`, with one bool argument, pins or unpins the tab of the frame's browser on the UI thread (Chromium's own `PinTab`/`UnpinTab`, which tells extensions). Applies after `tab-share-instead.patch`, next to whose message it takes its own. The CEF API stays as it is. The same code on every platform. Built and tried on macOS on Apple silicon (CEF 156.0.31 with Chromium 156.0.8078.111): tabs pinned in Magnetite, favorites included, read as pinned to an extension, also a tab whose page was made after it was pinned. Not tried on Linux or Windows. |
| `transparent-pages.patch` | A page in a window with a parent can be see-through, and the pages in a window can have round corners of their own. CEF made every windowed browser's background opaque, so a small page laid over another one (Magnetite's strip to resize a web panel, along the panel's edge) always covered it. With the patch a `CefBrowserSettings::background_color` whose alpha is 0 but which is not 0 itself (0 means unset) makes the browser fully transparent, as CEF already allows for windowless browsers; the window has to be translucent, which a frameless window with a parent is with `rounded-corners.patch`. `CefWindow::SetThemeColor` with the colour id -2 takes a radius in DIP for the corners of each page in the window (each `views::WebView`, through its `NativeViewHost`), for a page that does not fill its window and so is not rounded by the window's own corners (id -1). The CEF API stays as it is. Applies after `rounded-corners.patch`. Linux only. |
| `wayland-child-windows.patch` | Under Wayland, a window with a parent is a subsurface of that parent, which keeps its place in it; Magnetite's pages are such windows. CEF made it a toplevel and set it up with X11 calls, the last of which stops the program under Wayland. With the patch those calls run under X11 only. Linux only. |
| `wayland-frameless.patch` | Under Wayland, a frameless window asks the compositor to leave its frame to the window (client-side decorations). CEF removed the frame on Windows and X11 only, so compositors such as COSMIC and KDE drew their title bar above Magnetite's own. Applies after `wayland-child-windows.patch`, whose `UsesX11()` it uses. Linux only. |
| `webauthn-keychain-group.patch` | The Touch ID authenticator for passkeys keeps its credentials in a keychain access group, and runs only in an app entitled to that group. Chromium names the group at build time after its own team and bundle identifier, which an app that embeds the framework cannot be entitled to. With the patch the group is the running app's application identifier (the `com.apple.application-identifier` entitlement of its signature) with `.webauthn`; an app signed without that entitlement gets Chromium's group as before, and no Touch ID authenticator. A change to Chromium (`patch/patches/magnetite_webauthn_keychain_group.patch`, added by this patch). macOS only. |
| `window-reparent.patch` | A window with a parent can get another one: each time it is shown, CEF asks its delegate for the parent again (`GetParentWindow`) and moves the window there. Magnetite moves a page from one of its windows to another this way, without loading it again. The move itself is Chromium's (`views::Widget::Reparent`), on every platform. Under Wayland it stopped before the page's subsurface, which is now made again in the new parent; that needs a change to Chromium (`patch/patches/magnetite_wayland_reparent.patch`, added by this patch). Applies after `wayland-child-windows.patch`, whose `UsesX11()` it uses. Made for Linux; macOS and Windows are untested. |
| `window-resize-border.patch` | A frameless window inside another one has no resize border. CEF keeps the outer 4 points of every frameless window for resizing it, also of one with a parent, which the client places and sizes itself: those points never reached the page in the window, and under X11 a press there handed the window to the window manager, which resized it behind the client's back. Magnetite's pages and web panels are such windows, and a web panel's resize strip lies along its window's edge. Linux only. |
| `window-share.patch` | Sharing one of the application's windows (`getDisplayMedia` or `chrome.desktopCapture` with a window as the source) shows the pages in it. Chromium recognised a window of its own and recorded only what that window's compositor draws; Magnetite's pages are child windows with compositors of their own, so a shared Magnetite window showed the sidebar beside an empty page area, although the picker's thumbnail showed the page. With the patch such a window is recorded by ScreenCaptureKit like the windows of other applications, which takes its child windows with it, and needs the screen recording permission like them. A change to Chromium (`patch/patches/magnetite_window_share.patch`, added by this patch). macOS only; nothing changes on Linux and Windows. Checked outside Chromium on macOS 27 on Apple silicon: ScreenCaptureKit's capture of a Magnetite window holds the page as the screen shows it; not built yet. |

Every archive names the patches it was built with in
`Release/magnetite-patches.txt`, one file name a line. Magnetite packages
the file next to the library and reads from it what its CEF can do: with
`wayland-child-windows.patch` in the list it runs as a Wayland client.

## Releases

One release per CEF version, tagged with it (`156.0.15`; another build of
the same version gets a revision, `156.0.15-2`), with:

- `cef_binary_<version>_macosarm64_minimal.tar.bz2`: the minimal distribution
  for macOS on Apple silicon, laid out like the official one on CEF's CDN;
- `cef_binary_<version>_macosx64_minimal.tar.bz2`: the same for macOS on
  Intel;
- `cef_binary_<version>_linux64_minimal.tar.bz2`: the same for Linux on
  x86_64;
- `cef_binary_<version>_linuxarm64_minimal.tar.bz2`: the same for Linux on
  arm64;
- `cef_binary_<version>_windows64_minimal.tar.bz2`: the same for Windows on
  x86_64, with one difference ("Windows, built on Linux");
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

The workflow builds and releases from `main` only. `main` is protected: it
changes by pull request only, once the pull request's CodeRabbit check has
passed (`.coderabbit.yaml`), for administrators as well, and cannot be
force-pushed or deleted. No person has to approve a pull request; a build
needs an approval of its own (below). Turn on immutable releases in the
repository's settings, so a published archive cannot be replaced.

The workflow builds on machines of ours (below), so the attestation says which
code was built by which workflow, not that the machine was clean.

A release built by hand on a machine of the maintainers has no attestation: GitHub
signs only what its workflows build. Its notes say so and name the commit
it was built from. What can be checked is the SHA-256, which Magnetite pins,
and the build itself, by building that commit again.

## Building a release

Actions → Build CEF → Run workflow on `main`, with the full CEF version, as
CEF names its archives (`156.0.15+gcf671c0+chromium-156.0.8078.80`).

The Chromium version in it is the one that gets built. Usually it is the one
the CEF commit was made for. For a Chromium security release that CEF has not
followed yet, name the newer Chromium version of the same branch with the
newest CEF commit (`156.0.30+g6028375+chromium-156.0.8078.100`) and, as the
CEF version has a release already, a revision. CEF's patches are put onto
that Chromium version; if one does not apply, the build stops and CEF has to
follow first. The release notes say which Chromium version CEF was made for.

The run then waits for approval: its jobs start once a reviewer of the
environment `build` (Settings → Environments) approved it on the run's page.

It builds the five platforms, each in one job on a machine of our own
(below; macOS on Intel on the Mac after macOS on Apple silicon, Linux on
arm64 on the Linux machine after Linux on x86_64, and Windows there after or
before them), and publishes one release once all are done. A failed
platform holds the release back. A platform's tree (Chromium with its git
history, CEF, the build output) stays on its machine, so a run does only
what changed since the last one:

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
  With them Chromium also builds the OpenH264 encoder
  (`media_use_openh264`, `rtc_use_h264`). WebRTC needs it to send H.264 at
  all: without it, it does not offer the hardware encoder either (seen: a
  screen shared in a Microsoft Teams call did not arrive).
- `symbol_level=0`: no debug symbols.
- `treat_warnings_as_errors=false`: a newer macOS SDK than Chromium was
  tested with must not stop the build.

Before building, it checks that GN resolved the codec args as intended.

## Building on a machine of our own

The same build without the workflow, for the machine it runs on: a Mac with
Apple silicon or Linux on x86_64. On a MacBook Pro with an M4 Pro (14 cores)
a build of everything took 87 minutes. With `CEF_TARGET` it builds for
another platform instead: `macosx64` on the Mac, `linuxarm64` or `windows64`
on Linux (the sections below).

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
  releases every archive in `CEF_WORK/cef-distrib`, which on a machine that
  builds two platforms (below) can be an older one's, and a release cannot
  take files later: prefer the workflow, which releases all of them.

Build releases only on a machine you would trust with Magnetite's signing
key: what it builds ends up in every Magnetite release.

## Windows, built on Linux

The workflow builds CEF for Windows on x86_64 on our Linux runner, with
Chromium's cross build (`docs/win_cross.md` in Chromium). CEF itself supports
building for Windows on Windows only.

What takes long runs on our runner, what is quick and needs Windows on
GitHub's:

1. **toolchain**, on GitHub's Windows runner, when "toolchain" is ticked:
   installs the Windows SDK Chromium asks for, packages it and the image's
   Visual Studio 2026 with depot_tools' `package_from_installed.py`, and
   hands the package to the next job as an encrypted artifact. Tick it for
   the first run on a runner; the package then stays on the Linux runner
   (`~/cef-windows64-toolchain`) until Chromium asks for another toolchain,
   which stops the build with a message.
2. **build-windows**, on our Linux runner: checks out a tree of its own
   (`~/cef-windows64`, another 200 GB), builds with `target_os="win"` and
   makes the distribution.
3. **check-windows**, on GitHub's Windows runner: loads the distribution's
   `libcef.dll` (`tools/build-cef.sh check`); without that there is no
   release. Whether CEF works, only Magnetite shows.

It needs:

- the repository secret `WIN_TOOLCHAIN_KEY`, any long random text
  (`openssl rand -base64 32`). Artifacts of a public repository are open to
  everyone, and Microsoft's files are not ours to give away, so the package
  travels encrypted and its artifact is deleted after a day;
- on the Linux runner `openssl`, `fusermount` and FUSE 2's library
  `libfuse.so.2` (the package `libfuse2t64` or `libfuse2` on Debian and
  Ubuntu, `fuse-libs` on Fedora, `fuse2` on Arch; FUSE 3 alone is not
  enough): Chromium mounts the Windows SDK in a folder that ignores case.

CEF's tools take the platform from the machine they run on.
`patches/cross/host-is-not-the-target.patch`, applied in the build for
Windows only, lets `tools/build-cef.sh` name it instead; with it CEF writes the GN args it
writes on Windows. The archive's patch list leaves it out.

Those args (CDM host verification, the CDM's storage ID, RLZ) are for Windows
and macOS only, and GN gives them to the toolchain of the building machine
too, where Chromium refuses them. `patches/cross/host-toolchain-args.patch`
switches them off there, as Chromium's own defaults do.

A build for Windows on Linux has no V8 context snapshot (Chromium leaves it
out of a build for another system), so the installer's archive takes
V8's plain snapshot as an input without naming the target that makes it, and
GN stops. `patches/cross/installer-snapshot-dep.patch` names it, as later
Chromium versions do.

For the same reason the archive holds `snapshot_blob.bin` where CEF's own
Windows archive holds `v8_context_snapshot.bin`
(`patches/cross/distrib-plain-snapshot.patch`): an app has to ship that file
next to `libcef.dll` instead.

Known or open:

- Chromium's cross build leaves out its assembler files, so Crashpad cannot
  report crashes (`docs/win_cross.md`).
- Whether Microsoft's licence lets us copy the runner's Visual Studio
  Enterprise to a machine of ours is not checked.
- By hand, on the Linux machine, with a package from `win-toolchain` in
  `~/cef-windows64-toolchain/<toolchain hash>/`:
  `CEF_TARGET=windows64 tools/build-cef.sh local`.

## Intel Macs and Linux on arm64

The workflow builds CEF for macOS on Intel on our Mac and for Linux on arm64
on our Linux runner, with Chromium's cross build for another architecture of
the same system, as CEF's official builds for these platforms are made
(`docs/automated_build_setup.md` in CEF). CEF's tools support both, so they
need no patch of their own:

- macOS on Intel (`CEF_TARGET=macosx64`): `CEF_ENABLE_AMD64` lets CEF
  configure a build for x64 on Apple silicon. It needs no Rosetta
  (`docs/mac_arm64.md` in Chromium).
- Linux on arm64 (`CEF_TARGET=linuxarm64`): CEF installs Chromium's Debian
  sysroot for arm64 next to the one for x86_64, which the build's own tools
  use. As in CEF's official builds for it, without ThinLTO and PGO
  (`use_thin_lto=false chrome_pgo_phase=0`).

Each shares the tree of its machine's own build: one checkout, with a build
output of its own (`out/Release_GN_x64` on the Mac, `out/Release_GN_arm64`
on Linux), so the machine needs room for a second build output, not a
second tree. Its job runs after the machine's own build and does not take
"fresh", which that job has done for the tree already. An update of the tree
is done once; each build output is configured again after it
(`magnetite-configured` in the output marks one that is).

Before the release, `tools/build-cef.sh check` loads each archive's library
on GitHub's runner for its platform (`macos-15-intel`, `ubuntu-24.04-arm`),
as for Windows; without that there is no release.

By hand, with the `CEF_WORK` of the machine's own build:
`CEF_TARGET=macosx64 tools/build-cef.sh local` on the Mac,
`CEF_TARGET=linuxarm64 tools/build-cef.sh local` on Linux. `CEF_FRESH=true`
deletes the tree both builds share.

## Our own machines as runners

### Linux

The workflow's Linux build runs on a self-hosted runner with the default
labels `self-hosted`, `Linux`, `X64`. The machine needs what a build on a
machine of our own needs (above): `git`, `curl`, `python3`, `pkg-config`,
and 200 GB free in the runner user's home, where the tree stays (`~/cef`),
plus room for the build for arm64 in it.
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
