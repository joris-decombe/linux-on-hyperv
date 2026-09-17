#Requires -Version 5.1

# Order matters: Common defines the defaults and logging the rest lean on.
$libs = @('Common.ps1', 'Preflight.ps1', 'Vm.ps1', 'Credential.ps1', 'FatImage.ps1', 'Kickstart.ps1', 'Profile.ps1', 'Guest.ps1', 'Wsl.ps1')
foreach ($lib in $libs) {
    . (Join-Path $PSScriptRoot "lib/$lib")
}

Export-ModuleMember -Function @(
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
    'Test-RdpHandshake'
    'Connect-LinuxVM'
    'Remove-LinuxVM'
    'Get-LinuxVMAddress'
    'Start-LinuxDesktop'
    'Copy-GuestKit'
    'Start-WslApp'
    'Test-WslGpu'
    'Get-WslDistro'
)
