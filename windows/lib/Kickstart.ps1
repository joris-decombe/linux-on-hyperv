<#
Unattended Fedora installs.

Anaconda scans at boot for a volume labeled OEMDRV and, finding a ks.cfg on it,
runs the install from that with no kernel argument and no keyboard. That is the
whole mechanism: attach a second small disk and the installer stops asking.

It is also the answer to the Hyper-V console's unsynced Caps Lock -- an install
nobody types into cannot be mistyped into -- and it makes the VMs reproducible,
which matters when comparing desktops on supposedly identical machines.

We build a FAT32 VHDX rather than an ISO because Windows has no genisoimage and
PowerShell can make a VHDX natively. FAT32 uppercases its label, which for once
is exactly what is wanted.
#>

<#
.SYNOPSIS
    Turn a password into the SHA-512 crypt hash Kickstart wants, without the
    plaintext reaching a command line or a transcript.

.EXAMPLE
    $hash = New-LinuxPasswordHash
#>
function New-LinuxPasswordHash {
    [CmdletBinding()]
    param([securestring]$Password)

    if (-not $Password) { $Password = Read-Host -AsSecureString 'Password for the new Linux user' }

    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password))
    try {
        if ($plain -match "[`r`n]") {
            throw 'The password contains a carriage return or newline, which cannot be hashed reliably.'
        }

        $hash = Invoke-OpensslPasswd -Plain $plain
        if (-not $hash) {
            throw 'No openssl found (tried PATH and wsl.exe). Generate the hash yourself with: openssl passwd -6'
        }

        # Verify the hash actually matches what was typed. Re-hashing with the
        # salt from the result must reproduce it exactly. This is not
        # ceremony: the previous implementation piped the password into
        # openssl, and PowerShell appends a newline to native-command stdin,
        # so what got hashed was "password`r" -- producing a hash nobody could
        # ever log in with, discovered only after a full unattended install.
        $parts = $hash -split '\$'
        if ($parts.Count -lt 4) { throw "openssl returned something that is not SHA-512 crypt: $hash" }
        $salt = $parts[2]
        $again = Invoke-OpensslPasswd -Plain $plain -Salt $salt
        if ($again -ne $hash) {
            throw "Hash did not verify (got two different results for the same password). Refusing to write a password nobody can use."
        }

        $hash
    } finally {
        $plain = $null
        [GC]::Collect()
    }
}

<#
Runs `openssl passwd -6` with the password on stdin and NO trailing newline.

The newline is the whole reason this is not a one-liner. PowerShell's pipeline
terminates each object with [Environment]::NewLine when feeding a native
command, so `$plain | openssl passwd -6 -stdin` hashes the password plus a
carriage return. Writing to the process's stdin directly and closing it is the
only way to be sure of what was hashed.
#>
function Invoke-OpensslPasswd {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Plain,
        [string]$Salt
    )

    $args = @('passwd', '-6')
    if ($Salt) { $args += @('-salt', $Salt) }
    $args += '-stdin'

    $candidates = @()
    if (Get-Command openssl -ErrorAction SilentlyContinue) {
        $candidates += , @{ File = 'openssl'; Args = $args }
    }
    if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
        $candidates += , @{ File = 'wsl.exe'; Args = @('-e', 'openssl') + $args }
    }

    foreach ($c in $candidates) {
        try {
            $psi = [Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $c.File
            foreach ($a in $c.Args) { $psi.ArgumentList.Add($a) }
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true

            $proc = [Diagnostics.Process]::Start($psi)
            # Write, do not WriteLine: no newline is the entire point.
            $proc.StandardInput.Write($Plain)
            $proc.StandardInput.Close()
            $out = $proc.StandardOutput.ReadToEnd()
            $proc.WaitForExit()
            if ($proc.ExitCode -eq 0 -and $out.Trim()) { return $out.Trim() }
        } catch {
            continue
        }
    }
    $null
}

<#
.SYNOPSIS
    Build an OEMDRV disk that installs Fedora unattended.

.EXAMPLE
    New-KickstartDisk -Path D:\vm\fedora-ks.vhdx -UserName joris `
        -PasswordHash (New-LinuxPasswordHash) -Hostname fedora
#>
function New-KickstartDisk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$UserName,
        # SHA-512 crypt, i.e. openssl passwd -6. See New-LinuxPasswordHash.
        [Parameter(Mandatory)][string]$PasswordHash,
        [string]$FullName = $UserName,
        [string]$Hostname = 'fedora',
        [string]$Timezone = 'Pacific/Auckland',
        [string]$KeyboardLayout = 'us',
        [string]$Locale = 'en_NZ.UTF-8',
        # Public key to drop in, so the guest is reachable without the console.
        [string]$AuthorizedKey,
        # A netinst image carries no packages, so it needs both an install
        # source and a package selection. A Live image carries its own payload
        # and ignores both -- pass -Live to leave them out.
        [string]$PackageEnvironment = '@^workstation-product-environment',
        [string]$ReleaseVersion = '44',
        [switch]$Live,
        # The installer's own encryption is off by default: a LUKS passphrase
        # must be typed at the console on every boot, before any network
        # exists, which defeats the point of an unattended machine.
        [switch]$EncryptDisk,
        [string]$EncryptionPassphrase,
        [switch]$Force
    )

    if ($PasswordHash -notmatch '^\$6\$') {
        throw 'PasswordHash does not look like SHA-512 crypt (it should start with $6$). Use New-LinuxPasswordHash.'
    }
    if ($EncryptDisk -and -not $EncryptionPassphrase) {
        throw 'EncryptDisk needs EncryptionPassphrase, and note it is stored in plaintext on the disk.'
    }

    $ks = [System.Collections.Generic.List[string]]::new()
    $ks.Add('# Generated by linux-on-hyperv. Anaconda finds this on a volume labeled OEMDRV.')
    $ks.Add("keyboard --xlayouts='$KeyboardLayout'")
    $ks.Add("lang $Locale")
    $ks.Add("timezone $Timezone --utc")
    $ks.Add("network --bootproto=dhcp --hostname=$Hostname --activate")
    # No root password: sudo through wheel is the Fedora default and leaves one
    # fewer credential to look after.
    $ks.Add('rootpw --lock')
    $ks.Add("user --name=$UserName --gecos=`"$FullName`" --groups=wheel --iscrypted --password=$PasswordHash")
    $ks.Add('clearpart --all --initlabel')
    if ($EncryptDisk) {
        $ks.Add("autopart --type=btrfs --encrypted --passphrase=$EncryptionPassphrase")
    } else {
        $ks.Add('autopart --type=btrfs')
    }
    $ks.Add('bootloader --location=mbr')
    if (-not $Live) {
        # netinst has no payload: without a source Anaconda stops and asks for
        # one, which is precisely the interaction we are removing. The
        # mirrorlist resolves $releasever/$basearch on the installer side.
        $ks.Add('url --mirrorlist="https://mirrors.fedoraproject.org/mirrorlist?repo=fedora-' + $ReleaseVersion + '&arch=x86_64"')
    }
    # gnome-initial-setup would otherwise ask again for everything set above.
    $ks.Add('firstboot --disable')
    if ($AuthorizedKey) {
        $ks.Add("sshkey --username=$UserName `"$AuthorizedKey`"")
    }
    $ks.Add('reboot')

    if (-not $Live -and $PackageEnvironment) {
        $ks.Add('')
        $ks.Add('%packages')
        $ks.Add($PackageEnvironment)
        $ks.Add('%end')
    }

    if (Test-Path -LiteralPath $Path) {
        if (-not $Force) { throw "Kickstart disk already exists: $Path (pass -Force to replace it)" }
        Dismount-VHD -Path $Path -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $Path -Force
    }

    # Attaching a VHD to the host needs real elevation -- Hyper-V
    # Administrators is not enough, and the failure is an opaque 0x80070522.
    # Say so before doing any work rather than after.
    if (-not (Test-Elevated)) {
        throw @"
Building the kickstart disk needs an elevated PowerShell.

Mount-VHD attaches the disk to Windows itself, which requires Administrator --
membership of Hyper-V Administrators does not cover it. Everything else in this
module works unelevated; this one step does not.

Run this in an elevated window:
    Import-Module '$(Join-Path (Split-Path -Parent $PSScriptRoot) 'HyperVLinux.psd1')'
    New-KickstartDisk -Path '$Path' -UserName '$UserName' -PasswordHash (New-LinuxPasswordHash)
"@
    }

    Write-Step 'Building the OEMDRV kickstart disk'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    New-VHD -Path $Path -SizeBytes 64MB -Fixed -ErrorAction Stop | Out-Null

    $mounted = $null
    try {
        # -ErrorAction Stop throughout: these are non-terminating by default,
        # so without it a failed mount is followed by a cheerful success line.
        $mounted = Mount-VHD -Path $Path -Passthru -ErrorAction Stop | Get-Disk
        Initialize-Disk -Number $mounted.Number -PartitionStyle MBR -Confirm:$false -ErrorAction Stop | Out-Null
        $partition = New-Partition -DiskNumber $mounted.Number -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
        # The label is the entire mechanism: Anaconda looks for OEMDRV by name.
        Format-Volume -Partition $partition -FileSystem FAT32 -NewFileSystemLabel 'OEMDRV' -Confirm:$false -ErrorAction Stop | Out-Null

        $drive = "$($partition.DriveLetter):"
        # Read by a Linux installer: LF endings, no BOM.
        $text = ($ks -join "`n") + "`n"
        $ksPath = Join-Path $drive 'ks.cfg'
        [IO.File]::WriteAllText($ksPath, $text, [Text.UTF8Encoding]::new($false))
        if (-not (Test-Path -LiteralPath $ksPath)) { throw "ks.cfg was not written to $drive" }
        Write-Ok "wrote ks.cfg for user '$UserName' on host '$Hostname'"
    } catch {
        # A half-built disk is worse than none: Anaconda would find an OEMDRV
        # volume with no ks.cfg and sit at the wizard anyway.
        Dismount-VHD -Path $Path -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        throw
    } finally {
        if ($mounted) { Dismount-VHD -Path $Path -ErrorAction SilentlyContinue }
    }

    Write-Ok "Kickstart disk at $Path"
    Write-Note 'Attach it alongside the ISO and the install runs with no keyboard at all.'
    $Path
}

<#
Attaches a kickstart disk to an existing VM. The VM must be off.
#>
function Add-KickstartDisk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Path
    )

    $vm = Get-VM -Name $VMName -ErrorAction Stop
    if ($vm.State -ne 'Off') { throw "VM '$VMName' must be off to attach a disk (it is $($vm.State))." }

    if (Get-VMHardDiskDrive -VM $vm | Where-Object Path -eq $Path) {
        Write-Note 'Kickstart disk already attached'
        return
    }

    Add-VMHardDiskDrive -VM $vm -Path $Path
    Write-Ok "Attached $Path to $VMName"
}

<#
.SYNOPSIS
    Add SSH access and guest tooling to an existing kickstart disk.

.DESCRIPTION
    Edits the ks.cfg in place rather than regenerating it, which matters
    because the password hash is only ever held in memory -- rebuilding the
    disk would mean prompting for the password again.

    The %post block runs inside the installed system with networking up, so it
    can reach the Fedora mirrors. It deliberately does not use --erroronfail: a
    mirror hiccup should leave you with an installed machine to fix, not an
    aborted install.
#>
function Update-KickstartDisk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$UserName,
        # Public key to authorise for that user, so the guest is reachable
        # without ever touching the console.
        [string]$AuthorizedKey,
        # openssh-server plus the Hyper-V integration daemons, which is what
        # lets the host report the guest's address.
        [switch]$InstallGuestTools
    )

    if (-not (Test-Elevated)) {
        throw 'Editing the kickstart disk needs an elevated PowerShell (Mount-VHD requires Administrator).'
    }
    if (-not (Test-Path -LiteralPath $Path)) { throw "No kickstart disk at $Path" }

    $mounted = $null
    try {
        $mounted = Mount-VHD -Path $Path -Passthru -ErrorAction Stop | Get-Disk
        $vol = Get-Partition -DiskNumber $mounted.Number | Get-Volume | Where-Object DriveLetter
        if (-not $vol) { throw 'The kickstart disk has no readable volume.' }
        $ksPath = "$($vol.DriveLetter):\ks.cfg"
        if (-not (Test-Path -LiteralPath $ksPath)) { throw "No ks.cfg on $Path" }

        $lines = [System.Collections.Generic.List[string]](Get-Content -LiteralPath $ksPath)

        if ($AuthorizedKey -and -not ($lines -match '^sshkey ')) {
            # Kickstart writes this into the user's authorized_keys for us.
            $idx = $lines.FindIndex({ param($l) $l -eq 'reboot' })
            $entry = "sshkey --username=$UserName `"$AuthorizedKey`""
            if ($idx -ge 0) { $lines.Insert($idx, $entry) } else { $lines.Add($entry) }
        }

        if ($InstallGuestTools -and -not ($lines -match '^%post')) {
            $lines.Add('')
            $lines.Add('%post --log=/root/ks-post.log')
            $lines.Add('# Runs in the installed system, with networking up.')
            $lines.Add('# hyperv-daemons is what lets the Windows host see this guest''s address;')
            $lines.Add('# sshd is how the machine is reachable without using the console at all.')
            $lines.Add('dnf install -y hyperv-daemons openssh-server git')
            $lines.Add('systemctl enable hypervkvpd.service hypervvssd.service sshd.service')
            $lines.Add('')
            $lines.Add("# Kickstart's sshkey writes authorized_keys but does not always label it")
            $lines.Add('# for SELinux. sshd then reads a file it is not allowed to read, and the')
            $lines.Add('# client sees "Server accepts key" followed immediately by "Permission')
            $lines.Add('# denied" -- the key is present and still useless. Relabel and fix modes.')
            $lines.Add("for h in /home/*/ /root/; do")
            $lines.Add('  [ -d "$h/.ssh" ] || continue')
            $lines.Add('  chmod 700 "$h/.ssh"')
            $lines.Add('  chmod 600 "$h/.ssh/authorized_keys" 2>/dev/null || true')
            $lines.Add('  restorecon -R -F "$h/.ssh" 2>/dev/null || true')
            $lines.Add('done')
            $lines.Add('%end')
        }

        $text = ($lines -join "`n") + "`n"
        [IO.File]::WriteAllText($ksPath, $text, [Text.UTF8Encoding]::new($false))

        Write-Ok "updated ks.cfg on $Path"
        Write-Note 'Contents:'
        # Never echo the credential line: this output lands in transcripts and
        # scrollback, and a SHA-512 crypt hash is still worth attacking.
        $lines | ForEach-Object {
            if ($_ -match '--iscrypted') {
                Write-Note '  user --name=... --iscrypted --password=<redacted>'
            } else {
                Write-Note "  $_"
            }
        }
    } finally {
        if ($mounted) { Dismount-VHD -Path $Path -ErrorAction SilentlyContinue }
    }
}
