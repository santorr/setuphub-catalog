[CmdletBinding()]
param(
    [switch]$SkipWinget
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$catalogPath = Join-Path $repoRoot "packages.json"
$iconsPath = Join-Path $repoRoot "icons"
$failures = New-Object System.Collections.Generic.List[string]
$supportedSources = @("winget", "msstore", "steam")

function Add-Failure {
    param([Parameter(Mandatory = $true)][string]$Message)

    $failures.Add($Message) | Out-Null
    if ($env:GITHUB_ACTIONS -eq "true") {
        Write-Output "::error title=Catalog validation::$Message"
    } else {
        Write-Output "ERROR: $Message"
    }
}

function Test-RequiredString {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$PropertyName,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if (-not ($Object.PSObject.Properties.Name -contains $PropertyName)) {
        Add-Failure "$Context is missing '$PropertyName'."
        return
    }

    $value = $Object.$PropertyName
    if ($null -eq $value -or -not ($value -is [string]) -or [string]::IsNullOrWhiteSpace($value)) {
        Add-Failure "$Context has an invalid '$PropertyName'."
    }
}

function Get-PackageReferences {
    param(
        [Parameter(Mandatory = $true)][array]$Catalog
    )

    $references = New-Object System.Collections.Generic.List[object]
    foreach ($package in $Catalog) {
        if ($package.PSObject.Properties.Name -contains "installers" -and $null -ne $package.installers) {
            foreach ($installer in @($package.installers)) {
                if ($installer.PSObject.Properties.Name -contains "package_id") {
                    $installerName = if ($installer.PSObject.Properties.Name -contains "name" -and -not [string]::IsNullOrWhiteSpace($installer.name)) {
                        $installer.name
                    } else {
                        $package.name
                    }
                    $source = if ($installer.PSObject.Properties.Name -contains "source" -and -not [string]::IsNullOrWhiteSpace($installer.source)) {
                        ([string]$installer.source).Trim().ToLowerInvariant()
                    } else {
                        "winget"
                    }

                    $references.Add([pscustomobject]@{
                        Name = $installerName
                        Id = $installer.package_id
                        Source = $source
                        Key = "$source::$($installer.package_id)"
                        Context = "installer '$installerName' of '$($package.name)'"
                    }) | Out-Null
                }
            }
        }
    }

    return $references
}

function Get-DependencyReferences {
    param(
        [Parameter(Mandatory = $true)][array]$Catalog
    )

    $references = New-Object System.Collections.Generic.List[object]
    foreach ($package in $Catalog) {
        if (-not ($package.PSObject.Properties.Name -contains "installers") -or $null -eq $package.installers) {
            continue
        }

        foreach ($installer in @($package.installers)) {
            if (-not ($installer.PSObject.Properties.Name -contains "dependencies") -or $null -eq $installer.dependencies) {
                continue
            }

            $installerName = if ($installer.PSObject.Properties.Name -contains "name" -and -not [string]::IsNullOrWhiteSpace($installer.name)) {
                $installer.name
            } else {
                $package.name
            }

            foreach ($dependency in @($installer.dependencies)) {
                if (-not ($dependency.PSObject.Properties.Name -contains "package_id")) {
                    continue
                }

                $source = if ($dependency.PSObject.Properties.Name -contains "source" -and -not [string]::IsNullOrWhiteSpace($dependency.source)) {
                    ([string]$dependency.source).Trim().ToLowerInvariant()
                } else {
                    "winget"
                }

                $references.Add([pscustomobject]@{
                    Id = $dependency.package_id
                    Source = $source
                    Key = "$source::$($dependency.package_id)"
                    Context = "dependency '$($dependency.package_id)' of installer '$installerName' in '$($package.name)'"
                }) | Out-Null
            }
        }
    }

    return $references
}

function Get-PythonRunner {
    <#
    .SYNOPSIS
        Finds a Python command able to read SQLite databases.
    #>

    $candidates = @(
        [pscustomobject]@{ Command = "python"; Arguments = @() },
        [pscustomobject]@{ Command = "py"; Arguments = @("-3") },
        [pscustomobject]@{
            Command = (Join-Path (Split-Path -Parent $repoRoot) "setuphub-app\.venv\Scripts\python.exe")
            Arguments = @()
        }
    )

    foreach ($candidate in $candidates) {
        if (-not (Get-Command $candidate.Command -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath $candidate.Command)) {
            continue
        }

        try {
            & $candidate.Command @($candidate.Arguments) -c "import sqlite3" *> $null
        } catch {
            continue
        }

        if ($LASTEXITCODE -eq 0) {
            return $candidate
        }
    }

    throw "Python with sqlite3 is required to read the local Winget index."
}

function Get-WingetSourceIndexPath {
    <#
    .SYNOPSIS
        Returns the local Winget SQLite source index path.
    #>

    Write-Host "Updating Winget source index..."

    try {
        $wingetOutput = & winget source update --name winget 2>&1
        $wingetExitCode = $LASTEXITCODE
    } catch {
        throw "winget source update failed. $($_.Exception.Message)"
    }

    if ($wingetExitCode -ne 0) {
        $details = ($wingetOutput | Out-String).Trim()
        if ($details.Length -gt 600) {
            $details = $details.Substring(0, 600) + "..."
        }

        throw "winget source update failed with exit code $wingetExitCode. $details"
    }

    $sourcePackage = Get-AppxPackage -Name Microsoft.Winget.Source |
        Sort-Object -Property Version -Descending |
        Select-Object -First 1

    if ($null -eq $sourcePackage) {
        throw "The Microsoft.Winget.Source package is not installed after source update."
    }

    $indexPath = Join-Path $sourcePackage.InstallLocation "Public\index.db"

    if (-not (Test-Path -LiteralPath $indexPath)) {
        throw "The local Winget source index was not found at $indexPath."
    }

    return $indexPath
}

function Get-WingetIndexIds {
    <#
    .SYNOPSIS
        Reads all available Winget package identifiers from the local index.
    #>

    Write-Host "Loading Winget package IDs from local index..."

    $indexPath = Get-WingetSourceIndexPath
    $python = Get-PythonRunner
    $pythonScript = "import sqlite3, sys; con = sqlite3.connect(sys.argv[1]); [print(row[0]) for row in con.execute('select id from packages')]"
    $idsOutput = & $python.Command @($python.Arguments) -c $pythonScript $indexPath

    if ($LASTEXITCODE -ne 0) {
        throw "Python could not read the local Winget index at $indexPath."
    }

    $ids = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($id in @($idsOutput)) {
        $normalizedId = ([string]$id).Trim()

        if (-not [string]::IsNullOrWhiteSpace($normalizedId)) {
            $ids.Add($normalizedId) | Out-Null
        }
    }

    if ($ids.Count -eq 0) {
        throw "The local Winget index returned no package IDs."
    }

    return $ids
}

if (-not (Test-Path -LiteralPath $catalogPath)) {
    throw "Missing packages.json at $catalogPath."
}

if (-not (Test-Path -LiteralPath $iconsPath)) {
    throw "Missing icons directory at $iconsPath."
}

try {
    $catalog = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json
} catch {
    throw "packages.json is not valid JSON. $($_.Exception.Message)"
}

if (-not ($catalog -is [array])) {
    Add-Failure "packages.json must contain a JSON array at the root."
    $catalog = @($catalog)
}

if ($catalog.Count -eq 0) {
    Add-Failure "packages.json must contain at least one package."
}

for ($index = 0; $index -lt $catalog.Count; $index++) {
    $package = $catalog[$index]
    $context = "package at index $index"

    foreach ($field in @("name", "icon", "category", "description")) {
        Test-RequiredString -Object $package -PropertyName $field -Context $context
    }

    $hasInstallers = $package.PSObject.Properties.Name -contains "installers" -and $null -ne $package.installers -and @($package.installers).Count -gt 0

    if ($package.PSObject.Properties.Name -contains "package_id") {
        Add-Failure "$context must not define root 'package_id'. Use 'installers' instead."
    }

    if ($package.PSObject.Properties.Name -contains "variants") {
        Add-Failure "$context must not define 'variants'. Use 'installers' instead."
    }

    if (-not $hasInstallers) {
        Add-Failure "$context must define at least one installer."
    }

    if (-not ($package.PSObject.Properties.Name -contains "id")) {
        Add-Failure "$context must define stable 'id'."
    } else {
        Test-RequiredString -Object $package -PropertyName "id" -Context $context
    }

    if (-not ($package.PSObject.Properties.Name -contains "tags")) {
        Add-Failure "$context is missing 'tags'."
    } else {
        $tags = @($package.tags)
        if ($tags.Count -eq 0) {
            Add-Failure "$context must have at least one tag."
        }

        foreach ($tag in $tags) {
            if ($null -eq $tag -or -not ($tag -is [string]) -or [string]::IsNullOrWhiteSpace($tag)) {
                Add-Failure "$context contains an invalid tag."
            }
        }
    }

    if ($package.PSObject.Properties.Name -contains "icon" -and $package.icon -is [string] -and -not [string]::IsNullOrWhiteSpace($package.icon)) {
        $iconFile = Join-Path $iconsPath $package.icon
        if (-not (Test-Path -LiteralPath $iconFile)) {
            Add-Failure "Icon '$($package.icon)' referenced by '$($package.name)' does not exist."
        }
    }

    if ($package.PSObject.Properties.Name -contains "installers" -and $null -ne $package.installers) {
        $installerCount = @($package.installers).Count
        foreach ($installer in @($package.installers)) {
            $installerContext = "installer of '$($package.name)'"

            if ($installerCount -gt 1) {
                Test-RequiredString -Object $installer -PropertyName "name" -Context $installerContext

                if ($installer.PSObject.Properties.Name -contains "name") {
                    $installerContext = "installer '$($installer.name)' of '$($package.name)'"
                }
            }

            Test-RequiredString -Object $installer -PropertyName "package_id" -Context $installerContext

            if ($installer.PSObject.Properties.Name -contains "source") {
                Test-RequiredString -Object $installer -PropertyName "source" -Context $installerContext

                $isUnsupportedSource = (
                    ($null -ne $installer.source) -and
                    ($installer.source -is [string]) -and
                    (-not [string]::IsNullOrWhiteSpace($installer.source)) -and
                    ($supportedSources -notcontains $installer.source.Trim().ToLowerInvariant())
                )

                if ($isUnsupportedSource) {
                    Add-Failure "$installerContext has unsupported source '$($installer.source)'. Supported sources: $($supportedSources -join ', ')."
                }
            }

            if ($installer.PSObject.Properties.Name -contains "dependencies" -and $null -ne $installer.dependencies) {
                foreach ($dependency in @($installer.dependencies)) {
                    $dependencyContext = "dependency of $installerContext"
                    Test-RequiredString -Object $dependency -PropertyName "package_id" -Context $dependencyContext

                    if ($dependency.PSObject.Properties.Name -contains "source") {
                        Test-RequiredString -Object $dependency -PropertyName "source" -Context $dependencyContext

                        $isUnsupportedDependencySource = (
                            ($null -ne $dependency.source) -and
                            ($dependency.source -is [string]) -and
                            (-not [string]::IsNullOrWhiteSpace($dependency.source)) -and
                            ($supportedSources -notcontains $dependency.source.Trim().ToLowerInvariant())
                        )

                        if ($isUnsupportedDependencySource) {
                            Add-Failure "$dependencyContext has unsupported source '$($dependency.source)'. Supported sources: $($supportedSources -join ', ')."
                        }
                    }
                }
            }
        }
    }
}

$allPackageReferences = @(Get-PackageReferences -Catalog $catalog)
$allDependencyReferences = @(Get-DependencyReferences -Catalog $catalog)
$wingetPackageReferences = @(
    $allPackageReferences |
        Where-Object { $_.Source -eq "winget" }
)
$installerKeys = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

foreach ($reference in $allPackageReferences) {
    $installerKeys.Add($reference.Key) | Out-Null
}

foreach ($dependency in $allDependencyReferences) {
    if ([string]::IsNullOrWhiteSpace($dependency.Id)) {
        continue
    }

    if (-not $installerKeys.Contains($dependency.Key)) {
        Add-Failure "$($dependency.Context) does not reference an installer in the catalog."
    }
}
$duplicateIds = $allPackageReferences |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_.Id) } |
    Group-Object -Property Key |
    Where-Object { $_.Count -gt 1 }

foreach ($duplicate in $duplicateIds) {
    $contexts = ($duplicate.Group | ForEach-Object { $_.Context }) -join ", "
    Add-Failure "Duplicate installer '$($duplicate.Name)' used by $contexts."
}

if (-not $SkipWinget) {
    $wingetCommand = Get-Command winget -ErrorAction SilentlyContinue
    if ($null -eq $wingetCommand) {
        Add-Failure "winget is not available. Install Windows Package Manager or run with -SkipWinget for structure-only validation."
    } else {
        Write-Output "Checking $($wingetPackageReferences.Count) Winget package IDs against the Winget index..."

        try {
            $wingetIds = Get-WingetIndexIds
            Write-Output "Loaded $($wingetIds.Count) Winget package IDs."
        } catch {
            Add-Failure $_.Exception.Message
            $wingetIds = $null
        }

        if ($null -ne $wingetIds) {
            foreach ($reference in $wingetPackageReferences) {
                if ([string]::IsNullOrWhiteSpace($reference.Id) -or $wingetIds.Contains($reference.Id)) {
                    continue
                }

                Add-Failure "winget index does not contain '$($reference.Id)' for $($reference.Context)."
            }
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Output ""
    Write-Output "Catalog validation failed with $($failures.Count) error(s)."
    exit 1
}

$sourceSummary = (
    $allPackageReferences |
        Group-Object -Property Source |
        ForEach-Object { "$($_.Name): $($_.Count)" }
) -join ", "
Write-Output "Catalog validation passed for $($catalog.Count) packages, $($allPackageReferences.Count) installers ($sourceSummary) and $($wingetPackageReferences.Count) validated Winget IDs."
