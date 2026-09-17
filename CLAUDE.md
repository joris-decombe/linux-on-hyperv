# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Tooling to run a Linux desktop on Windows: a PowerShell module that builds
Hyper-V VMs and unattended installs, plus shell kits that run inside the guest
(or inside WSL). There is no build step, no package manager, and no test
framework — everything is scripts that act on a real hypervisor.

## Verification

There is no test suite. What exists instead, and what to run after editing:

```powershell
# PowerShell: parse every file (this is the closest thing to a compiler here)
Get-ChildItem -Recurse windows -Include *.ps1,*.psm1,*.psd1 | ForEach-Object {
    $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e)
    if ($e) { "FAIL $($_.Name)"; $e | ForEach-Object { "  " + $_.Message } }
}
Test-ModuleManifest windows\HyperVLinux.psd1
Import-Module .\windows\HyperVLinux.psd1 -Force   # catches load-order and export mistakes
```

```bash
# Shell: syntax-check both kits
for f in guest/setup.sh guest/doctor.sh guest/lib/*.sh wsl/setup.sh wsl/doctor.sh wsl/lib/*.sh; do bash -n "$f" || echo "FAIL $f"; done
```

Both kits support `--dry-run`, `--only <module>` and `--skip <module>`; use
`--dry-run` to exercise a change without touching a machine. `doctor.sh` in
either kit is read-only and reports what is actually configured.

Pure functions can be tested directly: `New-KickstartContent` builds the
ks.cfg text and touches nothing, so generated output can be inspected without
building media. The `%pre` guard inside it has been verified by extracting the
block and running it against a stubbed `blkid`.

## Architecture

Three kits that do not share a runtime, only conventions:

- **`windows/`** — a PowerShell module (`HyperVLinux.psd1`). `lib/*.ps1` are
  dot-sourced in the order listed in `HyperVLinux.psm1`; `Common.ps1` must come
  first because everything else uses its logging helpers and `$script:VMDefaults`.
- **`guest/`** — runs with `sudo` inside a VM. Modules in `LH_MODULES`
  (`guest/setup.sh`) run in order.
- **`wsl/`** — runs with `sudo` inside a WSL distro. **It sources
  `guest/lib/common.sh`, `desktop.sh` and `remote-desktop.sh`** so the two kits
  cannot drift; only its own modules live in `wsl/lib/`.

The guest kit is not meant to be run by hand. `New-KickstartContent -Provision`
emits a `%post` that clones this repo into the installed system and installs a
**first-boot systemd oneshot** which runs `guest/setup.sh`. That split is
forced: `%post` is chrooted with no systemd, no D-Bus and no loaded SELinux
policy, so `grdctl` cannot enable Remote Login there and `restorecon` silently
does nothing — both work one boot later. The unit's stamp file is written by
`ExecStartPost`, so a failed provision retries on the next boot instead of
marking a half-configured machine done.

`profiles/*.json` is the user-facing entry point: one file describes a whole
setup, `Invoke-LinuxProfile` applies it. Profiles are validated against a known
key set in `Get-LinuxProfileDefault` before anything runs — add a key there or
it will be rejected as a typo.

## Constraints that explain the design

These were all established by measurement. Re-deriving them costs hours.

- **A Hyper-V Linux guest has no GPU and no sound card.** GPU-PV is WSL-kernel
  only, DDA is Windows Server only. Rendering is `llvmpipe`; audio can only
  travel over the remote protocol.
- **The desktop travels over RDP**, served by the guest's own
  `gnome-remote-desktop`, not by screen capture. Only **GNOME 46+** "Remote
  Login" (`grdctl --system`) gives a headless session whose virtual monitor is
  sized by the client — that is what makes the window resizable. KDE's KRdp
  cannot do headless login; xrdp is X11-only and so cannot serve a Wayland
  desktop at all. `guest/lib/desktop.sh` encodes which backend each desktop gets.
- **Remote Login still needs RDP credentials set.** It ends at a GDM login
  screen, so it looks as though PAM is the only authentication involved and
  `set-credentials` belongs to the per-user Desktop Sharing mode. It does not:
  the credentials are a gate in front of the daemon, and with them empty
  `gnome-remote-desktop` starts cleanly, logs `RDP server started`, holds 3389
  open, and refuses every client with `Credentials are not set, denying
  client`. We set them to the account's own password so there is one secret;
  the unattended install passes it in through the kickstart.
- **WSL can run GPU-accelerated *applications* but not a desktop.** It has
  `/dev/dxg` and no DRM node, so Mesa's `d3d12` driver works for apps while
  `gnome-remote-desktop` segfaults on `fd -1`. See the comment block at the top
  of `wsl/lib/remote-desktop.sh` for the three approaches tried and their errors.
  Fedora needs `GALLIUM_DRIVER=d3d12` set explicitly or it silently uses
  llvmpipe; it also picks the integrated GPU unless told otherwise.
- **Unattended installs need netinst or DVD media, never Live.** Anaconda scans
  for a volume labeled `OEMDRV` when it starts; Live media boots to a desktop
  and only starts Anaconda when someone clicks Install, so the kickstart is
  silently ignored. `Get-LinuxProfile` refuses that combination.

## Traps that have already caused bugs here

- **Piping to a native command appends `[Environment]::NewLine`.** Feeding a
  password to `openssl passwd -6 -stdin` by pipeline hashes `password\r`, which
  produces an install nobody can log into. Write to
  `$proc.StandardInput.BaseStream` instead. `New-LinuxPasswordHash` now
  re-hashes with its own salt to verify before returning.
- **Hyper-V cmdlets are non-terminating by default.** Without
  `-ErrorAction Stop`, a failed `Mount-VHD` is followed by a cheerful success
  message. Several functions reported building media they had not built.
- **Module-internal functions are not in a script's scope.** `Test-Elevated`
  and the `Write-*` helpers live in `lib/Common.ps1` and are not exported;
  scripts under `windows/` must dot-source it after `Import-Module`.
- **`Mount-VHD` needs true Administrator**, which membership of *Hyper-V
  Administrators* does not grant (the error is an opaque `0x80070522`).
  Everything else in the module works unelevated for group members, after a
  sign-out and back in. This is why kickstart media is built as an ISO via
  IMAPI2 rather than a VHDX.
- **Windows PowerShell 5.1 is not PowerShell 7.** The module declares
  `#Requires -Version 5.1` and people do run it from `powershell.exe`, where
  `RandomNumberGenerator::Fill` and `ProcessStartInfo.ArgumentList` simply do
  not exist. Test anything using .NET APIs under `powershell.exe`, not only
  `pwsh`.
- **Never `catch { continue }` over a whole strategy.** Doing so turned "this
  .NET API is missing on 5.1" into "No openssl found", which pointed the
  investigation at the wrong machine entirely. Collect failures and report them.
- **Substring guards.** `if ('New-LinuxPassword' -notin $s)` is always false
  when `New-LinuxPasswordHash` is present. Match whole names.
- **`Server accepts key` then `Permission denied` is usually the client.** It
  cost four wrong diagnoses here — SELinux, then ownership, both "fixed" in the
  guest, neither the cause. ssh offers the *public* half read from `.pub`, which
  needs no passphrase, so the server matches it and says yes; the failure comes
  one step later, when ssh must sign with the private half and cannot decrypt
  it. A passphrase-protected key with no agent and no TTY produces this exactly.
  Check `ssh-keygen -y -f <key>` before touching anything server-side. The
  first-boot script's `chown`/`restorecon` are kept as cheap insurance, but they
  fixed nothing and are not evidence of anything.
- **An open port is not a working server.** `Wait-LinuxDesktop` used a bare TCP
  connect on 3389 and printed "Ready. Nothing else needs doing in the guest"
  over a daemon that was denying every client. Health checks here must complete
  a protocol exchange, not a handshake-free connect — `Test-RdpHandshake` sends
  an X.224 Connection Request and requires a Connection Confirm (`0xD0`) back.
- **Plaintext on the install media.** `-RdpPassword` puts the account password
  in the kickstart in the clear, alongside the SHA-512 hash that was already
  there. That is a real step down and it is deliberate: the daemon needs the
  password, not a hash. The guest shreds its copy once `grdctl` has it, and the
  media should be removed after provisioning.
- **Line endings are pinned in `.gitattributes`** — LF everywhere, CRLF for
  PowerShell. Shell scripts with CRLF fail in the guest on the shebang and on
  every heredoc terminator.

## Conventions

Comments explain *why*, especially where the code looks odd — most of the
oddities are workarounds for something measured above, and a comment saying so
is what stops the next person "simplifying" it back into a bug. Commit messages
are long-form and explain the reasoning, not just the change.

Anything destructive is guarded rather than documented: the kickstart's `%pre`
refuses to wipe a disk that already carries a filesystem, and `-AllowReinstall`
is the explicit opt-out. Prefer that shape over a warning in a README.
