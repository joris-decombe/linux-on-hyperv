# Architecture

## The two constraints

Everything in this repo follows from two facts about a Linux guest on Hyper-V.

**There is no sound card.** Hyper-V emulates none. A stock guest has no output
device at all. Hyper-V's own answer is Enhanced Session Mode, which is xrdp
serving an X11 session over `hv_sock` — usable only if your desktop is X11.

**There is no GPU, and no way to get one.** GPU-PV (what WSL2 uses) needs
`dxgkrnl`, which Microsoft ships only in the WSL kernel — and it yields
`/dev/dxg`, not a DRM node. DDA is a Windows Server feature. RemoteFX vGPU was
removed in 2020. So rendering is Mesa's `llvmpipe` on host CPU cores.

What the guest *does* get is `hyperv_drm`, a genuine KMS device — commonly at
`/dev/dri/card1`, with **no `renderD*` node beside it**. That distinction
matters: it is enough for a compositor to run on, and not enough for anything
that wants to import framebuffers through a render node.

## Why the desktop travels over RDP

The first version of this project captured the desktop with Sunshine and played
it in Moonlight. That works in principle and cost a lot in practice: software
capture plus software H.264 encode on a CPU-only guest, a pairing step, a
`setcap` for KMS access, a virtual audio sink built by hand — and a capture
backend that has to match the compositor. Sunshine's `wlr` backend speaks
`wlr-export-dmabuf`, which Hyprland does not implement, so it connected and
streamed black.

`gnome-remote-desktop` is an RDP server, and since GNOME 46 it does **Remote
Login**: a headless session created on demand for whoever connects, with a
virtual monitor sized by the client. That replaces the whole stack:

- **Audio** rides the RDP channel. No sound card needed, and no null sink.
- **Resolution** is negotiated per connection and renegotiated as the window
  resizes, so nothing is pinned by a kernel argument.
- **Clipboard** is part of the protocol.
- **The client** is `mstsc.exe`, already on the machine.

The Hyper-V console remains useful for exactly one thing: installing the OS,
and rescuing a guest whose network is broken.

## Remote Desktop vs Remote Login

`gnome-remote-desktop` runs in two modes that are easy to confuse, and only one
of them is what you want here.

| | Remote Desktop (`--headless`, per-user) | Remote Login (`--system`) |
|---|---|---|
| Scope | one user's session | the login screen, any user |
| Needs someone logged in first | yes | no |
| Service | user bus | `gnome-remote-desktop.service` (system) |
| Virtual monitor sized by client | partly | yes |
| GNOME version | earlier | **46+** |

`guest/lib/remote-desktop.sh` configures Remote Login and deliberately leaves
the per-user service alone. Both modes refuse to enable RDP without a TLS
certificate, so the kit generates a self-signed one — real TLS on the wire,
untrusted issuer, which is why the generated `.rdp` profile sets
`authentication level:i:0` rather than having `mstsc` refuse outright.

## Secure Boot

Hyper-V Generation 2 VMs default to the `MicrosoftWindows` Secure Boot
template, which will not validate a Linux bootloader. Fedora's shim *is* signed
— by Microsoft's third-party UEFI CA — so it boots with Secure Boot on under
the `MicrosoftUEFICertificateAuthority` template. `New-LinuxVM` selects that
template when you pass `-SecureBoot`, and turns Secure Boot off otherwise,
which is what unsigned installers need.

## The firewall rule

Fedora's firewalld denies inbound by default, so RDP needs a rule. The kit
derives the subnet from the address the guest actually holds rather than
hardcoding one, because the two switch types behave differently: the Hyper-V
Default Switch is NAT and renumbers on every host reboot, while an external
switch hands out a real LAN address. Deriving it means the same code is correct
on both — and it scopes the rule to that subnet instead of opening 3389 wide.

## What is deliberately not here

- **A tiling window manager.** That was the previous design, and the source of
  most of its difficulty. Anyone wanting tiling on this base is better served
  by a GNOME extension than by swapping the compositor, because the compositor
  is exactly what made capture hard.

## Unattended installs, and which media can do them

Anaconda scans for a volume labeled `OEMDRV` at startup and runs the `ks.cfg`
it finds there, with no kernel argument.

The kit builds that volume as an **ISO**, through IMAPI2 -- the disc-mastering
COM API Windows has shipped since Vista. The reason is privilege, not taste: a
VHDX has to be formatted, which means `Mount-VHD`, which attaches a disk to
Windows itself and requires Administrator. Membership of Hyper-V Administrators
does not cover it, and the failure is an opaque `0x80070522`. Building an ISO
needs nothing. ISO9660 uppercases its volume identifier, which is what Anaconda
matches on anyway. `New-KickstartDisk` still builds the VHDX form for anyone
who wants a writable volume.

**The media matters, and this is easy to get wrong.** A Fedora *Live* image
boots to a GNOME desktop and only starts Anaconda when someone clicks "Install
to Hard Drive" -- so at boot nothing scans for `OEMDRV` and the kickstart is
silently ignored. A *netinst* or DVD image boots straight into Anaconda, which
does scan. `Get-LinuxProfile` refuses the Live + unattended combination for
this reason.

The two media also want different kickstarts. A Live image installs its own
squashfs payload and ignores `%packages`; a netinst has no payload at all and
needs both an install source (`url --mirrorlist=...`) and a package
environment. `New-KickstartDisk -Live` omits both; otherwise it emits them, and
the desktop named in the profile chooses the environment group.
