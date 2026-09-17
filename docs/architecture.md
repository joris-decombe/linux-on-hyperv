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

## Where the password goes

Worth stating exactly, because "it's hashed" is not on its own an answer.

**In memory.** The password is read as a `SecureString`, then converted to a
**byte array** -- deliberately not a .NET string. A managed string is immutable
and cannot be erased: assigning `$null` drops a reference and leaves the
plaintext in the heap until collection, from where it can reach a pagefile, a
hibernation file or a crash dump. The byte array is zeroed in a `finally`, and
the unmanaged BSTR is released with `ZeroFreeBSTR`, which wipes before freeing
where `FreeBSTR` would leave the plaintext in freed memory.

**In transit.** The bytes are written to openssl's **stdin**, never to a command
line, so the password never appears in `Win32_Process` or `ps`. When openssl
comes from `wsl.exe` rather than the host PATH, the plaintext does cross into
the WSL VM -- still not on a command line, but through a second OS.

**At rest.** Only the SHA-512 crypt hash is written; the plaintext never
reaches disk. The hash lands in three places: the kickstart media, whose ACL is
inherited from the Hyper-V disk directory and covers Administrators, Hyper-V
Administrators, SYSTEM and the VM's own SID but *not* `Users`; the guest's
`/root/anaconda-ks.cfg`, which is root-only; and the guest's `/etc/shadow`,
which is where it belongs.

**The remaining weakness is the hash itself.** `openssl passwd -6` uses 5000
rounds, which is cheap to attack offline by anyone who can read the media.

So the media is cleaned up rather than left lying about. `Invoke-LinuxProfile`
waits for the install to finish and then ejects and deletes it; `-NoWait` opts
out, and `Remove-KickstartMedia` does the same job by hand. Ejecting works on a
running VM -- only *removing the drive* needs the VM off -- so the cleanup
costs no downtime. It also stops a stray installer boot from running
`clearpart --all` a second time.

Still, use a password you would be content to have attacked at 5000 rounds.

## Why the kickstart refuses to reinstall

An unattended install is a machine that partitions a disk with nobody
watching, and the media that tells it to do so outlives the install. It stays
attached. Anything that boots the installer again -- a changed boot order, a
stray firmware menu, a colleague pressing a key -- would find `clearpart --all`
and silently reinstall a working machine. That happened here once already.

Cleaning the media up afterwards helps, but it is a step that can be forgotten
or interrupted, and a safety property that depends on remembering something is
not a safety property. So the refusal lives in the kickstart itself.

The destructive commands are not written into the file at all. In their place
is `%include /tmp/linux-on-hyperv-partitioning`, and a `%pre` script decides
whether that file ever exists: it walks `/sys/block`, skips optical, loopback
and ram devices (the installer ISO and the kickstart disc are among them), and
asks `blkid` whether any real disk already carries a btrfs, ext, xfs, swap, LVM
or LUKS signature. If one does, it prints what it found and exits non-zero.
Under `--erroronfail` that stops Anaconda before it touches a partition table.
Anaconda runs `%pre` before resolving `%include`, which is what makes this
work.

`-AllowReinstall` writes `clearpart`/`autopart` inline and skips the guard --
for when wiping an installed machine is the actual intent.

The same reasoning applies to knowing when an install has finished. A reported
KVP address is not proof: Fedora's installer environment reports one too, so
treating it as completion can eject the kickstart media mid-install.
`Wait-LinuxInstall` waits for **sshd** instead, which the `%post` installs and
enables and which therefore cannot answer until the installed system has
booted. Without the guest tools there is no sshd coming, and `-AddressIsEnough`
falls back to the weaker signal deliberately rather than by accident.

## Do we need a password at all?

For automation, no. The SSH key does everything, and the guest kit runs over
it. If a machine only ever needs to be driven programmatically, the account
password could be locked outright.

For a desktop, yes. GNOME's Remote Login authenticates over RDP against the
real account through PAM, so a locked password means no graphical login --
which is the point of the VM.

So the password is not removed, it is **generated**: 24 characters from a
cryptographic RNG, never typed, never seen unless asked for. That makes the
install genuinely zero-touch, and it retires the last two hazards at once. A
password nobody types cannot be mistyped into a console with unsynced Caps
Lock. And 128 bits of entropy is not brute-forceable at any number of crypt
rounds, which was the standing weakness of the SHA-512 hash sitting on the
kickstart media.

It is stored with `ConvertFrom-SecureString`, i.e. DPAPI: decryptable only by
this Windows user on this machine, with inherited ACEs stripped so no other
local account can read even the ciphertext. That is deliberately the same trust
boundary as the VM's own disk -- anyone who can read one can read the other, so
the credential store is not the weak link.

`install.passwordMode = 'prompt'` restores the old behaviour for when the
password has to be one you already know.
