<#
Generated credentials.

The password prompt was the only interactive step left in an otherwise
unattended install, which made "unattended" not quite true. It is also the step
that produced the worst bug in this project's history: a password mistyped into
a console with unsynced Caps Lock, or mangled by a stray carriage return,
becomes a machine nobody can log into, and you find out an hour later at a
login screen.

Generating the password removes both problems, and a third: a 128-bit random
password is not brute-forceable at any number of crypt rounds, which is the one
weakness of the SHA-512 hash that ends up on the kickstart media.

Nothing needs the password for automation -- the SSH key does that. It exists
so a human can log into the desktop over RDP, where GNOME's Remote Login
authenticates against the real account through PAM. So it must be stored
somewhere retrievable, and that store is DPAPI: encrypted to this Windows user
on this machine, which is the same trust boundary as the VM itself.
#>

$script:CredentialRoot = Join-Path $env:LOCALAPPDATA 'HyperVLinux\credentials'

<#
.SYNOPSIS
    Generate a strong random password.

.DESCRIPTION
    Uses the cryptographic RNG, not Get-Random, which is seeded and not fit for
    secrets. The alphabet omits characters that are easy to misread when someone
    does have to type this by hand at a console: no O/0, l/1/I.
#>
function New-LinuxPassword {
    [CmdletBinding()]
    param([int]$Length = 24)

    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'.ToCharArray()
    $bytes = [byte[]]::new($Length * 4)
    # RandomNumberGenerator::Fill is .NET Core only; Create().GetBytes() works
    # on Windows PowerShell 5.1 as well, and this module supports both.
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }

    $chars = [char[]]::new($Length)
    try {
        for ($i = 0; $i -lt $Length; $i++) {
            # Take 4 bytes per character and reduce modulo the alphabet. With
            # 2^32 over 57 symbols the modulo bias is far below anything that
            # matters for a 24-character secret.
            $value = [BitConverter]::ToUInt32($bytes, $i * 4)
            $chars[$i] = $alphabet[$value % $alphabet.Length]
        }
        $secure = [securestring]::new()
        foreach ($c in $chars) { $secure.AppendChar($c) }
        $secure.MakeReadOnly()
        $secure
    } finally {
        [Array]::Clear($chars, 0, $chars.Length)
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

<#
.SYNOPSIS
    Store a VM's login password, encrypted to this Windows user.

.DESCRIPTION
    ConvertFrom-SecureString without a key uses DPAPI, so the file can only be
    read back by this user on this machine. That is deliberately the same trust
    boundary as the VM's own disk: anyone who can read one can read the other,
    so the credential store is not the weak link.
#>
function Save-LinuxVMCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][securestring]$Password
    )

    New-Item -ItemType Directory -Force -Path $script:CredentialRoot | Out-Null
    $path = Join-Path $script:CredentialRoot "$VMName.cred"

    [ordered]@{
        vm       = $VMName
        user     = $UserName
        password = ConvertFrom-SecureString $Password
        created  = (Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8

    # Belt and braces on top of DPAPI: strip inherited ACEs so other accounts
    # on this machine cannot even read the ciphertext.
    $acl = Get-Acl -LiteralPath $path
    $acl.SetAccessRuleProtection($true, $false)
    $acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent().Name,
            'FullControl', 'Allow'))
    Set-Acl -LiteralPath $path -AclObject $acl

    Write-Ok "Stored the login for '$UserName' at $path"
    Write-Note 'Encrypted to this Windows account (DPAPI). Read it with Get-LinuxVMCredential.'
    $path
}

<#
.SYNOPSIS
    Retrieve a VM's stored login.

.EXAMPLE
    Get-LinuxVMCredential -VMName Fedora            # user name only
    (Get-LinuxVMCredential -VMName Fedora -AsPlainText).Password
#>
function Get-LinuxVMCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        # Print the password. Off by default so an idle call cannot spill it
        # into a transcript or screen share.
        [switch]$AsPlainText
    )

    $path = Join-Path $script:CredentialRoot "$VMName.cred"
    if (-not (Test-Path -LiteralPath $path)) {
        throw "No stored credential for '$VMName'. It was either created with a password you chose, or the VM predates credential storage."
    }

    $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $secure = ConvertTo-SecureString $data.password

    if (-not $AsPlainText) {
        return [pscustomobject]@{
            VMName   = $data.vm
            UserName = $data.user
            Password = '<use -AsPlainText to reveal>'
            Created  = $data.created
        }
    }

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        [pscustomobject]@{
            VMName   = $data.vm
            UserName = $data.user
            Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            Created  = $data.created
        }
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

<#
.SYNOPSIS
    Forget a stored login.
#>
function Remove-LinuxVMCredential {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][string]$VMName)

    $path = Join-Path $script:CredentialRoot "$VMName.cred"
    if (-not (Test-Path -LiteralPath $path)) { Write-Note "No stored credential for '$VMName'"; return }
    if ($PSCmdlet.ShouldProcess($path, 'Delete stored credential')) {
        Remove-Item -LiteralPath $path -Force
        Write-Ok "Removed $path"
    }
}

<#
.SYNOPSIS
    Unwrap a SecureString. Use sparingly and never hold the result.

.DESCRIPTION
    Exists because gnome-remote-desktop's system daemon needs the password
    itself, not a hash, before it will speak to any client. The rest of this
    module goes to some trouble never to materialise a plaintext password, so
    this is the one deliberate exception rather than a convenience.
#>
function ConvertFrom-SecureStringPlain {
    [CmdletBinding()]
    param([Parameter(Mandatory)][securestring]$Secure)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

<#
.SYNOPSIS
    The SSH key this tooling uses to reach guests. Created on first use.

.DESCRIPTION
    Deliberately without a passphrase, which is the whole point. A profile
    pointed at a passphrase-protected key produces a guest that no unattended
    step can ever reach: ssh offers the public half happily, the server accepts
    it, and then ssh cannot sign because there is no TTY to prompt at and no
    agent to ask. That failure looks exactly like a rejected key, and cost four
    wrong diagnoses here before anyone checked the client.

    A passphrase-less key on disk is a real tradeoff, and it is bounded: this
    one authorises nothing but the throwaway VMs this module builds. Personal
    keys stay personal -- a profile can still name one, and it is added
    alongside this rather than replacing it.
#>
function New-LinuxAutomationKey {
    [CmdletBinding()]
    param([string]$Path = (Join-Path $env:USERPROFILE '.ssh\linux-on-hyperv-auto'))

    if (-not (Test-Path -LiteralPath "$Path.pub")) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
        Write-Step 'Creating the automation SSH key'
        # -N "" from PowerShell hands ssh-keygen a literal pair of quote
        # characters as the passphrase, so the key ends up encrypted with '""'
        # and nothing can use it -- including the ssh-keygen check below, which
        # is how this was caught. Letting cmd parse the arguments avoids it.
        & cmd.exe /c "ssh-keygen -t ed25519 -f ""$Path"" -N """" -C ""linux-on-hyperv automation"" -q" 2>&1 | Out-Null
        if (-not (Test-Path -LiteralPath "$Path.pub")) { throw "ssh-keygen did not produce $Path.pub" }
        Write-Ok "wrote $Path (no passphrase, for these VMs only)"
    }

    # Refuse to hand back a key that cannot sign unattended, rather than
    # building another guest nothing can log into.
    & ssh-keygen -y -f $Path 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "$Path is passphrase-protected, so automation cannot use it. Delete it and this will recreate it."
    }

    (Get-Content -LiteralPath "$Path.pub" -Raw).Trim()
}
