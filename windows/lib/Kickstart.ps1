<#
Unattended Fedora installs.

Anaconda scans at boot for a volume labeled OEMDRV and, finding a ks.cfg on it,
runs the install from that with no kernel argument and no keyboard. That is the
whole mechanism: attach a second small volume and the installer stops asking.

It is also the answer to the Hyper-V console's unsynced Caps Lock -- an install
nobody types into cannot be mistyped into -- and it makes the VMs reproducible,
which matters when comparing desktops on supposedly identical machines.

The volume can be an ISO or a VHDX, and the choice is about privilege rather
than taste:

  ISO   built through IMAPI2, the disc-mastering COM API built into Windows.
        Needs no elevation at all. This is the default.
  VHDX  built by formatting a mounted virtual disk, so it needs Mount-VHD,
        which attaches a disk to Windows itself and requires Administrator --
        membership of Hyper-V Administrators does not cover it.

The media the installer boots from matters too, and separately: a Fedora *Live*
image boots to a desktop and only starts Anaconda when someone clicks Install,
so nothing scans for OEMDRV and the kickstart is silently ignored. A netinst or
DVD image boots straight into Anaconda, which does scan.
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
        # salt from the result must reproduce it exactly. This is not ceremony:
        # an earlier implementation piped the password into openssl, and
        # PowerShell appends a newline to native-command stdin, so what got
        # hashed was "password`r" -- a hash nobody could ever log in with,
        # discovered only after a full unattended install had succeeded.
        $parts = $hash -split '\$'
        if ($parts.Count -lt 4) { throw "openssl returned something that is not SHA-512 crypt: $hash" }
        $again = Invoke-OpensslPasswd -Plain $plain -Salt $parts[2]
        if ($again -ne $hash) {
            throw 'Hash did not verify (two different results for the same password). Refusing to write a password nobody can use.'
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

    $opensslArgs = @('passwd', '-6')
    if ($Salt) { $opensslArgs += @('-salt', $Salt) }
    $opensslArgs += '-stdin'

    $candidates = @()
    if (Get-Command openssl -ErrorAction SilentlyContinue) {
        $candidates += , @{ File = 'openssl'; Args = $opensslArgs }
    }
    if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
        $candidates += , @{ File = 'wsl.exe'; Args = @('-e', 'openssl') + $opensslArgs }
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
            # Write, not WriteLine: the absence of a newline is the entire point.
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
    Build the ks.cfg text. Pure: it touches nothing on disk.

.DESCRIPTION
    Split out from the writers so the ISO and VHDX paths cannot drift apart.
#>
function New-KickstartContent {
    [CmdletBinding()]
    param(
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
        # openssh-server plus the Hyper-V integration daemons, so the guest is
        # reachable and reports its address without anyone touching the console.
        [switch]$InstallGuestTools,
        # The installer's own encryption is off by default: a LUKS passphrase
        # must be typed at the console on every boot, before any network
        # exists, which defeats the point of an unattended machine.
        [switch]$EncryptDisk,
        [string]$EncryptionPassphrase
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
        # one, which is precisely the interaction we are removing.
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

    if ($InstallGuestTools) {
        $ks.Add('')
        $ks.Add('%post --log=/root/ks-post.log')
        $ks.Add('# Runs in the installed system, with networking up.')
        $ks.Add('dnf install -y hyperv-daemons openssh-server git')
        $ks.Add('systemctl enable hypervkvpd.service hypervvssd.service sshd.service')
        $ks.Add('')
        $ks.Add("# Kickstart's sshkey writes authorized_keys but does not always label it")
        $ks.Add('# for SELinux. sshd then reads a file it is not allowed to read, and the')
        $ks.Add('# client sees "Server accepts key" followed immediately by "Permission')
        $ks.Add('# denied" -- the key present and still useless. Relabel and fix modes.')
        $ks.Add('for h in /home/*/ /root/; do')
        $ks.Add('  [ -d "$h/.ssh" ] || continue')
        $ks.Add('  chmod 700 "$h/.ssh"')
        $ks.Add('  chmod 600 "$h/.ssh/authorized_keys" 2>/dev/null || true')
        $ks.Add('  restorecon -R -F "$h/.ssh" 2>/dev/null || true')
        $ks.Add('done')
        $ks.Add('%end')
    }

    # LF endings, no BOM: this is read by a Linux installer.
    ($ks -join "`n") + "`n"
}

# Shared by both writers so their parameter surfaces cannot drift.
function Get-KickstartContentArgs {
    param([hashtable]$Bound)

    $keep = @(
        'UserName', 'PasswordHash', 'FullName', 'Hostname', 'Timezone',
        'KeyboardLayout', 'Locale', 'AuthorizedKey', 'PackageEnvironment',
        'ReleaseVersion', 'Live', 'InstallGuestTools', 'EncryptDisk',
        'EncryptionPassphrase'
    )
    $out = @{}
    foreach ($k in $keep) {
        if ($Bound.ContainsKey($k)) { $out[$k] = $Bound[$k] }
    }
    $out
}

<#
.SYNOPSIS
    Build an OEMDRV kickstart ISO. Needs no elevation.

.DESCRIPTION
    Uses IMAPI2, the disc-mastering COM API Windows has shipped since Vista, so
    nothing is mounted and no Administrator rights are involved. ISO9660
    uppercases its volume identifier, which is what Anaconda wants anyway.

.EXAMPLE
    New-KickstartIso -Path D:\vm\fedora-ks.iso -UserName joris `
        -PasswordHash (New-LinuxPasswordHash)
#>
function New-KickstartIso {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][string]$PasswordHash,
        [string]$FullName = $UserName,
        [string]$Hostname = 'fedora',
        [string]$Timezone = 'Pacific/Auckland',
        [string]$KeyboardLayout = 'us',
        [string]$Locale = 'en_NZ.UTF-8',
        [string]$AuthorizedKey,
        [string]$PackageEnvironment = '@^workstation-product-environment',
        [string]$ReleaseVersion = '44',
        [switch]$Live,
        [switch]$InstallGuestTools,
        [switch]$EncryptDisk,
        [string]$EncryptionPassphrase,
        [switch]$Force
    )

    $contentArgs = Get-KickstartContentArgs $PSBoundParameters
    $content = New-KickstartContent @contentArgs

    if ((Test-Path -LiteralPath $Path) -and -not $Force) {
        throw "Kickstart ISO already exists: $Path (pass -Force to replace it)"
    }

    Write-Step 'Building the OEMDRV kickstart ISO'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null

    # IMAPI2 builds from a directory tree, so stage the single file.
    $stage = Join-Path ([IO.Path]::GetTempPath()) ('ks-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    try {
        [IO.File]::WriteAllText((Join-Path $stage 'ks.cfg'), $content, [Text.UTF8Encoding]::new($false))

        $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
        # 1 = ISO9660, 2 = Joliet. Anaconda matches on the ISO9660 volume
        # identifier, which is the label.
        $fsi.FileSystemsToCreate = 3
        $fsi.VolumeName = 'OEMDRV'
        $fsi.Root.AddTree($stage, $false)

        $image = $fsi.CreateResultImage()
        Copy-ComStreamToFile -ComStream $image.ImageStream -Path $Path

        if (-not (Test-Path -LiteralPath $Path)) { throw "the ISO was not written to $Path" }
        Write-Ok ('wrote {0} ({1:N0} KB)' -f $Path, ((Get-Item -LiteralPath $Path).Length / 1KB))
        Write-Note "ks.cfg for user '$UserName' on host '$Hostname'"
    } finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Note 'Attach it as a second DVD drive. No elevation was needed to build it.'
    $Path
}

<#
Copies an IMAPI2 result image (a COM IStream) to a file.

PowerShell cannot read an IStream directly and ADODB.Stream will not take one,
so borrow a few lines of C#. This is the only reason the ISO path needs
Add-Type at all.
#>
function Copy-ComStreamToFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ComStream,
        [Parameter(Mandatory)][string]$Path
    )

    if (-not ('LinuxOnHyperV.ComStreamCopier' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace LinuxOnHyperV {
    public static class ComStreamCopier {
        public static void ToFile(object comStream, string path) {
            IStream stream = (IStream)comStream;
            byte[] buffer = new byte[64 * 1024];
            IntPtr read = Marshal.AllocHGlobal(sizeof(int));
            try {
                using (FileStream file = new FileStream(path, FileMode.Create, FileAccess.Write)) {
                    while (true) {
                        stream.Read(buffer, buffer.Length, read);
                        int count = Marshal.ReadInt32(read);
                        if (count <= 0) { break; }
                        file.Write(buffer, 0, count);
                    }
                }
            } finally {
                Marshal.FreeHGlobal(read);
            }
        }
    }
}
'@
    }

    [LinuxOnHyperV.ComStreamCopier]::ToFile($ComStream, $Path)
}

<#
.SYNOPSIS
    Build an OEMDRV kickstart disk as a VHDX. Requires Administrator.

.DESCRIPTION
    Prefer New-KickstartIso, which does the same job unelevated. This remains
    for cases wanting a writable volume rather than read-only media.
#>
function New-KickstartDisk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][string]$PasswordHash,
        [string]$FullName = $UserName,
        [string]$Hostname = 'fedora',
        [string]$Timezone = 'Pacific/Auckland',
        [string]$KeyboardLayout = 'us',
        [string]$Locale = 'en_NZ.UTF-8',
        [string]$AuthorizedKey,
        [string]$PackageEnvironment = '@^workstation-product-environment',
        [string]$ReleaseVersion = '44',
        [switch]$Live,
        [switch]$InstallGuestTools,
        [switch]$EncryptDisk,
        [string]$EncryptionPassphrase,
        [switch]$Force
    )

    $contentArgs = Get-KickstartContentArgs $PSBoundParameters
    $content = New-KickstartContent @contentArgs

    if (Test-Path -LiteralPath $Path) {
        if (-not $Force) { throw "Kickstart disk already exists: $Path (pass -Force to replace it)" }
        Dismount-VHD -Path $Path -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $Path -Force
    }

    if (-not (Test-Elevated)) {
        throw @"
Building a kickstart VHDX needs an elevated PowerShell, because Mount-VHD
attaches the disk to Windows itself and that requires Administrator --
membership of Hyper-V Administrators does not cover it.

Use the ISO instead. It does the same job and needs no elevation:
    New-KickstartIso -Path '$([IO.Path]::ChangeExtension($Path, 'iso'))' -UserName '$UserName' -PasswordHash (New-LinuxPasswordHash)
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
        $ksPath = Join-Path $drive 'ks.cfg'
        [IO.File]::WriteAllText($ksPath, $content, [Text.UTF8Encoding]::new($false))
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
    $Path
}

<#
.SYNOPSIS
    Attach kickstart media to a VM. Takes either an ISO or a VHDX.

.DESCRIPTION
    An ISO becomes a second DVD drive, a VHDX a second hard disk. Either way
    Anaconda sees a volume labeled OEMDRV. The VM must be off.
#>
function Add-KickstartMedia {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Path
    )

    $vm = Get-VM -Name $VMName -ErrorAction Stop
    if ($vm.State -ne 'Off') { throw "VM '$VMName' must be off to attach media (it is $($vm.State))." }

    if ([IO.Path]::GetExtension($Path) -eq '.iso') {
        if (Get-VMDvdDrive -VM $vm | Where-Object Path -eq $Path) {
            Write-Note 'Kickstart ISO already attached'
            return
        }
        Add-VMDvdDrive -VM $vm -Path $Path
        Write-Ok "Attached $Path as a DVD drive"
    } else {
        if (Get-VMHardDiskDrive -VM $vm | Where-Object Path -eq $Path) {
            Write-Note 'Kickstart disk already attached'
            return
        }
        Add-VMHardDiskDrive -VM $vm -Path $Path
        Write-Ok "Attached $Path as a hard disk"
    }
}

# The older name; Add-KickstartMedia handles both media types.
function Add-KickstartDisk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Path
    )
    Add-KickstartMedia -VMName $VMName -Path $Path
}

<#
.SYNOPSIS
    Add SSH access and guest tooling to an existing kickstart VHDX.

.DESCRIPTION
    Edits the ks.cfg in place rather than regenerating it, which matters when
    the password hash is only held in memory. Needs Administrator, for the same
    Mount-VHD reason. New media should instead be built with
    -InstallGuestTools, which puts the same %post in from the start.
#>
function Update-KickstartDisk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$UserName,
        [string]$AuthorizedKey,
        [switch]$InstallGuestTools
    )

    if (-not (Test-Elevated)) {
        throw 'Editing a kickstart VHDX needs an elevated PowerShell (Mount-VHD requires Administrator).'
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
            $idx = $lines.FindIndex({ param($l) $l -eq 'reboot' })
            $entry = "sshkey --username=$UserName `"$AuthorizedKey`""
            if ($idx -ge 0) { $lines.Insert($idx, $entry) } else { $lines.Add($entry) }
        }

        if ($InstallGuestTools -and -not ($lines -match '^%post')) {
            # Reuse the one definition of the %post block rather than keeping a
            # second copy here that could quietly diverge.
            $sample = (New-KickstartContent -UserName $UserName -PasswordHash '$6$placeholder$placeholder' -InstallGuestTools) -split "`n"
            $start = [Array]::IndexOf($sample, '%post --log=/root/ks-post.log')
            if ($start -ge 0) {
                $lines.Add('')
                $sample[$start..($sample.Count - 1)] | Where-Object { $_ -ne '' -or $true } | ForEach-Object { $lines.Add($_) }
            }
        }

        [IO.File]::WriteAllText($ksPath, (($lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))

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
