# Getting started

There are two ways to use this project. The first takes about ten minutes; the
second takes between one and two hours.

| | |
|---|---|
| **I only want the VM** | download [`omarchy-arm-utm-v2.zip`](https://archive.org/details/omarchy-arm-utm) (3.6 GB), verify it, unzip it, then open the `.utm` → [skip to the end](#if-you-only-want-the-vm) |
| **I want to build it myself** | `./build-omarchy-arm.sh` → continue reading |

## 1 · What you need

| Requirement | Why | How to check |
|---|---|---|
| **Apple Silicon Mac** | the VM is native aarch64 with HVF; Intel would need emulation and take much longer | `uname -m` → `arm64` |
| **macOS with Homebrew** | the script installs `qemu`, `expect`, and `aria2` if missing | `brew --version` |
| **UTM 4.7 or later** | this is where the VM is registered | `brew install --cask utm` |
| **Command Line Tools** | the script uses `git` and `python3`, provided by these tools on macOS | `xcode-select -p` |
| **~40 GB free space** | the build disk reaches ~13 GB and packaging needs more space | `df -h ~` |
| **A reliable connection** | downloads ~900 MB, then ~1,500 packages from the Arch Linux ARM repositories | |

If something is missing, install it like this:

```bash
xcode-select --install                    # git and python3
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install --cask utm
```

**You do not need `sudo`.** The script writes everything it needs inside its
working directory, and the three Homebrew dependencies are installed for your
user.

## 2 · What context the script needs

**None: it is a single file.** `build-omarchy-arm.sh` embeds the twelve files it
needs — the three installation stages, sanitizer, repair harness, optional-app
installer, update hook, VM configuration, two `expect` harnesses, QEMU launcher,
and `.utm` bundle generator — plus the README shipped inside the zip. It writes
them to disk when it starts. You can copy only that file to another Mac and it
will work the same way.

The only thing you can provide in advance, to save about 900 MB of downloads,
is the base images:

```bash
mkdir -p ~/omarchy-arm-build/dl
cp alpine-virt-*-aarch64.iso  ~/omarchy-arm-build/dl/alpine-virt-aarch64.iso
cp ArchLinuxARM-aarch64-*.tar.gz ~/omarchy-arm-build/dl/alarm-rootfs.tgz
```

The working directory is `~/omarchy-arm-build` unless you choose another one:

```bash
W=/Volumes/External/omarchy ./build-omarchy-arm.sh
```

## 3 · Run it

```bash
./build-omarchy-arm.sh
```

In a terminal it first asks six questions **pre-filled from your Mac**, so you
can usually press Enter for each:

```
━━━ configuration ━━━
  Time zone [Europe/Madrid]:              ← from /etc/localtime
  Console keyboard [us]:                  ← from macOS preferences
  Hyprland/Wayland keyboard [us]:
  VM cores [6]:                            ← half your performance cores
  VM memory (MiB) [12288]:                 ← based on your RAM
  Disk size [80G]:
```

The installer is English by default. To select Spanish, use either of these
forms:

```bash
./build-omarchy-arm.sh --lang es
OMARCHY_LANG=es ./build-omarchy-arm.sh
```

`--lang en` or `--lang es` applies to one run; the command-line option takes
precedence over `OMARCHY_LANG`. The language setting changes installer and
generated user-facing messages, not the VM's timezone, locale, or keyboard
settings. For example, the Spanish prompts look like this:

```
━━━ configuración ━━━
  Zona horaria [Europe/Madrid]:
  Teclado (consola) [es]:
  Teclado (Hyprland/Wayland) [es]:
```

Then it asks the three questions that **do change the result**:

- **Compile the 17 Omarchy tools that do not exist for ARM?** This takes about
  40 minutes. If you decline, the desktop still works, but `ttfx` (the
  screensaver), `tensaku` (annotating screenshots), `omacalc`, `omacut`,
  `omawrite`, `aether`, `cliamp`, and `omarchy-nvim` will be missing. They can
  be added later with `yay -S <package>`.

- **Include OBS Studio and Pinta?** They are free software, so they can be
  shipped in the image, and the distributed image includes them. They add about
  50 minutes: OBS is built from source (without its browser plugin, whose CEF is
  x86-only) and Pinta needs Microsoft's official arm64 .NET. If you decline,
  install them later from inside the VM with `omarchy-arm-extras pinta obs`.

- **Prepare the image for distribution?**
  - **No** (the default): the VM keeps your user and configuration, skips the
    `sanitize` and `package` phases, and saves about 30 minutes.
  - **Yes**: renames the user to `omarchy`, removes SSH keys, Git identity, and
    histories, and creates a `.zip` of about 6.5 GB with its `sha256` checksum.

To accept all defaults without answering:

```bash
./build-omarchy-arm.sh --yes        # defaults, without prompts
```

Without a terminal (cron, CI, or `nohup`) it also does not ask questions.

## 4 · What happens and how long it takes

Measured on an M3 Max, with the tools compiled and without OBS or Pinta:

| Phase | What it does | Time |
|---|---|---|
| `deps` | checks the Mac and installs qemu/expect/aria2 if missing | seconds |
| `fetch` | downloads Alpine and the ALARM rootfs, verifying sha256 and MD5 | ~2 min |
| `prepare` | computes the package list by comparing the live Omarchy branch with the ARM index | ~10 s |
| `build` | boots Alpine headless, partitions, deploys the rootfs, and runs the three chroot stages | **~40 min** |
| `utm` | writes the `.utm` bundle and registers it in UTM | ~1 min |
| `verify` | checks inside the VM that Hyprland, quickshell, and ~435 commands are present | ~4 min |
| `sanitize` | copies the disk and cleans it for distribution | ~10 min |
| `package` | compacts the qcow2, creates the bundle, and compresses it | ~3 min |

**Total: about 57 minutes**, producing a 4.1 GB `.zip`. Including OBS Studio
and Pinta — as in the distributed image — adds about **50 minutes** to
`build`: OBS is compiled entirely from source and is the slowest part.

The working directory can use **21 GB** during the process.

The `build` phase prints little while it works. To follow it:

```bash
tail -f ~/omarchy-arm-build/logs/build.log
```

## 5 · If something fails

Every phase is resumable, so you do **not** have to start over:

```bash
./build-omarchy-arm.sh --from build   # resume from that phase
./build-omarchy-arm.sh --only package # repeat one phase
./build-omarchy-arm.sh --list         # show valid phase names
```

Resuming does **not** ask again; it reuses your previous decisions.

Logs are stored in `~/omarchy-arm-build/logs/`, one per phase. The `build` log
is the important one: it contains the complete output from all three stages
inside the guest, with `[stage1]`, `[stage2]`, and `[stage3]` prefixes.

Two deliberate behaviors are worth knowing:

- If a build disk already exists, `build` does **not** delete it: it moves it to
  `omarchy-arm.qcow2.anterior` and starts a new one.
- If UTM already has a VM with the same name, the script does **not** delete it:
  it registers the new one with the time appended to its name.

One behavior may be surprising: UTM must be restarted to recognize a new bundle,
because it scans `Documents` only when the application starts. If VMs are
running, the script warns you and lets you decide; in unattended mode it does
not stop them and tells you to import the bundle manually with **File → Import**.

## 6 · When it finishes

The VM appears in UTM and starts without asking for a password.

The **Option (⌥) key acts as SUPER**, because macOS captures Cmd before UTM
receives it. ⌥+Space opens the Omarchy menu, ⌥+Return opens a terminal, and
⌥+K shows the complete keybinding list.

To install apps that are not included (1Password, Obsidian, Typora, LocalSend,
and Chrome):

```bash
omarchy-arm-extras --list
omarchy-arm-extras            # interactive menu
```

## 7 · Undo it

```bash
rm -rf ~/omarchy-arm-build           # the entire working directory
```

Then delete the VM from UTM itself. The script did not touch anything else on
your Mac.

---

## If you only want the VM

Download **`omarchy-arm-utm-v2.zip`** from
https://archive.org/details/omarchy-arm-utm (3.6 GB), then:

```bash
shasum -a 256 -c omarchy-arm-utm-v2.zip.sha256
unzip omarchy-arm-utm-v2.zip
open "Omarchy ARM.utm"
```

User `omarchy`, password `omarchy` (also root). **Change it immediately with
`passwd`.** The rest is in the `LEEME.md` included in the zip.

Check the download before extracting it:

```bash
shasum -a 256 -c omarchy-arm-utm-v2.zip.sha256
```
