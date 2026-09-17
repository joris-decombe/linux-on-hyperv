<#
Host-side plumbing for a running Linux guest: finding its address and opening
the desktop.

The desktop arrives over RDP, served by gnome-remote-desktop inside the guest.
That is the whole reason this project moved off a capture-and-stream approach:
RDP already carries video, audio, clipboard and -- the part that matters most
in a VM -- a resolution that follows the client window as you resize it. The
Windows client is mstsc.exe, which is already installed.
#>

function Get-LinuxVMAddress {
    [CmdletBinding()]
    param(
        [string]$Name = $script:VMDefaults.VMName,
        # Wait for the guest to report an address. It only does so once the
        # Hyper-V KVP daemon is running (the hyperv-daemons package).
        [int]$TimeoutSeconds = 0
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $addresses = @(Get-VMNetworkAdapter -VMName $Name -ErrorAction Stop |
            Select-Object -ExpandProperty IPAddresses |
            Where-Object { $_ -and $_ -notmatch ':' -and $_ -ne '127.0.0.1' })

        if ($addresses.Count -gt 0) { return $addresses[0] }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds 2
    } while ($true)

    throw @"
The guest is not reporting an IP address.

Hyper-V learns it from the guest's KVP daemon, which comes from the Fedora
'hyperv-daemons' package. Either the VM is still booting, or guest/setup.sh has
not run yet. Inside the guest, read it with 'ip -4 addr'.
"@
}

<#
Opens the guest desktop in the Windows Remote Desktop client.

Dynamic resolution is the default in mstsc for servers that advertise it, and
gnome-remote-desktop does -- so resizing the window resizes the guest desktop,
with no fixed mode anywhere in the chain.
#>
function Start-LinuxDesktop {
    [CmdletBinding()]
    param(
        [string]$Name = $script:VMDefaults.VMName,
        [string]$Address,
        # Start full screen instead of in a window.
        [switch]$FullScreen,
        # Skip writing an .rdp file and just hand the address to mstsc.
        [switch]$NoProfile
    )

    if (-not $Address) { $Address = Get-LinuxVMAddress -Name $Name -TimeoutSeconds 120 }

    if ($NoProfile) {
        Start-Process mstsc.exe -ArgumentList "/v:$Address"
        Write-Ok "Opened Remote Desktop to $Address"
        return
    }

    # An .rdp file is the only way to set several of these; mstsc's command line
    # cannot express audio redirection or dynamic resolution.
    $rdpPath = Join-Path $env:LOCALAPPDATA "HyperVLinux\$Name.rdp"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $rdpPath) | Out-Null

    $lines = @(
        "full address:s:$Address"
        # Play the guest's audio on this machine. Without this RDP renders it
        # on the "remote" side, which in a VM with no sound card means nowhere.
        'audiomode:i:0'
        # Send this machine's microphone the other way.
        'audiocapturemode:i:1'
        # Let the session resize with the window rather than pinning a mode.
        'dynamic resolution:i:1'
        'smart sizing:i:0'
        'redirectclipboard:i:1'
        'redirectprinters:i:0'
        'session bpp:i:32'
        # The guest's certificate is self-signed by grdctl; without this mstsc
        # refuses outright rather than warning.
        'authentication level:i:0'
        'prompt for credentials:i:1'
        "screen mode id:i:$(if ($FullScreen) { 2 } else { 1 })"
    )
    Set-Content -LiteralPath $rdpPath -Value $lines -Encoding ASCII

    Start-Process mstsc.exe -ArgumentList "`"$rdpPath`""
    Write-Ok "Opened Remote Desktop to $Address"
    Write-Note "Profile: $rdpPath"
    Write-Note 'Log in with your guest username and password.'
}

<#
Copies guest/ into the VM over SSH. Fedora Workstation does not enable sshd by
default either, so this only works once you have turned it on in the guest.
#>
function Copy-GuestKit {
    [CmdletBinding()]
    param(
        [string]$Name = $script:VMDefaults.VMName,
        [Parameter(Mandatory)][string]$UserName,
        [string]$Address
    )

    if (-not (Get-Command scp -ErrorAction SilentlyContinue)) {
        throw 'scp not found. Install the Windows OpenSSH client, or clone this repo inside the guest instead.'
    }
    if (-not $Address) { $Address = Get-LinuxVMAddress -Name $Name -TimeoutSeconds 60 }

    $guestDir = Join-Path (Get-RepoRoot) 'guest'
    Write-Step "Copying guest kit to ${UserName}@${Address}"
    & scp -r -o StrictHostKeyChecking=accept-new $guestDir "${UserName}@${Address}:~/linux-on-hyperv-guest"
    if ($LASTEXITCODE -ne 0) { throw "scp failed with exit code $LASTEXITCODE" }

    Write-Ok 'Copied'
    Write-Note 'Now run in the guest:  bash ~/linux-on-hyperv-guest/setup.sh'
}

<#
.SYNOPSIS
    Wait for the guest to finish provisioning itself and start serving RDP.

.DESCRIPTION
    The kickstart's first-boot unit installs gnome-remote-desktop, generates a
    certificate and enables Remote Login, which takes several minutes of
    package downloads after the install has already "finished". Port 3389
    answering is the end of that: it is served by the guest's own
    gnome-remote-desktop and by nothing else, so it cannot be true early.

    Returns the address, or $null on timeout.
#>
function Wait-LinuxDesktop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$Port = 3389,
        [int]$TimeoutMinutes = 30
    )

    Write-Step "Waiting for '$VMName' to finish provisioning its desktop"
    Write-Note "Signal: a completed RDP handshake, not merely an open port."

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        $address = @(Get-VMNetworkAdapter -VMName $VMName |
                Select-Object -ExpandProperty IPAddresses |
                Where-Object { $_ -and $_ -notmatch ':' -and $_ -ne '127.0.0.1' })[0]

        if ($address -and (Test-RdpHandshake -Address $address -Port $Port)) {
            Write-Ok "Desktop is being served at ${address}:$Port"
            return $address
        }
        Start-Sleep -Seconds 20
    }

    Write-Warn "No RDP listener after $TimeoutMinutes minutes."
    Write-Note 'The guest logs what it did: /var/log/linux-on-hyperv-firstboot.log'
    Write-Note "Or watch it live:  journalctl -u linux-on-hyperv-firstboot -f"
    $null
}

<#
.SYNOPSIS
    True when something at Address:Port actually speaks RDP.

.DESCRIPTION
    A TCP connect is not enough, and believing otherwise cost an evening here.
    gnome-remote-desktop accepts the connection before it decides whether it
    will talk to you, so with RDP credentials unset it accepts, says nothing,
    and denies the client -- while every port check on the Windows side reports
    3389 open and healthy. Invoke-LinuxProfile printed "Ready. Nothing else
    needs doing in the guest" over exactly that state.

    So send what mstsc sends: an X.224 Connection Request. A working server
    answers with a Connection Confirm (PDU type 0xD0) naming the security
    protocol it picked. Anything else -- silence, a reset, a timeout -- is not
    a server you can connect to.
#>
function Test-RdpHandshake {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Address,
        [int]$Port = 3389,
        [int]$TimeoutMs = 4000
    )

    $client = [Net.Sockets.TcpClient]::new()
    try {
        if (-not $client.ConnectAsync($Address, $Port).Wait($TimeoutMs)) { return $false }

        # X.224 Connection Request with an RDP negotiation request offering
        # TLS and CredSSP -- byte for byte what a client opens with.
        $request = [byte[]](
            0x03, 0x00, 0x00, 0x13,                     # TPKT header, 19 bytes
            0x0E, 0xE0, 0x00, 0x00, 0x00, 0x00, 0x00,   # X.224 CR
            0x01, 0x00, 0x08, 0x00,                     # RDP_NEG_REQ
            0x03, 0x00, 0x00, 0x00                      # TLS | CredSSP
        )

        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutMs
        $stream.Write($request, 0, $request.Length)
        $stream.Flush()

        $reply = [byte[]]::new(19)
        $read = $stream.Read($reply, 0, $reply.Length)
        # TPKT version 3, and an X.224 Connection Confirm rather than a
        # Disconnect Request, which is how a refusal arrives when it arrives
        # at all.
        ($read -ge 6) -and ($reply[0] -eq 0x03) -and ($reply[5] -eq 0xD0)
    } catch {
        $false
    } finally {
        $client.Dispose()
    }
}
