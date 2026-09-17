<#
A FAT16 disk image, written byte by byte.

This exists because of a three-way squeeze:

  * Kickstart media has to be a volume labeled OEMDRV that Anaconda can see.
  * Putting it on a second optical drive breaks the Fedora netinst outright:
    the installer boots with root=live:CDLABEL=..., and with two discs present
    dracut wedges at initrd-switch-root and never reaches Anaconda. Measured,
    twice: disc attached, hang; disc removed, welcome screen in two minutes.
  * Putting it on a VHDX means formatting it, which means Mount-VHD, which
    attaches a disk to Windows itself and requires Administrator -- more
    privilege than the rest of this module needs, and a UAC prompt in front of
    the one workflow whose entire purpose is to remove interaction.

The way out is to not ask Windows to format anything. `New-VHD -Fixed` works
unelevated, and a fixed VHD is simply the raw disk image followed by a
512-byte 'conectix' footer -- so the filesystem can be written with ordinary
file I/O. FAT16 is small enough to emit by hand and is what Anaconda expects.

The layout is an MBR with one partition rather than a bare "superfloppy",
because that is what a real USB stick looks like and therefore the shape
Anaconda's OEMDRV lookup is known to handle.
#>

$script:SectorSize = 512

<#
.SYNOPSIS
    Create a fixed VHD containing a single FAT16 partition.

.PARAMETER Files
    Ordered map of 8.3 file name to string contents, e.g. @{ 'ks.cfg' = $text }.

.EXAMPLE
    New-FatVhd -Path D:\vm\ks.vhd -Label OEMDRV -Files @{ 'ks.cfg' = $content }
#>
function New-FatVhd {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Files,
        [string]$Label = 'OEMDRV',
        [uint64]$SizeBytes = 64MB,
        [switch]$Force
    )

    if (Test-Path -LiteralPath $Path) {
        if (-not $Force) { throw "Image already exists: $Path (pass -Force to replace it)" }
        Remove-Item -LiteralPath $Path -Force
    }

    Write-Step "Building the $Label FAT16 image"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null

    # New-VHD gives a correctly formed fixed VHD -- header, geometry, footer --
    # without elevation. We only rewrite the payload area inside it.
    New-VHD -Path $Path -SizeBytes $SizeBytes -Fixed -ErrorAction Stop | Out-Null

    try {
        $totalSectors = [uint32]($SizeBytes / $script:SectorSize)
        $partitionStart = [uint32]2048            # 1 MiB in, the usual alignment
        $partitionSectors = $totalSectors - $partitionStart

        $image = New-Fat16Volume -Files $Files -Label $Label `
            -SectorCount $partitionSectors -HiddenSectors $partitionStart

        $stream = [IO.File]::Open($Path, 'Open', 'Write')
        try {
            $stream.Seek(0, 'Begin') | Out-Null
            $stream.Write((New-MbrSector -PartitionStart $partitionStart -PartitionSectors $partitionSectors), 0, $script:SectorSize)

            $stream.Seek([long]$partitionStart * $script:SectorSize, 'Begin') | Out-Null
            $stream.Write($image, 0, $image.Length)
            $stream.Flush()
        } finally {
            $stream.Dispose()
        }

        Write-Ok ("wrote {0} ({1} -> {2})" -f $Path, $Label, (($Files.Keys | Sort-Object) -join ', '))
        $Path
    } catch {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        throw
    }
}

# A minimal MBR: no boot code, one FAT16 LBA partition.
function New-MbrSector {
    param([uint32]$PartitionStart, [uint32]$PartitionSectors)

    $mbr = [byte[]]::new($script:SectorSize)
    $entry = 446
    $mbr[$entry] = 0x00                       # not bootable; this is data only
    $mbr[$entry + 1] = 0xFE                   # CHS start, "use LBA instead"
    $mbr[$entry + 2] = 0xFF
    $mbr[$entry + 3] = 0xFF
    $mbr[$entry + 4] = 0x0E                   # FAT16 LBA
    $mbr[$entry + 5] = 0xFE                   # CHS end, ditto
    $mbr[$entry + 6] = 0xFF
    $mbr[$entry + 7] = 0xFF
    [Array]::Copy([BitConverter]::GetBytes($PartitionStart), 0, $mbr, $entry + 8, 4)
    [Array]::Copy([BitConverter]::GetBytes($PartitionSectors), 0, $mbr, $entry + 12, 4)
    $mbr[510] = 0x55
    $mbr[511] = 0xAA
    $mbr
}

<#
Builds the whole FAT16 volume in memory: boot sector, two FATs, root
directory, data.

Geometry is chosen rather than computed by search: 2 KiB clusters over a 64 MiB
volume give ~32k clusters, comfortably inside FAT16's valid 4085..65524 range,
so a 128-sector FAT covers it with room to spare.
#>
function New-Fat16Volume {
    param(
        [hashtable]$Files,
        [string]$Label,
        [uint32]$SectorCount,
        [uint32]$HiddenSectors
    )

    $sectorsPerCluster = 4
    $reservedSectors = 1
    $fatCount = 2
    $rootEntries = 512
    $rootSectors = [uint32](($rootEntries * 32) / $script:SectorSize)
    $sectorsPerFat = [uint32]128

    $clusterBytes = $sectorsPerCluster * $script:SectorSize
    $dataStart = $reservedSectors + ($fatCount * $sectorsPerFat) + $rootSectors
    $clusterCount = [uint32](($SectorCount - $dataStart) / $sectorsPerCluster)
    if ($clusterCount -lt 4085 -or $clusterCount -gt 65524) {
        throw "Geometry gives $clusterCount clusters, outside FAT16's 4085..65524. Adjust size or sectors per cluster."
    }

    $volume = [byte[]]::new([int]$SectorCount * $script:SectorSize)

    # --- boot sector -------------------------------------------------------
    $bs = $volume
    $bs[0] = 0xEB; $bs[1] = 0x3C; $bs[2] = 0x90                        # jump
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('MSWIN4.1'), 0, $bs, 3, 8)
    [Array]::Copy([BitConverter]::GetBytes([uint16]$script:SectorSize), 0, $bs, 11, 2)
    $bs[13] = [byte]$sectorsPerCluster
    [Array]::Copy([BitConverter]::GetBytes([uint16]$reservedSectors), 0, $bs, 14, 2)
    $bs[16] = [byte]$fatCount
    [Array]::Copy([BitConverter]::GetBytes([uint16]$rootEntries), 0, $bs, 17, 2)
    # Total sectors does not fit in the 16-bit field, so it goes in the 32-bit
    # one and the small field stays zero. Getting this wrong makes Linux read
    # the volume as tiny and silently truncate it.
    [Array]::Copy([BitConverter]::GetBytes([uint16]0), 0, $bs, 19, 2)
    $bs[21] = 0xF8                                                      # fixed disk
    [Array]::Copy([BitConverter]::GetBytes([uint16]$sectorsPerFat), 0, $bs, 22, 2)
    [Array]::Copy([BitConverter]::GetBytes([uint16]63), 0, $bs, 24, 2)  # sectors per track
    [Array]::Copy([BitConverter]::GetBytes([uint16]255), 0, $bs, 26, 2) # heads
    [Array]::Copy([BitConverter]::GetBytes([uint32]$HiddenSectors), 0, $bs, 28, 4)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$SectorCount), 0, $bs, 32, 4)
    $bs[36] = 0x80                                                      # drive number
    $bs[38] = 0x29                                                      # extended boot signature
    [Array]::Copy([BitConverter]::GetBytes([uint32](Get-Random -Minimum 1 -Maximum ([int]::MaxValue))), 0, $bs, 39, 4)
    [Array]::Copy((ConvertTo-FatName $Label 11), 0, $bs, 43, 11)
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('FAT16   '), 0, $bs, 54, 8)
    $bs[510] = 0x55; $bs[511] = 0xAA

    # --- allocate clusters and fill the root directory ---------------------
    $fat = [byte[]]::new([int]$sectorsPerFat * $script:SectorSize)
    $fat[0] = 0xF8; $fat[1] = 0xFF; $fat[2] = 0xFF; $fat[3] = 0xFF      # reserved entries

    $root = [byte[]]::new([int]$rootSectors * $script:SectorSize)
    $rootOffset = 0

    # Volume label lives in the root directory as an entry with the volume
    # attribute. blkid reads the boot sector's copy, but the directory entry is
    # what several tools show, so write both and keep them identical.
    [Array]::Copy((ConvertTo-FatName $Label 11), 0, $root, $rootOffset, 11)
    $root[$rootOffset + 11] = 0x08
    $rootOffset += 32

    $nextCluster = 2
    foreach ($name in ($Files.Keys | Sort-Object)) {
        $content = [Text.Encoding]::UTF8.GetBytes([string]$Files[$name])
        $clusters = [Math]::Max(1, [Math]::Ceiling($content.Length / $clusterBytes))
        $first = $nextCluster

        for ($i = 0; $i -lt $clusters; $i++) {
            $c = $first + $i
            $value = if ($i -eq $clusters - 1) { 0xFFFF } else { $c + 1 }
            [Array]::Copy([BitConverter]::GetBytes([uint16]$value), 0, $fat, $c * 2, 2)
        }

        [Array]::Copy((ConvertTo-FatName ([IO.Path]::GetFileNameWithoutExtension($name)) 8), 0, $root, $rootOffset, 8)
        [Array]::Copy((ConvertTo-FatName ([IO.Path]::GetExtension($name).TrimStart('.')) 3), 0, $root, $rootOffset + 8, 3)
        $root[$rootOffset + 11] = 0x20                                   # archive
        [Array]::Copy([BitConverter]::GetBytes([uint16]$first), 0, $root, $rootOffset + 26, 2)
        [Array]::Copy([BitConverter]::GetBytes([uint32]$content.Length), 0, $root, $rootOffset + 28, 4)
        $rootOffset += 32

        $dataOffset = ($dataStart + (($first - 2) * $sectorsPerCluster)) * $script:SectorSize
        [Array]::Copy($content, 0, $volume, $dataOffset, $content.Length)

        $nextCluster += $clusters
    }

    # Both FAT copies must match; fsck and some drivers compare them.
    for ($f = 0; $f -lt $fatCount; $f++) {
        [Array]::Copy($fat, 0, $volume, ($reservedSectors + ($f * $sectorsPerFat)) * $script:SectorSize, $fat.Length)
    }
    [Array]::Copy($root, 0, $volume, ($reservedSectors + ($fatCount * $sectorsPerFat)) * $script:SectorSize, $root.Length)

    $volume
}

# FAT 8.3 names are space-padded, upper case, and fixed width.
function ConvertTo-FatName {
    param([string]$Text, [int]$Width)

    $clean = ($Text -replace '[^A-Za-z0-9_\-]', '').ToUpperInvariant()
    if ($clean.Length -gt $Width) { $clean = $clean.Substring(0, $Width) }
    [Text.Encoding]::ASCII.GetBytes($clean.PadRight($Width, ' '))
}
