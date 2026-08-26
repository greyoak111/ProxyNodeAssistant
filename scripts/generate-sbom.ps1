[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,
    [string]$Root = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)),
    [string]$Version = "0.9.5"
)

$ErrorActionPreference = "Stop"
$Root = [IO.Path]::GetFullPath($Root)
$OutputPath = [IO.Path]::GetFullPath($OutputPath)

function New-SpdxPackage {
    param(
        [string]$Name,
        [string]$PackageVersion,
        [string]$DownloadLocation = "NOASSERTION",
        [string]$Supplier = "NOASSERTION"
    )
    $id = ($Name -replace '[^A-Za-z0-9.-]', '-') -replace '-+', '-'
    [ordered]@{
        SPDXID = "SPDXRef-Package-$id"
        name = $Name
        versionInfo = $PackageVersion
        downloadLocation = $DownloadLocation
        filesAnalyzed = $false
        licenseConcluded = "NOASSERTION"
        licenseDeclared = "NOASSERTION"
        copyrightText = "NOASSERTION"
        supplier = $Supplier
    }
}

$packages = [Collections.Generic.List[object]]::new()
$packages.Add((New-SpdxPackage -Name "TextNodeAssistant" -PackageVersion $Version -DownloadLocation "NOASSERTION" -Supplier "Organization: TextNodeAssistant contributors"))

$goMod = Get-Content -LiteralPath (Join-Path $Root "go.mod") -Raw
foreach ($match in [regex]::Matches($goMod, '(?m)^\s*([A-Za-z0-9._~/-]+)\s+(v[^\s]+)')) {
    $moduleName = $match.Groups[1].Value
    $moduleVersion = $match.Groups[2].Value
    $packages.Add((New-SpdxPackage -Name $moduleName -PackageVersion $moduleVersion -DownloadLocation ("https://proxy.golang.org/" + $moduleName + "/@v/" + $moduleVersion + ".zip")))
}

$androidFiles = @(
    (Join-Path $Root "android\build.gradle.kts"),
    (Join-Path $Root "android\app\build.gradle.kts")
)
foreach ($file in $androidFiles) {
    $content = Get-Content -LiteralPath $file -Raw
    foreach ($match in [regex]::Matches($content, '(?:implementation|testImplementation|androidTestImplementation|platform)\("([^":]+):([^":]+):([^"\)]+)"\)')) {
        $group = $match.Groups[1].Value
        $artifact = $match.Groups[2].Value
        $dependencyVersion = $match.Groups[3].Value
        $packages.Add((New-SpdxPackage -Name "${group}:$artifact" -PackageVersion $dependencyVersion -DownloadLocation "NOASSERTION"))
    }
    foreach ($match in [regex]::Matches($content, 'id\("([^"]+)"\)\s+version\s+"([^"]+)"')) {
        $packages.Add((New-SpdxPackage -Name $match.Groups[1].Value -PackageVersion $match.Groups[2].Value -DownloadLocation "NOASSERTION"))
    }
}

$lockPath = Join-Path $Root "runbook\text-node-assistant-v$Version\THIRD_PARTY_LOCK.env"
$lock = @{}
foreach ($line in Get-Content -LiteralPath $lockPath) {
    if ($line -match '^([A-Z0-9_]+)=(.+)$') { $lock[$matches[1]] = $matches[2] }
}
foreach ($thirdParty in @(
    @{ Name = "3x-ui"; VersionKey = "THREEXUI_VERSION"; UrlKey = "THREEXUI_ASSET_BASE_URL" },
    @{ Name = "copyparty"; VersionKey = "COPYPARTY_VERSION"; UrlKey = "COPYPARTY_SFX_URL" },
    @{ Name = "rclone"; VersionKey = "RCLONE_VERSION"; UrlKey = "RCLONE_URL_AMD64" },
    @{ Name = "WinFsp"; VersionKey = "WINFSP_VERSION"; UrlKey = "WINFSP_MSI_URL" }
)) {
    $packages.Add((New-SpdxPackage -Name $thirdParty.Name -PackageVersion $lock[$thirdParty.VersionKey] -DownloadLocation $lock[$thirdParty.UrlKey]))
}

$uniquePackages = @($packages | Group-Object { $_.SPDXID + '|' + $_.versionInfo } | ForEach-Object { $_.Group[0] })
$rootPackage = $uniquePackages | Where-Object SPDXID -eq "SPDXRef-Package-TextNodeAssistant" | Select-Object -First 1
$relationships = [Collections.Generic.List[object]]::new()
$relationships.Add([ordered]@{
    spdxElementId = "SPDXRef-DOCUMENT"
    relationshipType = "DESCRIBES"
    relatedSpdxElement = $rootPackage.SPDXID
})
foreach ($dependency in $uniquePackages | Where-Object SPDXID -ne $rootPackage.SPDXID) {
    $relationships.Add([ordered]@{
        spdxElementId = $rootPackage.SPDXID
        relationshipType = "DEPENDS_ON"
        relatedSpdxElement = $dependency.SPDXID
    })
}

$toolkitHash = (Get-FileHash -LiteralPath (Join-Path $Root "assets\text-node-assistant-toolkit-v$Version.tar.gz") -Algorithm SHA256).Hash.ToLowerInvariant()
$created = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
$document = [ordered]@{
    spdxVersion = "SPDX-2.3"
    dataLicense = "CC0-1.0"
    SPDXID = "SPDXRef-DOCUMENT"
    name = "TextNodeAssistant-v$Version"
    documentNamespace = "https://text-node-assistant.invalid/spdx/v$Version/$toolkitHash"
    creationInfo = [ordered]@{
        created = $created
        creators = @("Tool: TextNodeAssistant-generate-sbom.ps1")
        licenseListVersion = "3.26"
    }
    documentDescribes = @($rootPackage.SPDXID)
    packages = $uniquePackages
    relationships = @($relationships)
    annotations = @([ordered]@{
        annotationDate = $created
        annotationType = "OTHER"
        annotator = "Tool: TextNodeAssistant-generate-sbom.ps1"
        comment = "Pinned remote artifacts and direct Go/Android build dependencies. Transitive Android/OS packages remain subject to their upstream lockfiles and package managers."
    })
}

$parent = Split-Path -Parent $OutputPath
if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
[IO.File]::WriteAllText($OutputPath, (($document | ConvertTo-Json -Depth 12) + "`n"), [Text.UTF8Encoding]::new($false))
Get-Item -LiteralPath $OutputPath | Select-Object FullName, Length
