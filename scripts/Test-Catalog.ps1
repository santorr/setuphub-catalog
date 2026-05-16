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
    param([Parameter(Mandatory = $true)][array]$Catalog)

    $references = New-Object System.Collections.Generic.List[object]
    foreach ($package in $Catalog) {
        if ($package.PSObject.Properties.Name -contains "package_id") {
            $references.Add([pscustomobject]@{
                Name = $package.name
                Id = $package.package_id
                Context = "package '$($package.name)'"
            }) | Out-Null
        }

        if ($package.PSObject.Properties.Name -contains "variants" -and $null -ne $package.variants) {
            foreach ($variant in @($package.variants)) {
                if ($variant.PSObject.Properties.Name -contains "package_id") {
                    $references.Add([pscustomobject]@{
                        Name = $variant.name
                        Id = $variant.package_id
                        Context = "variant '$($variant.name)' of '$($package.name)'"
                    }) | Out-Null
                }
            }
        }
    }

    return $references
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

    foreach ($field in @("name", "package_id", "icon", "category", "description")) {
        Test-RequiredString -Object $package -PropertyName $field -Context $context
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

    if ($package.PSObject.Properties.Name -contains "variants" -and $null -ne $package.variants) {
        foreach ($variant in @($package.variants)) {
            Test-RequiredString -Object $variant -PropertyName "name" -Context "variant of '$($package.name)'"
            Test-RequiredString -Object $variant -PropertyName "package_id" -Context "variant '$($variant.name)' of '$($package.name)'"
        }
    }
}

$packageReferences = @(Get-PackageReferences -Catalog $catalog)
$duplicateIds = $packageReferences |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_.Id) } |
    Group-Object -Property Id |
    Where-Object { $_.Count -gt 1 }

foreach ($duplicate in $duplicateIds) {
    $contexts = ($duplicate.Group | ForEach-Object { $_.Context }) -join ", "
    Add-Failure "Duplicate package_id '$($duplicate.Name)' used by $contexts."
}

if (-not $SkipWinget) {
    $wingetCommand = Get-Command winget -ErrorAction SilentlyContinue
    if ($null -eq $wingetCommand) {
        Add-Failure "winget is not available. Install Windows Package Manager or run with -SkipWinget for structure-only validation."
    } else {
        Write-Output "Checking $($packageReferences.Count) package IDs with winget..."

        foreach ($reference in $packageReferences) {
            if ([string]::IsNullOrWhiteSpace($reference.Id)) {
                continue
            }

            Write-Output "winget show --id $($reference.Id) --exact"
            try {
                $wingetOutput = & winget show --id $reference.Id --exact --accept-source-agreements --disable-interactivity 2>&1
                $wingetExitCode = $LASTEXITCODE
            } catch {
                $wingetOutput = $_.Exception.Message
                $wingetExitCode = 1
            }

            if ($wingetExitCode -ne 0) {
                $details = ($wingetOutput | Out-String).Trim()
                if ($details.Length -gt 600) {
                    $details = $details.Substring(0, 600) + "..."
                }

                Add-Failure "winget could not resolve '$($reference.Id)' for $($reference.Context). $details"
            }
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Output ""
    Write-Output "Catalog validation failed with $($failures.Count) error(s)."
    exit 1
}

Write-Output "Catalog validation passed for $($catalog.Count) packages and $($packageReferences.Count) winget IDs."
