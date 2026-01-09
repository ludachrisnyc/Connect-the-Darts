<#
Ready-to-run PowerShell script to install Android emulator components,
create an AVD and start it. Intended for Windows.

Usage (run in PowerShell as Administrator if required):

    .\scripts\setup-emulator.ps1 -AvdName my_avd -ApiLevel 33 -ImageVariant "google_apis;x86_64"

It will try to auto-detect the SDK path from `local.properties` or environment variables.
#>

param(
    [string]$AvdName = 'my_avd',
    [int]$ApiLevel = 33,
    [string]$ImageVariant = 'google_apis;x86_64',
    [switch]$StartEmulator = $true,
    [string]$CmdlineToolsZip = '',
    [switch]$AutoSetJava = $true
)

function Get-ProjectSdkDir {
    $projRoot = (Get-Location).Path
    $localProps = Join-Path $projRoot 'local.properties'
    if (Test-Path $localProps) {
        $content = Get-Content $localProps -ErrorAction SilentlyContinue
        foreach ($line in $content) {
            if ($line -match '^sdk\.dir=(.+)$') {
                $raw = $Matches[1].Trim()
                $raw = $raw -replace '\\:', ':'
                return [string]$raw
            }
        }
    }
    if ($Env:ANDROID_SDK_ROOT) { return $Env:ANDROID_SDK_ROOT }
    if ($Env:ANDROID_HOME) { return $Env:ANDROID_HOME }
    return $null
}

function Find-Tool($sdkRoot, $toolName) {
    # Build candidate paths as plain strings to avoid passing arrays to Join-Path
    $candidates = @(
        "$sdkRoot\cmdline-tools\latest\bin\$toolName",
        "$sdkRoot\cmdline-tools\bin\$toolName",
        "$sdkRoot\tools\bin\$toolName",
        "$sdkRoot\tools\$toolName",
        "$sdkRoot\$toolName"
    )
    foreach ($c in $candidates) {
        if (Test-Path "${c}.exe") { return "${c}.exe" }
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Ensure-CmdlineTools($sdkRoot, $zipPath) {
    $sdkmanager = Find-Tool $sdkRoot 'sdkmanager'
    if ($sdkmanager) { return $true }

    if ($zipPath -and (Test-Path $zipPath)) {
        Write-Host "Using local cmdline-tools zip: $zipPath"
        $zip = $zipPath
    } else {
        Write-Host "Command-line tools not found under $sdkRoot. Downloading..."
        $zipUrl = 'https://dl.google.com/android/repository/commandlinetools-win-latest.zip'
        $zip = Join-Path $env:TEMP 'cmdline-tools.zip'
        try {
            Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing -ErrorAction Stop
        } catch {
            Write-Host "Failed to download command-line tools: $_" -ForegroundColor Red
            return $false
        }
    }

    $tmp = Join-Path $env:TEMP 'cmdline-tools-tmp'
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    try {
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
    } catch {
        Write-Host "Failed to extract cmdline-tools zip: $_" -ForegroundColor Red
        return $false
    }

    $src = Join-Path $tmp 'cmdline-tools'
    $destParent = Join-Path $sdkRoot 'cmdline-tools'
    New-Item -ItemType Directory -Force -Path $destParent | Out-Null
    $dest = Join-Path $destParent 'latest'

    # If extracted already has a nested folder, move appropriately
    if (Test-Path $src) {
        Remove-Item -Recurse -Force $dest -ErrorAction SilentlyContinue
        Move-Item -Force $src $dest
    } else {
        # Some archives may extract a tools folder - try to move first container
        $entries = Get-ChildItem $tmp | Where-Object { $_.PSIsContainer }
        if ($entries.Count -gt 0) {
            Remove-Item -Recurse -Force $dest -ErrorAction SilentlyContinue
            Move-Item -Force $entries[0].FullName $dest
        } else {
            Write-Host "No cmdline-tools folder found inside the archive." -ForegroundColor Red
            return $false
        }
    }

    if ($zipPath -ne $null -and (Test-Path $zipPath)) {
        # don't delete user-provided zip
    } else {
        Remove-Item -Recurse -Force $tmp, $zip -ErrorAction SilentlyContinue
    }

    $sdkmanager = Find-Tool $sdkRoot 'sdkmanager'
    return [bool]$sdkmanager
}

# Try to ensure JAVA_HOME is valid or auto-detect a JDK under common locations.
function Ensure-Java($autoFix) {
    if ($env:JAVA_HOME) {
        if (Test-Path (Join-Path $env:JAVA_HOME 'bin\java.exe')) { return $true }
    }

    # Search common install locations for JDKs
    $candidates = @('C:\Program Files\Java','C:\Program Files (x86)\Java')
    $found = @()
    foreach ($c in $candidates) {
        if (Test-Path $c) {
            $dirs = Get-ChildItem -Directory -Path $c -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
            $found += $dirs
        }
    }
    if ($found.Count -gt 0) {
        # prefer highest version by sorting names descending
        $jdk = ($found | Sort-Object -Descending)[0]
        if (Test-Path (Join-Path $jdk 'bin\java.exe')) {
            [Environment]::SetEnvironmentVariable('JAVA_HOME',$jdk,'User')
            $env:JAVA_HOME = $jdk
            # prepend to current session PATH
            $env:PATH = (Join-Path $jdk 'bin') + ';' + $env:PATH
            # ensure user PATH contains it
            $current = [Environment]::GetEnvironmentVariable('Path','User')
            if ($current -notlike "*$($jdk)\bin*") {
                [Environment]::SetEnvironmentVariable('Path', "$current;$jdk\bin",'User')
            }
            Write-Host "JAVA_HOME set to $jdk"
            return $true
        }
    }

    if ($autoFix) {
        Write-Host "No JDK found under common locations. Please install a JDK (Temurin/OpenJDK 17+) and re-run the script." -ForegroundColor Yellow
    }
    return $false
}

function Install-Packages($sdkRoot, $packages) {
    $sdkmanager = Find-Tool $sdkRoot 'sdkmanager'
    if (-not $sdkmanager) {
        Write-Host "sdkmanager not found; attempting to install command-line tools..."
        if (-not (Ensure-CmdlineTools $sdkRoot)) { throw "sdkmanager not found under $sdkRoot. Install Android SDK Command-line Tools." }
        $sdkmanager = Find-Tool $sdkRoot 'sdkmanager'
    }

    Write-Host "Installing packages: $($packages -join ', ')"
    $args = @("--sdk_root=$sdkRoot") + $packages + '--verbose'
    & "$sdkmanager" $args
    if ($LASTEXITCODE -ne 0) { throw "sdkmanager failed with exit code $LASTEXITCODE" }
}

function Create-Avd($sdkRoot, $avdName, $apiLevel, $imageVariant) {
    $avdmanager = Find-Tool $sdkRoot 'avdmanager'
    if (-not $avdmanager) { throw "avdmanager not found under $sdkRoot." }

    $package = "system-images;android-$apiLevel;$imageVariant"
    Write-Host "Creating AVD '$avdName' with package $package"

    # Accept and create if not existing
    $avdList = & "$avdmanager" list avd 2>&1
    if ($avdList -match "Name: $avdName") {
        Write-Host "AVD '$avdName' already exists. Skipping creation."
        return
    }

    # Determine a device (use pixel if available)
    $device = 'pixel'

    & "$avdmanager" create avd -n $avdName -k $package --device $device --force
    if ($LASTEXITCODE -ne 0) { throw "avdmanager create failed with exit code $LASTEXITCODE" }
}

function Start-Emulator($sdkRoot, $avdName) {
    $emulator = Join-Path $sdkRoot 'emulator\emulator.exe'
    if (-not (Test-Path $emulator)) { throw "emulator binary not found under $sdkRoot\emulator" }

    Write-Host "Starting emulator: $avdName"
    Start-Process -FilePath $emulator -ArgumentList "-avd `"$avdName`" -netdelay none -netspeed full" -NoNewWindow

    # Wait for device to appear
    $adb = Join-Path $sdkRoot 'platform-tools\adb.exe'
    if (-not (Test-Path $adb)) { Write-Host "Warning: adb not found; skipping device wait check."; return }

    Write-Host "Waiting for emulator to show in 'adb devices' (this may take 30-120s)"
    for ($i=0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 3
        $out = & "$adb" devices
        if ($out -match 'emulator-') {
            Write-Host "Emulator is running."
            return
        }
    }
    Write-Host "Timed out waiting for emulator to appear in adb devices."
}

try {
    $sdkRoot = Get-ProjectSdkDir
    if (-not $sdkRoot) { throw "Android SDK path not found. Set ANDROID_SDK_ROOT or add sdk.dir in local.properties." }
    Write-Host "Using SDK path: $sdkRoot"

    $packages = @('platform-tools','emulator', "platforms;android-$ApiLevel", "system-images;android-$ApiLevel;$ImageVariant")
    Install-Packages -sdkRoot $sdkRoot -packages $packages

    Create-Avd -sdkRoot $sdkRoot -avdName $AvdName -apiLevel $ApiLevel -imageVariant $ImageVariant

    if ($StartEmulator) { Start-Emulator -sdkRoot $sdkRoot -avdName $AvdName }

    Write-Host "All done. Use adb to verify: $sdkRoot\platform-tools\adb.exe devices"
    Write-Host "To start the emulator later: $sdkRoot\emulator\emulator.exe -avd $AvdName"
} catch {
    Write-Host "Error: $_" -ForegroundColor Red
    exit 1
}
