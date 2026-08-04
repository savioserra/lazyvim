[CmdletBinding()]
param(
    [switch]$Minimal,
    [switch]$NoFont,
    [switch]$NoRestore
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

if ($env:OS -ne 'Windows_NT') {
    throw 'scripts/install.ps1 is the Windows installer; use scripts/install on Linux or macOS.'
}

$RepoRoot = Get-DotfilesRepoRoot
$Tools = Import-ToolManifest (Join-Path $RepoRoot 'manifests\tools.env')
$Architecture = Get-WindowsArchitecture
$Platform = "windows-$($Architecture.ToLowerInvariant())"
$OptHome = Get-DotfilesOptHome
$BinHome = Get-DotfilesBinHome
$ConfigHome = Get-NvimConfigHome
$StateHome = Join-Path $env:LOCALAPPDATA 'dotfiles\state'
$CacheHome = Join-Path $env:LOCALAPPDATA 'dotfiles\cache\downloads'
$BackupRoot = Join-Path $StateHome ("backups\{0}-{1}" -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'), $PID)

$InstallCompanions = -not $Minimal
$InstallFont = -not $Minimal -and -not $NoFont
$RunRestore = -not $NoRestore

if ($RunRestore -and -not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'Git is required to restore plugins. Install Git for Windows or rerun with -NoRestore.'
}

$null = New-Item -ItemType Directory -Force -Path $OptHome, $BinHome, $StateHome, $CacheHome

if ($Architecture -eq 'ARM64') {
    $NeovimUrl = $Tools.NEOVIM_WINDOWS_ARM64_URL
    $NeovimSha256 = $Tools.NEOVIM_WINDOWS_ARM64_SHA256
    $NeovimExtracted = 'nvim-win-arm64'
    $RipgrepUrl = $Tools.RIPGREP_WINDOWS_ARM64_URL
    $RipgrepSha256 = $Tools.RIPGREP_WINDOWS_ARM64_SHA256
    $RipgrepExtracted = "ripgrep-$($Tools.RIPGREP_VERSION)-aarch64-pc-windows-msvc"
    $FdVersion = $Tools.FD_WINDOWS_ARM64_VERSION
    $FdUrl = $Tools.FD_WINDOWS_ARM64_URL
    $FdSha256 = $Tools.FD_WINDOWS_ARM64_SHA256
    $FdExtracted = "fd-v$FdVersion-aarch64-pc-windows-msvc"
    $FzfUrl = $Tools.FZF_WINDOWS_ARM64_URL
    $FzfSha256 = $Tools.FZF_WINDOWS_ARM64_SHA256
    $LazygitUrl = $Tools.LAZYGIT_WINDOWS_ARM64_URL
    $LazygitSha256 = $Tools.LAZYGIT_WINDOWS_ARM64_SHA256
    $TreeSitterUrl = $Tools.TREE_SITTER_WINDOWS_ARM64_URL
    $TreeSitterSha256 = $Tools.TREE_SITTER_WINDOWS_ARM64_SHA256
}
else {
    $NeovimUrl = $Tools.NEOVIM_WINDOWS_X86_64_URL
    $NeovimSha256 = $Tools.NEOVIM_WINDOWS_X86_64_SHA256
    $NeovimExtracted = 'nvim-win64'
    $RipgrepUrl = $Tools.RIPGREP_WINDOWS_X86_64_URL
    $RipgrepSha256 = $Tools.RIPGREP_WINDOWS_X86_64_SHA256
    $RipgrepExtracted = "ripgrep-$($Tools.RIPGREP_VERSION)-x86_64-pc-windows-msvc"
    $FdVersion = $Tools.FD_WINDOWS_X86_64_VERSION
    $FdUrl = $Tools.FD_WINDOWS_X86_64_URL
    $FdSha256 = $Tools.FD_WINDOWS_X86_64_SHA256
    $FdExtracted = "fd-v$FdVersion-x86_64-pc-windows-msvc"
    $FzfUrl = $Tools.FZF_WINDOWS_X86_64_URL
    $FzfSha256 = $Tools.FZF_WINDOWS_X86_64_SHA256
    $LazygitUrl = $Tools.LAZYGIT_WINDOWS_X86_64_URL
    $LazygitSha256 = $Tools.LAZYGIT_WINDOWS_X86_64_SHA256
    $TreeSitterUrl = $Tools.TREE_SITTER_WINDOWS_X86_64_URL
    $TreeSitterSha256 = $Tools.TREE_SITTER_WINDOWS_X86_64_SHA256
}

function Install-ZipDirectory {
    param(
        [string]$Name,
        [string]$Version,
        [string]$Uri,
        [string]$Sha256,
        [string]$ArchiveName,
        [string]$ExtractedName,
        [string]$ExpectedBinary
    )

    $target = Join-Path $OptHome "$Name-$Version"
    if (Test-Path -LiteralPath (Join-Path $target $ExpectedBinary) -PathType Leaf) {
        Write-Log "Already installed: $Name $Version"
        return $target
    }
    if (Test-PathEntry $target) {
        Backup-Path -Path $target -BackupRoot $BackupRoot
    }

    $archive = Join-Path $CacheHome $ArchiveName
    $temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("dotfiles-{0}" -f [guid]::NewGuid())
    Get-VerifiedDownload -Uri $Uri -Sha256 $Sha256 -Path $archive
    $null = New-Item -ItemType Directory -Force -Path $temporary
    try {
        Expand-Archive -LiteralPath $archive -DestinationPath $temporary -Force
        $extracted = Join-Path $temporary $ExtractedName
        if (-not (Test-Path -LiteralPath $extracted -PathType Container)) {
            throw "Unexpected archive layout for $Name"
        }
        Move-Item -LiteralPath $extracted -Destination $target
    }
    finally {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path -LiteralPath (Join-Path $target $ExpectedBinary) -PathType Leaf)) {
        throw "$Name did not install correctly"
    }
    Write-Log "Installed $Name $Version"
    return $target
}

function Install-FlatZip {
    param(
        [string]$Name,
        [string]$Version,
        [string]$Uri,
        [string]$Sha256,
        [string]$ArchiveName,
        [string]$ExpectedBinary
    )

    $target = Join-Path $OptHome "$Name-$Version"
    if (Test-Path -LiteralPath (Join-Path $target $ExpectedBinary) -PathType Leaf) {
        Write-Log "Already installed: $Name $Version"
        return $target
    }
    if (Test-PathEntry $target) {
        Backup-Path -Path $target -BackupRoot $BackupRoot
    }

    $archive = Join-Path $CacheHome $ArchiveName
    Get-VerifiedDownload -Uri $Uri -Sha256 $Sha256 -Path $archive
    $null = New-Item -ItemType Directory -Force -Path $target
    Expand-Archive -LiteralPath $archive -DestinationPath $target -Force
    if (-not (Test-Path -LiteralPath (Join-Path $target $ExpectedBinary) -PathType Leaf)) {
        throw "$Name did not install correctly"
    }
    Write-Log "Installed $Name $Version"
    return $target
}

$NeovimHome = Install-ZipDirectory `
    -Name 'nvim' `
    -Version $Tools.NEOVIM_VERSION `
    -Uri $NeovimUrl `
    -Sha256 $NeovimSha256 `
    -ArchiveName "nvim-$($Tools.NEOVIM_VERSION)-$Platform.zip" `
    -ExtractedName $NeovimExtracted `
    -ExpectedBinary 'bin\nvim.exe'

if ($InstallCompanions) {
    $RipgrepHome = Install-ZipDirectory `
        -Name 'ripgrep' `
        -Version $Tools.RIPGREP_VERSION `
        -Uri $RipgrepUrl `
        -Sha256 $RipgrepSha256 `
        -ArchiveName "ripgrep-$($Tools.RIPGREP_VERSION)-$Platform.zip" `
        -ExtractedName $RipgrepExtracted `
        -ExpectedBinary 'rg.exe'

    $FdHome = Install-ZipDirectory `
        -Name 'fd' `
        -Version $FdVersion `
        -Uri $FdUrl `
        -Sha256 $FdSha256 `
        -ArchiveName "fd-$FdVersion-$Platform.zip" `
        -ExtractedName $FdExtracted `
        -ExpectedBinary 'fd.exe'

    $FzfHome = Install-FlatZip `
        -Name 'fzf' `
        -Version $Tools.FZF_VERSION `
        -Uri $FzfUrl `
        -Sha256 $FzfSha256 `
        -ArchiveName "fzf-$($Tools.FZF_VERSION)-$Platform.zip" `
        -ExpectedBinary 'fzf.exe'

    $LazygitHome = Install-FlatZip `
        -Name 'lazygit' `
        -Version $Tools.LAZYGIT_VERSION `
        -Uri $LazygitUrl `
        -Sha256 $LazygitSha256 `
        -ArchiveName "lazygit-$($Tools.LAZYGIT_VERSION)-$Platform.zip" `
        -ExpectedBinary 'lazygit.exe'

    $TreeSitterHome = Install-FlatZip `
        -Name 'tree-sitter' `
        -Version $Tools.TREE_SITTER_VERSION `
        -Uri $TreeSitterUrl `
        -Sha256 $TreeSitterSha256 `
        -ArchiveName "tree-sitter-$($Tools.TREE_SITTER_VERSION)-$Platform.zip" `
        -ExpectedBinary 'tree-sitter.exe'
}

if ($InstallFont) {
    $fontMarker = Join-Path $StateHome "fonts\JetBrainsMono-$($Tools.NERD_FONT_VERSION).installed"
    $fontHome = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    $regularFont = Join-Path $fontHome 'JetBrainsMonoNerdFont-Regular.ttf'
    if ((Test-Path -LiteralPath $fontMarker -PathType Leaf) -and (Test-Path -LiteralPath $regularFont -PathType Leaf)) {
        Write-Log "Already installed: JetBrainsMono Nerd Font $($Tools.NERD_FONT_VERSION)"
    }
    else {
        $archive = Join-Path $CacheHome "JetBrainsMono-$($Tools.NERD_FONT_VERSION).zip"
        $temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("dotfiles-fonts-{0}" -f [guid]::NewGuid())
        Get-VerifiedDownload -Uri $Tools.NERD_FONT_WINDOWS_URL -Sha256 $Tools.NERD_FONT_WINDOWS_SHA256 -Path $archive
        $null = New-Item -ItemType Directory -Force -Path $temporary, $fontHome
        try {
            Expand-Archive -LiteralPath $archive -DestinationPath $temporary -Force
            $registryPath = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
            $null = New-Item -Path $registryPath -Force
            foreach ($font in Get-ChildItem -LiteralPath $temporary -Recurse -File -Filter '*.ttf') {
                $destination = Join-Path $fontHome $font.Name
                if (Test-Path -LiteralPath $destination -PathType Leaf) {
                    Backup-Path -Path $destination -BackupRoot $BackupRoot
                }
                Copy-Item -LiteralPath $font.FullName -Destination $destination
                $valueName = "$($font.BaseName) (TrueType)"
                $null = New-ItemProperty -Path $registryPath -Name $valueName -Value $destination -PropertyType String -Force
            }
        }
        finally {
            Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
        }
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $fontMarker -Parent)
        Set-Content -LiteralPath $fontMarker -Value $Tools.NERD_FONT_VERSION -Encoding ASCII
        Write-Log "Installed JetBrainsMono Nerd Font $($Tools.NERD_FONT_VERSION)"
    }
}

Connect-ManagedDirectory `
    -Source (Join-Path $RepoRoot 'packages\nvim') `
    -Target $ConfigHome `
    -BackupRoot $BackupRoot

Write-CommandShim -Name 'nvim' -Executable (Join-Path $NeovimHome 'bin\nvim.exe') -BinHome $BinHome
if ($InstallCompanions) {
    Write-CommandShim -Name 'rg' -Executable (Join-Path $RipgrepHome 'rg.exe') -BinHome $BinHome
    Write-CommandShim -Name 'fd' -Executable (Join-Path $FdHome 'fd.exe') -BinHome $BinHome
    Write-CommandShim -Name 'fzf' -Executable (Join-Path $FzfHome 'fzf.exe') -BinHome $BinHome
    Write-CommandShim -Name 'lazygit' -Executable (Join-Path $LazygitHome 'lazygit.exe') -BinHome $BinHome
    Write-CommandShim -Name 'tree-sitter' -Executable (Join-Path $TreeSitterHome 'tree-sitter.exe') -BinHome $BinHome
}
Add-UserPath $BinHome

if ($RunRestore) {
    & (Join-Path $RepoRoot 'scripts\restore.ps1')
}

Write-Log "Installation complete for $Platform"
Write-Output 'Open a new terminal, then run: nvim'
