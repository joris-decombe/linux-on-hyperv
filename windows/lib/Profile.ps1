<#
Setup profiles.

By the time this project had grown a second target (WSL) and a third install
mode (unattended), the interface was a dozen cmdlets with interlocking
parameters, and the only person who could drive it was whoever had just read
the source. A profile is the fix: one JSON file describes an entire setup, and
one command applies it.

The reproducibility is the real point rather than a side effect. Comparing
desktops means building machines that differ in exactly one respect, and a file
you can diff is the only honest way to promise that.

Profiles are data, not scripts: they are validated against a known set of keys
before anything runs, so a typo is an error message rather than a VM built
subtly wrong.
#>

# Every key a profile may contain, with its default. Anything outside this set
# is rejected -- a silently-ignored "proccessorCount" is worse than a refusal.
function Get-LinuxProfileDefault {
    [ordered]@{
        name        = 'unnamed'
        description = ''
        # 'vm' builds a Hyper-V machine; 'wsl' configures a WSL distro. They
        # are genuinely different targets, not two ways of doing one thing:
        # only the VM can host a desktop, only WSL can reach the GPU.
        target      = 'vm'

        vm          = [ordered]@{
            name           = 'Fedora'
            isoPath        = ''
            processorCount = 8
            memoryGB       = 12
            minMemoryGB    = 2
            staticMemory   = $false
            diskGB         = 100
            switchName     = 'Default Switch'
            secureBoot     = $false
        }

        install     = [ordered]@{
            # Unattended installs need a kickstart disk and an installer that
            # reads it. Fedora Live ISOs do not: they boot to a desktop and
            # only start Anaconda when you click Install, so OEMDRV is never
            # scanned at boot. Use a netinst/DVD image for hands-off installs.
            unattended        = $false
            userName          = ''
            fullName          = ''
            hostname          = ''
            timezone          = 'Pacific/Auckland'
            keyboardLayout    = 'us'
            locale            = 'en_NZ.UTF-8'
            authorizedKeyPath = ''
            installGuestTools = $true
            # 'generate' makes the install genuinely zero-touch and produces a
            # password no one can mistype and nobody can brute-force. 'prompt'
            # asks, for when the password has to be one you already know.
            passwordMode      = 'generate'
            # Finish the setup from inside the guest, on its first boot, rather
            # than leaving someone to log in at the console and run setup.sh.
            # This is what makes "unattended" mean a working desktop instead of
            # a working login prompt.
            provision         = $true
            provisionRepo     = 'https://github.com/joris-decombe/linux-on-hyperv.git'
            provisionRef      = 'main'
        }

        guest       = [ordered]@{
            desktop = 'gnome'
            rdpPort = 3389
        }

        wsl         = [ordered]@{
            distroName = 'FedoraLinux-44'
            gpuAdapter = 'NVIDIA'
        }
    }
}

function ConvertTo-Hashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hashtable $p.Value }
        return $h
    }
    return $InputObject
}

<#
.SYNOPSIS
    Read and validate a profile, filling in defaults for anything omitted.
#>
function Get-LinuxProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "No profile at $Path" }

    try {
        $raw = ConvertTo-Hashtable (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    } catch {
        throw "Profile is not valid JSON: $Path`n$($_.Exception.Message)"
    }

    $merged = Get-LinuxProfileDefault
    $problems = [System.Collections.Generic.List[string]]::new()

    foreach ($key in $raw.Keys) {
        if (-not $merged.Contains($key)) { $problems.Add("unknown key '$key'"); continue }
        if ($merged[$key] -is [System.Collections.Specialized.OrderedDictionary]) {
            foreach ($sub in $raw[$key].Keys) {
                if (-not $merged[$key].Contains($sub)) { $problems.Add("unknown key '$key.$sub'"); continue }
                $merged[$key][$sub] = $raw[$key][$sub]
            }
        } else {
            $merged[$key] = $raw[$key]
        }
    }

    if ($merged.target -notin @('vm', 'wsl')) { $problems.Add("target must be 'vm' or 'wsl', got '$($merged.target)'") }

    if ($merged.target -eq 'vm') {
        if (-not $merged.vm.isoPath) { $problems.Add('vm.isoPath is required for a vm profile') }
        elseif (-not (Test-Path -LiteralPath $merged.vm.isoPath)) { $problems.Add("vm.isoPath not found: $($merged.vm.isoPath)") }

        if ($merged.install.unattended) {
            foreach ($f in 'userName') {
                if (-not $merged.install.$f) { $problems.Add("install.$f is required when install.unattended is true") }
            }
            if ($merged.vm.isoPath -match 'Live') {
                $problems.Add('install.unattended with a Live ISO will not work: Live media boots to a desktop and never starts Anaconda, so the OEMDRV kickstart is never read. Use a netinst or DVD image.')
            }
        }
    }

    if ($merged.install.passwordMode -notin @('generate', 'prompt')) {
        $problems.Add("install.passwordMode must be 'generate' or 'prompt', got '$($merged.install.passwordMode)'")
    }

    if ($merged.guest.desktop -notin @('gnome', 'kde', 'xfce', 'cinnamon', 'mate')) {
        $problems.Add("guest.desktop '$($merged.guest.desktop)' is not one of: gnome kde xfce cinnamon mate")
    }

    if ($problems.Count) {
        throw ("Profile $Path has problems:`n" + (($problems | ForEach-Object { "  - $_" }) -join "`n"))
    }

    $merged
}

<#
.SYNOPSIS
    Write a profile, asking questions when run with -Interactive.

.EXAMPLE
    New-LinuxProfile -Interactive -Path profiles/fedora-gnome.json
#>
function New-LinuxProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Interactive,
        [hashtable]$Settings,
        [switch]$Force
    )

    if ((Test-Path -LiteralPath $Path) -and -not $Force) {
        throw "Profile already exists: $Path (pass -Force to overwrite)"
    }

    $p = Get-LinuxProfileDefault

    if ($Interactive) {
        Write-Step 'New setup profile'
        Write-Note 'Enter accepts the default in brackets.'

        $p.name = Read-Default 'Profile name' ([IO.Path]::GetFileNameWithoutExtension($Path))
        $p.description = Read-Default 'Description' ''
        $p.target = Read-Choice 'Target' @('vm', 'wsl') $p.target

        if ($p.target -eq 'vm') {
            $p.vm.name = Read-Default 'VM name' $p.name
            $p.vm.isoPath = Read-Iso
            $p.vm.switchName = Read-Choice 'Virtual switch' @(Get-VMSwitch | Select-Object -ExpandProperty Name) $p.vm.switchName
            $p.vm.processorCount = [int](Read-Default 'vCPUs' $p.vm.processorCount)
            $p.vm.memoryGB = [int](Read-Default 'Max memory (GB)' $p.vm.memoryGB)
            $p.vm.diskGB = [int](Read-Default 'Disk (GB)' $p.vm.diskGB)
            $p.vm.secureBoot = (Read-Default 'Secure Boot? (y/n)' $(if ($p.vm.secureBoot) { 'y' } else { 'n' })) -eq 'y'

            $p.guest.desktop = Read-Choice 'Desktop' @('gnome', 'kde', 'xfce', 'cinnamon', 'mate') $p.guest.desktop
            if ($p.guest.desktop -ne 'gnome') {
                Write-Warn 'Only GNOME gives a session sized by the connecting client; the others cannot resize with the window.'
            }

            $p.install.unattended = (Read-Default 'Unattended install? (y/n)' 'n') -eq 'y'
            if ($p.install.unattended) {
                if ($p.vm.isoPath -match 'Live') {
                    Write-Warn 'That is a Live ISO. Unattended installs need a netinst or DVD image -- Live media never starts Anaconda at boot, so the kickstart is not read.'
                }
                $p.install.userName = Read-Default 'Linux username' $env:USERNAME.ToLower()
                $p.install.fullName = Read-Default 'Full name' $p.install.userName
                $p.install.hostname = Read-Default 'Hostname' $p.vm.name.ToLower()
                $p.install.timezone = Read-Default 'Timezone' $p.install.timezone
                $p.install.keyboardLayout = Read-Default 'Keyboard layout' $p.install.keyboardLayout
                $p.install.locale = Read-Default 'Locale' $p.install.locale
                $p.install.authorizedKeyPath = Read-Default 'SSH public key to authorise (blank for none)' "$env:USERPROFILE\.ssh\linux-on-hyperv.pub"
            }
        } else {
            $distros = @(((& wsl.exe --list --quiet 2>$null) -join "`n") -replace "`0", '' -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($distros) { $p.wsl.distroName = Read-Choice 'WSL distro' $distros $p.wsl.distroName }
            $p.wsl.gpuAdapter = Read-Default 'Preferred GPU adapter (matched by name)' $p.wsl.gpuAdapter
        }
    }

    if ($Settings) {
        foreach ($k in $Settings.Keys) {
            if (-not $p.Contains($k)) { throw "unknown setting '$k'" }
            $p[$k] = $Settings[$k]
        }
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    ($p | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Path -Encoding UTF8
    Write-Ok "wrote $Path"

    # Validate what was just written, so a bad answer surfaces now rather than
    # halfway through building a VM.
    Get-LinuxProfile -Path $Path | Out-Null
    Write-Ok 'profile is valid'
    $Path
}

function Read-Default {
    param([string]$Prompt, $Default)
    $answer = Read-Host "  $Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    $answer.Trim()
}

function Read-Choice {
    param([string]$Prompt, [string[]]$Options, [string]$Default)
    Write-Host "  $Prompt" -ForegroundColor White
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $mark = if ($Options[$i] -eq $Default) { '*' } else { ' ' }
        Write-Host ("    $mark {0}) {1}" -f ($i + 1), $Options[$i])
    }
    $answer = Read-Host "  choose 1-$($Options.Count) [$Default]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $Options.Count) {
        return $Options[[int]$answer - 1]
    }
    if ($Options -contains $answer) { return $answer }
    Write-Warn "not one of the options; keeping $Default"
    $Default
}

# Offer whatever ISOs are lying around rather than making someone type a path.
function Read-Iso {
    $candidates = @(
        "$env:USERPROFILE\Downloads", 'D:\Downloads', 'D:\iso', 'C:\iso'
    ) | Where-Object { Test-Path $_ } | ForEach-Object {
        Get-ChildItem -LiteralPath $_ -Filter *.iso -File -ErrorAction SilentlyContinue
    } | Sort-Object LastWriteTime -Descending | Select-Object -First 8

    if (-not $candidates) { return (Read-Default 'Installer ISO path' '') }

    Write-Host '  Installer ISO' -ForegroundColor White
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        Write-Host ("    {0}) {1}  ({2:N1} GB)" -f ($i + 1), $candidates[$i].Name, ($candidates[$i].Length / 1GB))
    }
    $answer = Read-Host "  choose 1-$($candidates.Count), or type a path"
    if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $candidates.Count) {
        return $candidates[[int]$answer - 1].FullName
    }
    $answer.Trim()
}


# The desktop chosen in the profile decides what the installer pulls down.
# Fedora names these as environment groups; "@^" selects an environment rather
# than a plain group.
function Get-DesktopEnvironmentGroup {
    param([string]$Desktop)
    switch ($Desktop) {
        'gnome' { '@^workstation-product-environment' }
        'kde' { '@^kde-desktop-environment' }
        'xfce' { '@^xfce-desktop-environment' }
        'cinnamon' { '@^cinnamon-desktop-environment' }
        'mate' { '@^mate-desktop-environment' }
        default { '@^workstation-product-environment' }
    }
}

<#
.SYNOPSIS
    Apply a profile: build the VM, or configure the WSL distro.

.EXAMPLE
    Invoke-LinuxProfile -Path profiles/fedora-gnome.json
#>
function Invoke-LinuxProfile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Force,
        # Return as soon as the VM starts, leaving the kickstart media attached.
        # The media carries the password hash and would reinstall the machine if
        # the installer were ever booted again, so cleaning up is the default.
        [switch]$NoWait
    )

    $p = Get-LinuxProfile -Path $Path
    Write-Step "Applying profile '$($p.name)' (target: $($p.target))"
    if ($p.description) { Write-Note $p.description }

    if ($p.target -eq 'wsl') {
        Write-Note "WSL setup runs inside the distro. From '$($p.wsl.distroName)':"
        Write-Note "  sudo bash wsl/setup.sh --adapter $($p.wsl.gpuAdapter)"
        return
    }

    $splat = @{
        Name           = $p.vm.name
        IsoPath        = $p.vm.isoPath
        ProcessorCount = $p.vm.processorCount
        MemoryBytes    = [uint64]$p.vm.memoryGB * 1GB
        DiskBytes      = [uint64]$p.vm.diskGB * 1GB
        SwitchName     = $p.vm.switchName
        NoStart        = $true
    }
    if ($p.vm.secureBoot) { $splat.SecureBoot = $true }
    if ($p.vm.staticMemory) { $splat.StaticMemory = $true }
    $splat.MinimumMemoryBytes = [uint64]$p.vm.minMemoryGB * 1GB
    if ($Force) { $splat.Force = $true }

    if (-not $PSCmdlet.ShouldProcess($p.vm.name, "Create VM from profile $($p.name)")) { return }

    New-LinuxVM @splat | Out-Null

    if ($p.install.unattended) {
        $key = ''
        $rdpPassword = ''
        if ($p.install.authorizedKeyPath -and (Test-Path -LiteralPath $p.install.authorizedKeyPath)) {
            $key = (Get-Content -LiteralPath $p.install.authorizedKeyPath -Raw).Trim()
        }
        if ($p.install.passwordMode -eq 'generate') {
            # Nothing to type: the password is generated, hashed for the
            # kickstart, and stored encrypted for whoever needs to log in.
            $secret = New-LinuxPassword
            $hash = New-LinuxPasswordHash -Password $secret
            Save-LinuxVMCredential -VMName $p.vm.name -UserName $p.install.userName -Password $secret | Out-Null
            # gnome-remote-desktop needs the password itself, not a hash, so
            # the guest can set its RDP credentials without anyone typing.
            if ($p.install.provision) { $rdpPassword = ConvertFrom-SecureStringPlain $secret }
        } else {
            Write-Host ''
            Write-Host "Password for the Linux user '$($p.install.userName)':" -ForegroundColor Cyan
            $hash = New-LinuxPasswordHash
        }

        $vmDir = Split-Path -Parent (Get-VMHardDiskDrive -VMName $p.vm.name | Select-Object -First 1 -ExpandProperty Path)
        # A FAT16 VHD written by hand, not an ISO on a second DVD: with two
        # discs attached the Fedora netinst wedges in dracut at
        # initrd-switch-root and never reaches Anaconda. And not a
        # Windows-formatted VHDX either, because that needs Mount-VHD and so
        # Administrator. See lib/FatImage.ps1.
        $ksPath = Join-Path $vmDir "$($p.vm.name)-kickstart.vhd"

        $ksSplat = @{
            Path              = $ksPath
            UserName          = $p.install.userName
            FullName          = $p.install.fullName
            Hostname          = $p.install.hostname
            PasswordHash      = $hash
            Timezone          = $p.install.timezone
            KeyboardLayout    = $p.install.keyboardLayout
            Locale            = $p.install.locale
            AuthorizedKey     = $key
            InstallGuestTools = [bool]$p.install.installGuestTools
            Provision         = [bool]$p.install.provision
            ProvisionRepo     = $p.install.provisionRepo
            ProvisionRef      = $p.install.provisionRef
            Desktop           = $p.guest.desktop
            RdpPassword       = $rdpPassword
            Force             = $true
        }
        # A Live image installs its own payload and ignores %packages; a
        # netinst has nothing until told what to fetch.
        if ($p.vm.isoPath -match 'Live') {
            $ksSplat.Live = $true
        } else {
            $ksSplat.PackageEnvironment = Get-DesktopEnvironmentGroup $p.guest.desktop
        }
        New-KickstartVhd @ksSplat | Out-Null

        Add-KickstartMedia -VMName $p.vm.name -Path $ksPath

        # Anaconda has to run for the kickstart to be read, so boot the
        # installer. There are two DVD drives now -- the installer and the
        # kickstart -- and picking the first one found would hand the firmware
        # a non-bootable disc and stall at the UEFI shell.
        $installerDvd = Get-VMDvdDrive -VMName $p.vm.name | Where-Object Path -eq $p.vm.isoPath | Select-Object -First 1
        if (-not $installerDvd) { throw "The installer ISO is not attached to '$($p.vm.name)'." }
        Set-VMFirmware -VMName $p.vm.name -FirstBootDevice $installerDvd
    }

    Start-VM -Name $p.vm.name -ErrorAction Continue
    if ((Get-VM -Name $p.vm.name).State -ne 'Running') {
        throw "The VM did not start. Free memory is the usual cause; see docs/troubleshooting.md."
    }
    Write-Ok "'$($p.vm.name)' is running"

    if ($p.install.unattended -and -not $NoWait) {
        # Blocks until the installed system reports an address, then ejects and
        # deletes the kickstart media. Without this the media -- and the
        # password hash on it -- stays attached forever.
        $waitArgs = @{ VMName = $p.vm.name }
        # Without the guest tools there is no sshd to wait for, so fall back to
        # the weaker address-only signal rather than timing out for an hour.
        if (-not $p.install.installGuestTools) { $waitArgs.AddressIsEnough = $true }
        $address = Wait-LinuxInstall @waitArgs
        if ($address) { Write-Ok "Guest is at $address" }
        # The install being finished is not the same as the desktop being
        # served: the first-boot unit still has packages to fetch.
        if ($address -and $p.install.provision) {
            if (Wait-LinuxDesktop -VMName $p.vm.name -Port $p.guest.rdpPort) {
                # Now, and only now, is the media safe to remove: it could not
                # be detached while the VM ran, and until provisioning finished
                # the guest still needed the credentials on it. It carries the
                # password in the clear, so this is not housekeeping.
                if (Get-VMHardDiskDrive -VMName $p.vm.name | Where-Object { $_.Path -like '*kickstart*' }) {
                    Write-Step 'Removing the kickstart media'
                    Write-Note 'It holds the RDP password in plaintext, so the VM is restarted to detach it.'
                    Stop-VM -Name $p.vm.name -Force -ErrorAction Stop
                    Remove-KickstartMedia -VMName $p.vm.name -Confirm:$false
                    Start-VM -Name $p.vm.name -ErrorAction Stop
                    Wait-LinuxDesktop -VMName $p.vm.name -Port $p.guest.rdpPort -TimeoutMinutes 10 | Out-Null
                }
                Write-Ok 'Ready. Nothing else needs doing in the guest.'
            }
        }
    } elseif ($p.install.unattended) {
        Write-Warn 'Kickstart media left attached (-NoWait).'
        Write-Note "Clean it up when the install finishes:  Remove-KickstartMedia -VMName $($p.vm.name)"
    }

    if ($p.install.unattended -and $p.install.passwordMode -eq 'generate') {
        Write-Note "Desktop login:       Get-LinuxVMCredential -VMName $($p.vm.name) -AsPlainText"
    }
    if (-not $p.install.provision) {
        Write-Note "Next, in the guest:  sudo bash guest/setup.sh --desktop $($p.guest.desktop)"
    }
    Write-Note "Connect:             Start-LinuxDesktop -Name $($p.vm.name)"
}
