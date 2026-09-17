@{
    RootModule        = 'HyperVLinux.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = 'a3f1c6e4-7b2d-4f18-9c31-5e0d8a2b6417'
    Author            = 'Joris Decombe'
    Description       = 'Run a Linux desktop in a Hyper-V VM on Windows, with display and sound over RDP.'
    PowerShellVersion = '5.1'
    RequiredModules   = @('Hyper-V')
    FunctionsToExport = @(
        'Test-HyperVHost'
        'New-LinuxVM'
    'New-KickstartDisk'
    'New-KickstartIso'
    'New-KickstartVhd'
    'New-FatVhd'
    'New-KickstartContent'
    'Add-KickstartMedia'
    'Remove-KickstartMedia'
    'Wait-LinuxInstall'
    'New-LinuxPasswordHash'
    'New-LinuxPassword'
    'Save-LinuxVMCredential'
    'Get-LinuxVMCredential'
    'Remove-LinuxVMCredential'
    'Add-KickstartDisk'
    'Update-KickstartDisk'
    'Get-LinuxProfile'
    'New-LinuxProfile'
    'Invoke-LinuxProfile'
    'Wait-LinuxDesktop'
        'Connect-LinuxVM'
        'Remove-LinuxVM'
        'Get-LinuxVMAddress'
        'Start-LinuxDesktop'
        'Copy-GuestKit'
    'Start-WslApp'
    'Test-WslGpu'
    'Get-WslDistro'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{ PSData = @{
        Tags       = @('Hyper-V', 'Linux', 'Fedora', 'GNOME', 'RDP')
        LicenseUri = 'https://opensource.org/licenses/MIT'
    } }
}
