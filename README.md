# Omarchy 4 for Apple Silicon — ready to run in UTM

Run the Omarchy 4 desktop on an Apple Silicon Mac without repartitioning your
disk or replacing macOS. This project provides a ready-made **aarch64 UTM
virtual machine** and, for contributors, a reproducible builder.

![Omarchy 4 desktop](shots/hires.png)

## Get the VM

**Recommended for most people. You do not need to build anything.**

You need:

- A Mac with Apple Silicon
- [UTM 4.7 or newer](https://mac.getutm.app)
- At least 15 GB free for download and setup; the VM's virtual disk can grow
  to 80 GB as you install applications and add files

Download **`omarchy-arm-utm-v2.zip`** and its checksum from the
[Internet Archive](https://archive.org/details/omarchy-arm-utm), then run:

```bash
shasum -a 256 -c omarchy-arm-utm-v2.zip.sha256
unzip omarchy-arm-utm-v2.zip
open "Omarchy ARM.utm"
```

Start the VM in UTM. It signs in automatically with these credentials:

| | |
|---|---|
| User | `omarchy` |
| Password | `omarchy` (also used for root) |

Open a terminal and run `passwd` after your first login.

> Download v2, not the older unsuffixed archive. v2 fixes the repeated update
> notifications, missing systemd user units, command paths, and clipboard
> integration problems found in the original image.

## What is included

- Arch Linux ARM running natively as aarch64 with Apple HVF acceleration
- Hyprland and the Omarchy 4 quickshell desktop
- Omarchy themes, configuration, and more than 400 `omarchy-*` commands
- ARM builds of tools that Omarchy does not publish for aarch64
- `qemu-guest-agent`, automatic `/mnt/share`, and a text clipboard bridge
- Working Omarchy updates with snapshots and ARM-specific update handling
- An installer for optional applications that cannot be redistributed in the VM

This is useful for exploring or using Omarchy while keeping the host Mac
untouched. There is no dual boot, reduced-security boot mode, or manual UTM
configuration.

## Before you start

This VM has a few practical limitations:

- Graphics are rendered in software. It is suitable for normal desktop use,
  development, and testing, but not video-heavy or 3D workloads.
- Resolution is fixed at boot and the guest is configured for one monitor.
- UTM's native clipboard sharing does not work with Hyprland. The included
  `omarchy-arm-clipboard` bridge handles text through a shared folder instead.
- `herdr` is unavailable because its required Zig version is no longer packaged.

For shared files, select a directory in **UTM → VM Settings → Sharing**. It
appears inside the VM at `/mnt/share`.

To enable the clipboard bridge:

```bash
omarchy-arm-clipboard --install
omarchy-arm-clipboard --host
```

Run the host command printed by the second command. Clipboard synchronization
is text-only.

## Mac keyboard shortcuts

macOS captures Cmd before UTM can pass it to the guest, so the image maps the
Mac keys like this:

| Mac key | Inside the VM |
|---|---|
| **Option (⌥)** | SUPER |
| Cmd (⌘) | ALT |

- **⌥+Space** — Omarchy menu
- **⌥+Return** — terminal
- **⌥+K** — keybinding reference

New prebuilt images should be released with a US English keyboard layout.
Interactive builds detect the selected macOS input source and let you confirm
or change it before the build starts.

Some Logitech keyboards can operate in either Mac or Windows mode. Use Mac
mode with the image's default Option-to-SUPER mapping. If you use Windows mode
and want the physical Windows key to remain SUPER, remove
`altwin:swap_lalt_lwin` from `~/.config/hypr/input.lua`, then run:

```bash
hyprctl reload
hyprctl configerrors
```

## Optional applications

1Password, Obsidian, Typora, LocalSend, and Google Chrome are not bundled
because redistributing their binaries would create licensing problems. Install
them from their official sources with the included helper:

```bash
omarchy-arm-extras --list
omarchy-arm-extras
omarchy-arm-extras --all
```

Spotify has no native Linux ARM client. Its web app works after installing
Chrome and Widevine:

```bash
omarchy-arm-extras chrome spotify-web
```

## Build it yourself — optional

The downloadable VM is the normal installation path. Build from source only if
you want to reproduce the image, change its contents, or contribute to the
project.

<details>
<summary>Show build instructions</summary>

### Requirements

- Apple Silicon Mac
- Homebrew and UTM 4.7+
- Xcode Command Line Tools
- About 40 GB free
- Roughly one to two hours, depending on network and optional packages

```bash
git clone https://github.com/khordoo/omarchy-apple-silicon-utm.git
cd omarchy-apple-silicon-utm
./build-omarchy-arm.sh
```

The installer is English by default. Spanish remains available:

```bash
./build-omarchy-arm.sh --lang es
OMARCHY_LANG=es ./build-omarchy-arm.sh
```

For an unattended build using the current defaults:

```bash
./build-omarchy-arm.sh --yes
```

For a reproducible US English release image, make the keyboard choice explicit
so it does not depend on the maintainer's selected macOS input source:

```bash
VM_TIMEZONE=UTC VM_KEYMAP=us VM_XKB=us ./build-omarchy-arm.sh --yes
```

The builder is a single self-contained Bash script. Its phases are resumable:

```bash
./build-omarchy-arm.sh --from build
./build-omarchy-arm.sh --only package
./build-omarchy-arm.sh --list
```

See [GETTING_STARTED.md](GETTING_STARTED.md) for requirements, timing,
language selection, troubleshooting, and the complete build walkthrough.

</details>

## Why this project exists

Omarchy's configuration is architecture-independent, but its official package
repository does not currently provide the aarch64 packages needed by the normal
installer. This project builds the equivalent Arch Linux ARM base, applies the
real Omarchy 4 configuration, and packages the result as a UTM VM.

It targets virtualization rather than bare metal. If you have an M1 or M2 Mac
and specifically want a native Asahi Linux installation with GPU support, see
[omarchy-mac](https://github.com/omarchy-mac/omarchy-mac).

## Documentation

- [English setup and build guide](GETTING_STARTED.md)
- [Guía en español](README.es.md)
- [Detailed Spanish build notes](EMPEZAR.md)
- [Technical write-up](ARTICULO.md) (Spanish)
- [Files included with the downloadable VM](dist/LEEME.md)

## Project status

The build has completed all eight phases from scratch, built all 17 ARM tool
ports, passed guest-side verification, and produced a bootable themed desktop.

## Project direction

This fork focuses on making the project easier to discover, install, and use:

- Maintain a clear English-first experience while preserving Spanish support
- Keep the downloadable VM as the simplest way to get started
- Add a guided first-run setup for changing the default credentials, locale,
  timezone, and keyboard settings without rebuilding the VM
- Improve first-run guidance and troubleshooting
- Expand release verification and document confirmed compatibility
- Keep pace with relevant Omarchy 4 and Arch Linux ARM changes

Ideas and testing feedback are welcome through GitHub issues.

## Acknowledgements

The core ARM64 builder and original prebuilt UTM image were created by
`@ggalancs`. This fork builds on that work, with a focus on English-first
localization, clearer onboarding, and continued usability improvements.

This is an unofficial community project and is not affiliated with Basecamp or
the Omarchy project. Omarchy, Arch Linux ARM, Hyprland, and bundled software
retain their respective licences.

Repository code is available under the [MIT License](LICENSE).
