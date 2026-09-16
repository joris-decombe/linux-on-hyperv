# linux-on-hyperv

Run a Linux desktop on Windows in a Hyper-V VM, with display, **sound**,
clipboard and a resolution that follows the window — over the Remote Desktop
client Windows already ships.

Three parts:

- **`windows/`** — a PowerShell module that builds the Hyper-V VM correctly the
  first time and opens the desktop.
- **`guest/`** — a shell kit you run once inside the VM that turns on GNOME's
  own RDP server and wires up the Hyper-V integration services.
- **`wsl/`** — a smaller kit for WSL, which cannot host a desktop but *can* run
  individual applications on the real GPU.

## Two routes, and what each can actually do

| | Hyper-V VM (`guest/`) | WSL (`wsl/`) |
|---|---|---|
| Full desktop | **yes** — GNOME over RDP | no |
| GPU | none, ever — `llvmpipe` | **yes** — D3D12 on the discrete GPU |
| Sound | RDP audio | WSLg, already working |
| Resize with the window | yes | n/a |
| Start-up | full OS boot | seconds |

They are complements, not alternatives: run the desktop in the VM, and send
anything GPU-hungry to WSL, where it appears as an ordinary Windows window.

Why WSL cannot host the desktop is not a matter of configuration — it was
measured, three ways, and the errors are recorded in
[`wsl/lib/remote-desktop.sh`](wsl/lib/remote-desktop.sh). The short version:
WSL exposes `/dev/dxg` but no DRM node, Mesa's `d3d12` driver renders
applications through `/dev/dxg` happily, and every compositor and
remote-desktop server wants a DRM device that is not there.
`gnome-remote-desktop` segfaults on `fd -1`.

## Why RDP, and not screen capture

Hyper-V gives a Linux guest a KMS display but **no sound card of any kind**,
and its Enhanced Session Mode is xrdp serving X11. So the built-in console can
show you a desktop but can never give you audio, a clipboard, or a resizable
window.

The obvious fix is to capture the desktop and stream it (Sunshine → Moonlight).
That works, but on a GPU-less VM it means software capture *and* software H.264
encode, plus a pairing dance, plus a capture backend that has to match your
compositor — and the resolution is still pinned by a kernel argument.

GNOME already solves all of this. `gnome-remote-desktop` **is** an RDP server,
and since GNOME 46 it offers **Remote Login**: a headless session created on
demand, with a virtual monitor sized by whatever client connects. So:

| | Sunshine/Moonlight | GNOME Remote Login |
|---|---|---|
| Video | yes | yes |
| Audio | yes, via a null sink you build | yes, built in |
| Clipboard | no | yes |
| Resize with the window | no (fixed mode) | **yes** |
| Client | install Moonlight | `mstsc.exe`, already present |
| Setup | pair by PIN, `setcap`, pick a capture backend | one command |

There is still no GPU in a Hyper-V Linux guest — GPU-PV is WSL-kernel only, DDA
is Windows Server only — so GNOME renders on `llvmpipe`. It is perfectly usable
for everything except 3D.

## Requirements

- Windows 10/11 Pro, Enterprise or Education with Hyper-V enabled
- A [Fedora Workstation](https://fedoraproject.org/workstation/) ISO (**GNOME 46
  or newer** — Remote Login does not exist before that)
- ~30 GB free for the VM disk to grow into; 8 vCPU and 12 GB RAM by default

Give yourself Hyper-V access once, instead of a UAC prompt per command:

```powershell
Add-LocalGroupMember -Group 'Hyper-V Administrators' -Member $env:USERNAME
```

Then sign out and back in — group membership only applies to a new logon token.

## Profiles

One JSON file describes a whole setup; one command applies it.

```powershell
Import-Module .\windows\HyperVLinux.psd1
New-LinuxProfile -Interactive -Path profiles\my-setup.json   # asks, then writes
Invoke-LinuxProfile -Path profiles\my-setup.json             # builds it
```

The wizard offers what your machine actually has -- the ISOs in your Downloads,
your virtual switches, your installed WSL distros -- rather than making you
type paths.

Reproducibility is the point rather than a nicety: comparing desktops means
building machines that differ in exactly one respect, and a file you can diff
is the only honest way to promise that. Keep one profile per candidate.

Profiles are validated before anything runs, against a known set of keys, so a
typo is an error rather than a VM built subtly wrong:

```
Profile my-setup.json has problems:
  - unknown key 'vm.proccessorCount'
  - install.unattended with a Live ISO will not work: Live media boots to a
    desktop and never starts Anaconda, so the OEMDRV kickstart is never read.
    Use a netinst or DVD image.
  - guest.desktop 'hyprland' is not one of: gnome kde xfce cinnamon mate
```

Two shipped examples: [`profiles/fedora-gnome-vm.json`](profiles/fedora-gnome-vm.json)
and [`profiles/fedora-wsl-gpu.json`](profiles/fedora-wsl-gpu.json).

## Install

### 1. Create the VM

The unattended path is the better one, and not only for convenience: the
Hyper-V console does not propagate lock-key state, so Caps Lock silently
inverts case, and a password mistyped that way is only discovered later when
the login screen rejects it. From an **elevated** PowerShell:

```powershell
cd windows
.\Install-FedoraUnattended.ps1 -IsoPath D:\iso\Fedora-Workstation-Live-44-1.7.x86_64.iso
```

It prompts once for the new Linux user's password, hashes it locally, writes a
Kickstart onto an ISO labeled `OEMDRV` -- which Anaconda looks for by name,
with no kernel argument -- attaches it as a second DVD drive, and boots.
Nothing is typed into the VM.

**No elevation is required.** The ISO is built through IMAPI2, the
disc-mastering COM API built into Windows. (`New-KickstartDisk` builds the same
thing as a VHDX instead, and that *does* need Administrator, because `Mount-VHD`
attaches a disk to Windows itself -- which membership of Hyper-V Administrators
does not cover. Prefer the ISO.)

To drive the installer by hand instead:

```powershell
cd windows
.\New-LinuxVM.ps1 -IsoPath D:\iso\Fedora-Workstation-Live-x86_64.iso
```

Runs preflight, creates a Generation 2 VM with pinned memory and no automatic
checkpoints, and opens the Hyper-V console. Install Fedora there and reboot.

Fedora is signed for Microsoft's third-party UEFI CA, so `-SecureBoot` works —
but only under the `MicrosoftUEFICertificateAuthority` template, which is not
the one Hyper-V picks by default. The script handles that; Secure Boot is off
unless you ask for it.

Other switches: `-Name`, `-ProcessorCount`, `-MemoryGB`, `-DiskGB`,
`-SwitchName`, `-VMPath`, `-NestedVirtualization`.

### 2. Set up the guest

Inside Fedora:

```bash
sudo dnf install -y git
git clone https://github.com/joris-decombe/linux-on-hyperv.git
sudo bash linux-on-hyperv/guest/setup.sh
```

This repo is **private**, so that clone will ask for credentials — use a
personal access token as the password, or push the kit from Windows instead
(no GitHub involved):

```powershell
Copy-GuestKit -UserName <your-guest-user>
```

which needs `sudo systemctl enable --now sshd` in the guest first.

`--dry-run` shows every change without making one. `--only`/`--skip` narrow it
to a module: `integration`, `remote_desktop`, `audio`, `firewall`.

### 3. Open the desktop

```powershell
Import-Module .\windows\HyperVLinux.psd1
Start-LinuxDesktop
```

You get a GDM login screen over RDP. Log in with the guest's own username and
password — Remote Login has no separate RDP credentials.

## Commands

### Windows

| Command | What it does |
|---|---|
| `Test-HyperVHost` | Preflight only: access, Hyper-V, switch, ISO, disk space |
| `New-LinuxProfile` | Write a setup profile, interactively or from values |
| `Invoke-LinuxProfile` | Build a setup from a profile |
| `Get-LinuxProfile` | Read and validate a profile |
| `New-LinuxVM` | Create and start the VM |
| `New-KickstartIso` | Build an OEMDRV kickstart ISO (no elevation needed) |
| `New-KickstartDisk` | Same as a VHDX; needs Administrator |
| `Add-KickstartMedia` | Attach kickstart media to a VM |
| `New-LinuxPasswordHash` | Hash a password locally for Kickstart |
| `Add-KickstartDisk` | Attach one to an existing VM |
| `Connect-LinuxVM` | Open the Hyper-V console (basic session, no sound) |
| `Remove-LinuxVM` | Delete the VM, optionally its disks |
| `Get-LinuxVMAddress` | Guest IP, as reported by the KVP daemon |
| `Start-LinuxDesktop` | Open the VM desktop over RDP |
| `Start-WslApp` | Run a Linux app on the GPU, in its own Windows window |
| `Test-WslGpu` | Report which renderer WSL apps actually get |
| `Copy-GuestKit` | scp `guest/` into the VM |

### Guest

| Command | What it does |
|---|---|
| `guest/setup.sh` | Set the VM up; idempotent, re-runnable |
| `guest/doctor.sh` | Check every piece and print the fix for each failure |
| `wsl/setup.sh` | Set up GPU-accelerated apps in a WSL distro |
| `wsl/doctor.sh` | Same, for WSL |
| `gpu-run <cmd>` | (in WSL) run an application on the discrete GPU |

### WSL

```bash
sudo dnf install -y git
git clone https://github.com/joris-decombe/linux-on-hyperv.git
sudo bash linux-on-hyperv/wsl/setup.sh
```

Then, from Windows or a WSL shell:

```bash
gpu-run firefox
```

Verified on Fedora 44 / WSL2: `gpu-run glxinfo -B` reports
`D3D12 (NVIDIA GeForce RTX 2070), Accelerated: yes`, where plain `glxinfo`
reports `llvmpipe`. Fedora's stock Mesa needs `GALLIUM_DRIVER=d3d12` set
explicitly — Ubuntu patches theirs to auto-detect — and picks the integrated
GPU unless told otherwise. `gpu-run` sets both.

## What gets changed in the guest

| Path | Why |
|---|---|
| `hyperv-daemons` package + units | So the host can read the guest's IP |
| `/var/lib/gnome-remote-desktop/certificates/` | Self-signed TLS cert; `grdctl` will not enable RDP without one |
| `grdctl --system rdp` settings | Turns on Remote Login |
| `gnome-remote-desktop.service` | The system (not per-user) unit |
| firewalld | TCP+UDP 3389, scoped to the guest's own subnet |

## Troubleshooting

Start with `sudo bash guest/doctor.sh`. More in
[docs/troubleshooting.md](docs/troubleshooting.md); the reasoning behind the
design is in [docs/architecture.md](docs/architecture.md).

## History

This started as an Omarchy project — Hyprland on Arch — and the git history
shows it. I dropped it once I learned who its creator is and read what he
posts. I don't want anything to do with him or his software, and that came
first; the technical case for leaving happened to be just as strong.

Omarchy was fine software. The problem was never Omarchy — it was the
combination of a tiling Wayland compositor with a hypervisor that offers no
GPU and no sound card, which forced a capture-and-stream design where every
piece had to be built by hand. Moving to GNOME replaced that whole stack with
an RDP server the desktop already ships, and made the window resizable as a
side effect. [docs/architecture.md](docs/architecture.md) has the reasoning.

Four real bugs turned up along the way, all of them found by running the thing
rather than reading it: a hardcoded `/dev/dri/card0` that misses `hyperv_drm`'s
`card1`, a Hyprland config key that silently voided the entire config file, a
systemd unit the Sunshine package does not actually ship, and a capture backend
Hyprland cannot feed. The Hyper-V half of that work carried over unchanged; the
guest half was replaced.

## License

MIT.
