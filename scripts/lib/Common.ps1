Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:DotfilesRepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

function Get-DotfilesRepoRoot {
    return $script:DotfilesRepositoryRoot
}

function Write-DotfilesLog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'CLI progress must not enter the success pipeline.')]
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "==> $Message" -ForegroundColor Blue
}

function Write-DotfilesWarning {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'CLI warnings must not enter the success pipeline.')]
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "warning: $Message" -ForegroundColor Yellow
}

Set-Alias -Name Write-Log -Value Write-DotfilesLog
Set-Alias -Name Write-WarningMessage -Value Write-DotfilesWarning

function Import-ToolManifest {
    param([Parameter(Mandatory = $true)][string]$Path)

    $values = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*([A-Z][A-Z0-9_]*)="([^"]*)"\s*$') {
            $values[$Matches[1]] = $Matches[2]
        }
    }
    return $values
}

function Get-WindowsArchitecture {
    $architecture = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        $architecture = $env:PROCESSOR_ARCHITECTURE
    }

    switch -Regex ($architecture) {
        '^(ARM64|AARCH64)$' { return 'ARM64' }
        '^(AMD64|X86_64)$' { return 'X86_64' }
        default { throw "Unsupported Windows architecture: $architecture" }
    }
}

function Get-DotfilesOptHome {
    if (-not [string]::IsNullOrWhiteSpace($env:DOTFILES_OPT_HOME)) {
        return $env:DOTFILES_OPT_HOME
    }
    return Join-Path $env:LOCALAPPDATA 'Programs\dotfiles'
}

function Get-DotfilesBinHome {
    if (-not [string]::IsNullOrWhiteSpace($env:DOTFILES_BIN_HOME)) {
        return $env:DOTFILES_BIN_HOME
    }
    return Join-Path (Get-DotfilesOptHome) 'bin'
}

function Get-NvimConfigHome {
    return Join-Path $env:LOCALAPPDATA 'nvim'
}

function Get-NvimDataHome {
    return Join-Path $env:LOCALAPPDATA 'nvim-data'
}

function Test-PathEntry {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $null = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Get-ResolvedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -and $null -ne $item.Target) {
        $target = @($item.Target)[0]
        if (-not [System.IO.Path]::IsPathRooted($target)) {
            $target = Join-Path $item.Parent.FullName $target
        }
        return [System.IO.Path]::GetFullPath($target)
    }
    return [System.IO.Path]::GetFullPath($item.FullName)
}

function Backup-Path {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BackupRoot
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $userProfilePath = [System.IO.Path]::GetFullPath($HOME).TrimEnd('\')
    if ($fullPath.StartsWith($userProfilePath, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relative = $fullPath.Substring($userProfilePath.Length).TrimStart('\')
    }
    else {
        $relative = $fullPath.Replace(':', '').TrimStart('\')
    }

    $destination = Join-Path $BackupRoot $relative
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent)
    Move-Item -LiteralPath $Path -Destination $destination
    Write-DotfilesLog "Backed up $Path to $destination"
}

function Connect-ManagedDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$BackupRoot
    )

    $sourcePath = [System.IO.Path]::GetFullPath($Source)
    if (Test-PathEntry $Target) {
        $targetPath = Get-ResolvedPath $Target
        if ($targetPath.Equals($sourcePath, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-DotfilesLog "Already linked: $Target"
            return
        }
        Backup-Path -Path $Target -BackupRoot $BackupRoot
    }

    $null = New-Item -ItemType Directory -Force -Path (Split-Path $Target -Parent)
    try {
        $null = New-Item -ItemType Junction -Path $Target -Target $sourcePath
    }
    catch {
        if (Test-PathEntry $Target) {
            Remove-Item -LiteralPath $Target -Force
        }
        try {
            $null = New-Item -ItemType SymbolicLink -Path $Target -Target $sourcePath
        }
        catch {
            throw "Could not link $Target to $sourcePath. Enable Windows Developer Mode or keep the repository and LOCALAPPDATA on compatible local volumes."
        }
    }
    Write-DotfilesLog "Linked $Target -> $sourcePath"
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-VerifiedDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $null = New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent)
    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and (Get-Sha256 $Path) -eq $Sha256.ToLowerInvariant()) {
        Write-DotfilesLog "Using cached $(Split-Path $Path -Leaf)"
        return
    }

    $partial = "$Path.part"
    Remove-Item -LiteralPath $Path, $partial -Force -ErrorAction SilentlyContinue
    Write-DotfilesLog "Downloading $(Split-Path $Path -Leaf)"
    $null = Invoke-WebRequest -Uri $Uri -OutFile $partial -UseBasicParsing
    Move-Item -LiteralPath $partial -Destination $Path
    if ((Get-Sha256 $Path) -ne $Sha256.ToLowerInvariant()) {
        throw "Checksum mismatch for $Path"
    }
}

function Write-CommandShim {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$BinHome
    )

    $null = New-Item -ItemType Directory -Force -Path $BinHome
    $shim = Join-Path $BinHome "$Name.cmd"
    $content = "@echo off`r`n`"$Executable`" %*`r`n"
    if ((Test-Path -LiteralPath $shim -PathType Leaf) -and (Get-Content -LiteralPath $shim -Raw) -eq $content) {
        Write-DotfilesLog "Already installed shim: $shim"
        return
    }
    Set-Content -LiteralPath $shim -Value $content -Encoding ASCII -NoNewline
    Write-DotfilesLog "Installed shim: $shim"
}

function Add-UserPath {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($current -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if (-not ($entries | Where-Object { $_.TrimEnd('\').Equals($Directory.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase) })) {
        $updated = (@($Directory) + $entries) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $updated, 'User')
        Write-DotfilesLog "Added $Directory to the user PATH"
    }
    if (-not (($env:Path -split ';') | Where-Object { $_.TrimEnd('\').Equals($Directory.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase) })) {
        $env:Path = "$Directory;$env:Path"
    }
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath exited with status $LASTEXITCODE"
    }
}

function Get-MasonReceiptVersion {
    param([Parameter(Mandatory = $true)][string]$Path)

    $receipt = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($receipt.source.id -notmatch '@([^@#]+)(?:#.*)?$') {
        throw "Could not determine version from Mason receipt: $Path"
    }
    return $Matches[1]
}
