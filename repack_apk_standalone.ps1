param(
    [Parameter(Mandatory=$true)]
    [string]$InputApk,

    [Parameter(Mandatory=$true)]
    [string]$OutputApk,

    [string]$NewPackage,
    [string]$VersionCode,
    [string]$VersionName,
    [string]$MinSdk,
    [string]$TargetSdk,
    [string]$MaxSdk,
    [string]$WorkDir,
    [switch]$KeepTemp,
    [switch]$FullSmali
)

$ErrorActionPreference = "Stop"

function Resolve-ToolPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    if (Split-Path -Path $Path -IsAbsolute) {
        return $Path
    }
    return Join-Path $PSScriptRoot $Path
}

function Get-FullPathSafe([string]$Path) {
    # [System.IO.Path]::GetFullPath()가 ConstrainedLanguage 모드에서 차단되는 환경을 위한 대체 함수
    if (Split-Path -Path $Path -IsAbsolute) {
        return $Path
    }
    $base = (Get-Location).Path
    return Join-Path $base $Path
}

function Invoke-Checked([string[]]$Command, [string[]]$MaskValues = @()) {
    if ($null -eq $Command -or $Command.Count -eq 0) {
        throw "Command array is null or empty"
    }

    $displayCommand = $Command
    if ($MaskValues.Count -gt 0) {
        $displayCommand = $Command | ForEach-Object {
            $item = $_
            foreach ($m in $MaskValues) {
                if (-not [string]::IsNullOrEmpty($m) -and $item -eq $m) {
                    $item = "****"
                }
            }
            $item
        }
    }
    Write-Host ("$ " + ($displayCommand -join " "))
    
    $exe = $Command[0]
    $argsList = $Command[1..($Command.Count - 1)]
    
    & $exe @argsList
    
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE"
    }
}

function Read-OldPackage([string]$ManifestPath) {
    if ([string]::IsNullOrWhiteSpace($ManifestPath) -or -not (Test-Path -LiteralPath $ManifestPath)) {
        throw "Manifest path is invalid or does not exist: $ManifestPath"
    }
    [xml]$xml = Get-Content -LiteralPath $ManifestPath -Encoding UTF8
    if (-not $xml.manifest.HasAttribute("package")) {
        throw "package attribute not found: $ManifestPath"
    }
    return $xml.manifest.GetAttribute("package")
}

function Update-ManifestPackage([string]$ManifestPath, [string]$OldPackage, [string]$NewPackage) {
    if ([string]::IsNullOrWhiteSpace($NewPackage) -or ($NewPackage -eq "null") -or ($NewPackage -eq $OldPackage)) {
        return
    }
    [xml]$xml = Get-Content -LiteralPath $ManifestPath -Encoding UTF8
    if ($xml.manifest.GetAttribute("package") -eq $OldPackage) {
        $xml.manifest.SetAttribute("package", $NewPackage)
        $xml.Save($ManifestPath)
        Write-Host "-> Manifest: Updated package name to $NewPackage"
    } else {
        throw "expected package $OldPackage in $ManifestPath"
    }
}

function Update-ManifestMetadata([string]$ManifestPath, [string]$VersionCode, [string]$VersionName, [string]$MinSdk, [string]$TargetSdk, [string]$MaxSdk) {
    [xml]$xml = Get-Content -LiteralPath $ManifestPath -Encoding UTF8
    $nsUri = "http://schemas.android.com/apk/res/android"
    $modified = $false

    $hasVCode = (-not [string]::IsNullOrWhiteSpace($VersionCode)) -and ($VersionCode -ne "null")
    $hasVName = (-not [string]::IsNullOrWhiteSpace($VersionName)) -and ($VersionName -ne "null")
    $hasMin   = (-not [string]::IsNullOrWhiteSpace($MinSdk)) -and ($MinSdk -ne "null")
    $hasTarget = (-not [string]::IsNullOrWhiteSpace($TargetSdk))
    $hasMax   = (-not [string]::IsNullOrWhiteSpace($MaxSdk))

    if ($hasVCode) {
        $xml.manifest.SetAttribute("versionCode", $nsUri, $VersionCode)
        Write-Host "-> Manifest: Updated versionCode to $VersionCode"
        $modified = $true
    }

    if ($hasVName) {
        $xml.manifest.SetAttribute("versionName", $nsUri, $VersionName)
        Write-Host "-> Manifest: Updated versionName to $VersionName"
        $modified = $true
    }

    $usesSdkNode = $xml.SelectSingleNode("/manifest/uses-sdk")
    $hasNewSdkValue = $hasMin -or $hasTarget -or $hasMax

    if ($null -eq $usesSdkNode -and $hasNewSdkValue) {
        $usesSdkNode = $xml.CreateElement("uses-sdk")
        [void]$xml.manifest.AppendChild($usesSdkNode)
        Write-Host "-> Manifest: Created missing <uses-sdk> element securely."
    }

    if ($null -ne $usesSdkNode) {
        if ($hasMin) {
            $usesSdkNode.SetAttribute("minSdkVersion", $nsUri, $MinSdk)
            Write-Host "-> Manifest: Updated minSdkVersion to $MinSdk"
            $modified = $true
        }
        if ($hasTarget) {
            if ($TargetSdk -eq "null") {
                if ($usesSdkNode.HasAttribute("targetSdkVersion", $nsUri)) {
                    $usesSdkNode.RemoveAttribute("targetSdkVersion", $nsUri)
                    Write-Host "-> Manifest: Removed targetSdkVersion attribute"
                    $modified = $true
                }
            } else {
                $usesSdkNode.SetAttribute("targetSdkVersion", $nsUri, $TargetSdk)
                Write-Host "-> Manifest: Updated targetSdkVersion to $TargetSdk"
                $modified = $true
            }
        }
        if ($hasMax) {
            if ($MaxSdk -eq "null") {
                if ($usesSdkNode.HasAttribute("maxSdkVersion", $nsUri)) {
                    $usesSdkNode.RemoveAttribute("maxSdkVersion", $nsUri)
                    Write-Host "-> Manifest: Removed maxSdkVersion attribute"
                    $modified = $true
                }
            } else {
                $usesSdkNode.SetAttribute("maxSdkVersion", $nsUri, $MaxSdk)
                Write-Host "-> Manifest: Updated maxSdkVersion to $MaxSdk"
                $modified = $true
            }
        }
    }

    if ($modified) {
        $xml.Save($ManifestPath)
    }
}

function Update-ApktoolYml([string]$YmlPath, [string]$NewPackage, [string]$VersionCode, [string]$VersionName, [string]$MinSdk, [string]$TargetSdk, [string]$MaxSdk) {
    $text = Get-Content -LiteralPath $YmlPath -Raw -Encoding UTF8

    if (-not [string]::IsNullOrWhiteSpace($NewPackage) -and ($NewPackage -ne "null")) {
        if ($text -match '(?m)^renameManifestPackage:\s*') {
            $text = $text -replace '(?m)^renameManifestPackage:.*$', "renameManifestPackage: $NewPackage"
        } else {
            $text = $text.TrimEnd() + "`nrenameManifestPackage: $NewPackage`n"
        }
        $text = $text -replace '(?m)^(  packageName:)\s*$', "`$1 $NewPackage"
        Write-Host "-> apktool.yml: Updated package name to $NewPackage"
    }

    if (-not [string]::IsNullOrWhiteSpace($VersionCode) -and ($VersionCode -ne "null")) {
        if ($text -match '(?m)^  versionCode:\s*.*$') {
            $text = $text -replace '(?m)^  versionCode:\s*.*$', "  versionCode: $VersionCode"
            Write-Host "-> apktool.yml: Updated versionCode to $VersionCode"
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($VersionName) -and ($VersionName -ne "null")) {
        if ($text -match '(?m)^  versionName:\s*.*$') {
            $text = $text -replace '(?m)^  versionName:\s*.*$', "  versionName: $VersionName"
            Write-Host "-> apktool.yml: Updated versionName to $VersionName"
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($MinSdk) -and ($MinSdk -ne "null")) {
        if ($text -match '(?m)^    minSdkVersion:\s*.*$') {
            $text = $text -replace '(?m)^    minSdkVersion:\s*.*$', "    minSdkVersion: $MinSdk"
            Write-Host "-> apktool.yml: Updated minSdkVersion to $MinSdk"
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($TargetSdk)) {
        $targetVal = if ($TargetSdk -eq "null") { "null" } else { $TargetSdk }
        if ($text -match '(?m)^    targetSdkVersion:\s*.*$') {
            $text = $text -replace '(?m)^    targetSdkVersion:\s*.*$', "    targetSdkVersion: $targetVal"
            Write-Host "-> apktool.yml: Updated targetSdkVersion to $targetVal"
        } else {
            if ($text -match '(?m)^  sdkInfo:\s*$') {
                $text = $text -replace '(?m)^  sdkInfo:\s*$', "  sdkInfo:`n    targetSdkVersion: $targetVal"
                Write-Host "-> apktool.yml: Added and Updated targetSdkVersion to $targetVal"
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($MaxSdk)) {
        $val = if ($MaxSdk -eq "null") { "null" } else { $MaxSdk }
        if ($text -match '(?m)^    maxSdkVersion:\s*.*$') {
            $text = $text -replace '(?m)^    maxSdkVersion:\s*.*$', "    maxSdkVersion: $val"
            Write-Host "-> apktool.yml: Updated maxSdkVersion to $val"
        } else {
            if ($text -match '(?m)^  sdkInfo:\s*$') {
                $text = $text -replace '(?m)^  sdkInfo:\s*$', "  sdkInfo:`n    maxSdkVersion: $val"
                Write-Host "-> apktool.yml: Added and Updated maxSdkVersion to $val"
            }
        }
    }

    Set-Content -LiteralPath $YmlPath -Value $text -Encoding UTF8 -NoNewline
}

function Replace-InTree([string]$Root, [string]$OldPackage, [string]$NewPackage) {
    $oldSmali = "L" + $OldPackage.Replace(".", "/")
    $newSmali = "L" + $NewPackage.Replace(".", "/")
    $changed = 0

    Get-ChildItem -LiteralPath $Root -Recurse -File | ForEach-Object {
        $allowedSuffix = @(".smali", ".xml", ".txt", ".json", ".properties")
        if (($allowedSuffix -notcontains $_.Extension) -and ($_.Name -ne "AndroidManifest.xml")) {
            return
        }
        $text = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
        $updated = $text.Replace($oldSmali, $newSmali).Replace($OldPackage, $NewPackage)
        if ($updated -ne $text) {
            Set-Content -LiteralPath $_.FullName -Value $updated -Encoding UTF8 -NoNewline
            $script:changed += 1
        }
    }
    return $changed
}

function Move-SmaliPackageDirs([string]$DecodedDir, [string]$OldPackage, [string]$NewPackage) {
    $oldRel = $OldPackage.Replace(".", "\")
    $newRel = $NewPackage.Replace(".", "\")
    $moves = 0

    Get-ChildItem -LiteralPath $DecodedDir -Directory -Filter "smali*" | ForEach-Object {
        $oldDir = Join-Path $_.FullName $oldRel
        $newDir = Join-Path $_.FullName $newRel
        if (Test-Path -LiteralPath $oldDir -PathType Container) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $newDir) | Out-Null
            if (Test-Path -LiteralPath $newDir) {
                Remove-Item -LiteralPath $newDir -Recurse -Force
            }
            Move-Item -LiteralPath $oldDir -Destination $newDir
            $script:moves += 1
        }
    }
    return $moves
}

if (-not [string]::IsNullOrWhiteSpace($NewPackage) -and ($NewPackage -ne "null")) {
    if ($NewPackage -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$') {
        throw "Invalid package name: $NewPackage"
    }
}

$fields = @(@{N="VersionCode";V=$VersionCode}, @{N="MinSdk";V=$MinSdk}, @{N="TargetSdk";V=$TargetSdk})
foreach ($f in $fields) {
    if (-not [string]::IsNullOrWhiteSpace($f.V) -and ($f.V -ne "null")) {
        if ($f.V -notmatch '^[0-9]+$') {
            throw "[ERROR] $($f.N) must be a valid number! (Input: '$($f.V)')"
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($MaxSdk) -and $MaxSdk -ne "null") {
    if ($MaxSdk -notmatch '^[0-9]+$') {
        throw "[ERROR] MaxSdk must be a valid number or 'null'! (Input: '$MaxSdk')"
    }
}

if ([string]::IsNullOrWhiteSpace($InputApk)) {
    throw "[ERROR] Input APK path is empty."
}
$inputPath = Get-FullPathSafe $InputApk
if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
    throw "Input APK not found: $inputPath"
}

if ([string]::IsNullOrWhiteSpace($OutputApk)) {
    throw "[ERROR] Output APK path is empty."
}

# 디렉토리 경로가 없으면(파일명만 입력된 경우) input apk와 동일한 디렉토리를 기본 경로로 사용한다.
$outDir = Split-Path -Path $OutputApk -Parent
if ([string]::IsNullOrWhiteSpace($outDir)) {
    $outputPath = Join-Path (Split-Path -Parent $inputPath) $OutputApk
} else {
    $outputPath = Get-FullPathSafe $OutputApk
}

# 확장자가 .apk가 아니면(미지정 포함) .apk로 강제 적용한다.
if ($outputPath -match '\.[^\.\\/]+$') {
    if ($matches[0] -ne ".apk") {
        $outputPath = $outputPath -replace '\.[^\.\\/]+$', '.apk'
    }
} else {
    $outputPath = $outputPath + ".apk"
}

$java = Resolve-ToolPath "tools\java\bin\java.exe"
if ([string]::IsNullOrWhiteSpace($java) -or -not (Test-Path -LiteralPath $java -PathType Leaf)) {
    $java = "java"
}

$javaArgs = @("-Xmx3g", "-jar")

$apktoolJar = Resolve-ToolPath "tools\apktool\apktool.jar"
$apksignerJar = Resolve-ToolPath "tools\build-tools\lib\apksigner.jar"
$zipalign = Resolve-ToolPath "tools\build-tools\zipalign.exe"

# 서명 키 결정: keystore.config가 존재하고 값이 채워져 있으면 해당 키 사용, 아니면 기본 debug 키로 폴백
$keystoreConfigPath = Resolve-ToolPath "tools\keystore\keystore.config"
$keystore = $null
$keyAlias = $null
$storePass = $null
$keyPass = $null

if (-not [string]::IsNullOrWhiteSpace($keystoreConfigPath) -and (Test-Path -LiteralPath $keystoreConfigPath -PathType Leaf)) {
    $configValues = @{}
    Get-Content -LiteralPath $keystoreConfigPath -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) { return }
        $idx = $line.IndexOf("=")
        if ($idx -gt 0) {
            $key = $line.Substring(0, $idx).Trim()
            $val = $line.Substring($idx + 1).Trim()
            $configValues[$key] = $val
        }
    }

    $cfgKeystorePath = $configValues["KeystorePath"]
    $cfgKeyAlias = $configValues["KeyAlias"]
    $cfgStorePass = $configValues["StorePassword"]
    $cfgKeyPass = $configValues["KeyPassword"]

    $configComplete = (-not [string]::IsNullOrWhiteSpace($cfgKeystorePath)) -and
                       (-not [string]::IsNullOrWhiteSpace($cfgKeyAlias)) -and
                       (-not [string]::IsNullOrWhiteSpace($cfgStorePass)) -and
                       (-not [string]::IsNullOrWhiteSpace($cfgKeyPass))

    if ($configComplete) {
        if (Split-Path -Path $cfgKeystorePath -IsAbsolute) {
            $keystore = $cfgKeystorePath
        } else {
            $keystore = Join-Path (Split-Path -Parent $keystoreConfigPath) $cfgKeystorePath
        }
        $keyAlias = $cfgKeyAlias
        $storePass = $cfgStorePass
        $keyPass = $cfgKeyPass

        if (-not (Test-Path -LiteralPath $keystore -PathType Leaf)) {
            throw "keystore.config에 지정된 키 파일을 찾을 수 없습니다: $keystore"
        }
        Write-Host "-> Signing: keystore.config에 등록된 서명 키를 사용합니다. (alias=$keyAlias)"
    } else {
        Write-Host "-> [WARNING] keystore.config가 존재하지만 필수 값이 비어 있어 기본 debug 키로 폴백합니다."
    }
} else {
    Write-Host "-> [WARNING] keystore.config가 없어 기본 debug 키로 서명합니다. 스토어 업로드용 APK에는 사용할 수 없습니다."
}

if ($null -eq $keystore) {
    $keystore = Resolve-ToolPath "tools\keystore\debug.keystore"
    $keyAlias = "androiddebugkey"
    $storePass = "android"
    $keyPass = "android"
}

foreach ($required in @($apktoolJar, $apksignerJar, $zipalign, $keystore)) {
    if ([string]::IsNullOrWhiteSpace($required)) {
        throw "Required bundled path is null or empty. Check if tool directories exist."
    }
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required bundled file not found: $required"
    }
}

if ([string]::IsNullOrWhiteSpace($WorkDir)) {
    $workRoot = Join-Path $env:TEMP ("repack_apk_" + [System.Guid]::NewGuid().ToString("N"))
} else {
    $workRoot = Get-FullPathSafe $WorkDir
}

$decodedDir = Join-Path $workRoot "decoded"
$unsignedApk = Join-Path $workRoot "unsigned.apk"
$alignedApk = Join-Path $workRoot "aligned.apk"

try {
    if (Test-Path -LiteralPath $decodedDir) {
        Remove-Item -LiteralPath $decodedDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $workRoot | Out-Null

    Invoke-Checked @($java, $javaArgs[0], $javaArgs[1], $apktoolJar, "d", "-f", $inputPath, "-o", $decodedDir)

    $manifestPath = Join-Path $decodedDir "AndroidManifest.xml"
    $ymlPath = Join-Path $decodedDir "apktool.yml"
    $oldPackage = Read-OldPackage $manifestPath

    Write-Host "Old package: $oldPackage"

    if ([string]::IsNullOrWhiteSpace($NewPackage) -or ($NewPackage -eq "null")) {
        $NewPackage = $oldPackage
        Write-Host "New package: (Not specified. Keeping original package)"
    } else {
        Write-Host "New package: $NewPackage"
    }

    Update-ManifestPackage $manifestPath $oldPackage $NewPackage
    Update-ManifestMetadata $manifestPath $VersionCode $VersionName $MinSdk $TargetSdk $MaxSdk
    Update-ApktoolYml $ymlPath $NewPackage $VersionCode $VersionName $MinSdk $TargetSdk $MaxSdk

    if ($FullSmali -and ($oldPackage -ne $NewPackage)) {
        $script:moves = 0
        $script:changed = 0
        Move-SmaliPackageDirs $decodedDir $oldPackage $NewPackage | Out-Null
        Replace-InTree $decodedDir $oldPackage $NewPackage | Out-Null
        Write-Host "Moved smali dirs: $script:moves, updated files: $script:changed"
    } else {
        if ($FullSmali) {
            Write-Host "FullSmali skipped: Package name has not changed."
        } else {
            Write-Host "Manifest-only mode (add -FullSmali for smali tree rename)"
        }
    }

    if (Test-Path -LiteralPath $unsignedApk) {
        Remove-Item -LiteralPath $unsignedApk -Force
    }

    Invoke-Checked @($java, $javaArgs[0], $javaArgs[1], $apktoolJar, "b", $decodedDir, "-o", $unsignedApk)

    if (Test-Path -LiteralPath $alignedApk) {
        Remove-Item -LiteralPath $alignedApk -Force
    }
    Invoke-Checked @($zipalign, "-f", "4", $unsignedApk, $alignedApk)

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outputPath) | Out-Null
    if (Test-Path -LiteralPath $outputPath) {
        Remove-Item -LiteralPath $outputPath -Force
    }
    Copy-Item -LiteralPath $alignedApk -Destination $outputPath

    Invoke-Checked @(
        $java, $javaArgs[0], $javaArgs[1], $apksignerJar, "sign",
        "--v2-signing-enabled", "true",
        "--v3-signing-enabled", "true",
        "--ks", $keystore,
        "--ks-pass", "pass:$storePass",
        "--key-pass", "pass:$keyPass",
        "--ks-key-alias", $keyAlias,
        $outputPath
    ) -MaskValues @("pass:$storePass", "pass:$keyPass")

    Invoke-Checked @($java, $javaArgs[0], $javaArgs[1], $apksignerJar, "verify", "--verbose", $outputPath)

    Write-Host "Done: $outputPath"
    if ($KeepTemp) {
        Write-Host "Temp kept: $workRoot"
    }
} finally {
    if ([string]::IsNullOrWhiteSpace($WorkDir) -and (Test-Path -LiteralPath $workRoot)) {
        cmd /c "rmdir /s /q `"$workRoot`"" 2>$null
    }
}