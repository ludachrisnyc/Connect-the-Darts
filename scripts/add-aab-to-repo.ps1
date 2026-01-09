<#
Copy the built AAB into a project `releases/` folder and optionally git-commit it.

Usage (run from any PowerShell prompt):
  .\scripts\add-aab-to-repo.ps1
  .\scripts\add-aab-to-repo.ps1 -ProjectRoot 'C:\path\to\project' -Source 'build\app\outputs\bundle\release\app-release.aab' -Commit

Parameters:
  -ProjectRoot : Project root folder (defaults to current working directory)
  -Source      : Relative path to AAB inside project (defaults to build/app/outputs/bundle/release/app-release.aab)
  -DestDir     : Destination folder name under project (defaults to releases)
  -Commit      : If provided, runs `git add` and `git commit` (and tries to `git push`)
#>

param(
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$Source = 'build\app\outputs\bundle\release\app-release.aab',
    [string]$DestDir = 'releases',
    [switch]$Commit = $false
)

try {
    $proj = Resolve-Path -Path $ProjectRoot
    $projPath = $proj.Path
} catch {
    Write-Error "Project root not found: $ProjectRoot"
    exit 1
}

function Find-Aab($projPath, $sourceRel) {
    $candidates = @()
    # explicit provided relative path
    if ($sourceRel) { $candidates += (Join-Path $projPath $sourceRel) }
    # common Flutter path
    $candidates += (Join-Path $projPath 'build\app\outputs\bundle\release\app-release.aab')
    # common Android native path
    $candidates += (Join-Path $projPath 'app\build\outputs\bundle\release\app-release.aab')

    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }

    # fallback: search for any .aab in project
    $found = Get-ChildItem -Path $projPath -Filter '*.aab' -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    if ($found -and $found.Count -gt 0) { return $found[0].FullName }
    return $null
}

$src = Find-Aab $projPath $Source
if (-not $src) {
    Write-Error "AAB not found in project. Looked in common locations and the project tree."
    Write-Host "You can build the appbundle with: ./gradlew.bat bundleRelease (or 'flutter build appbundle') from project root"
    exit 1
}

$destRoot = Join-Path $projPath $DestDir
if (-not (Test-Path $destRoot)) { New-Item -ItemType Directory -Force -Path $destRoot | Out-Null }

$ts = Get-Date -Format yyyyMMdd_HHmmss
$destName = "app-release-$ts.aab"
$dest = Join-Path $destRoot $destName

Copy-Item -Path $src -Destination $dest -Force
Write-Host "Copied AAB to: $dest"

if ($Commit) {
    # Ensure we're inside a git repo
    Push-Location $projPath
    $isGit = & git rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Not a git repository. Skipping commit.' -ForegroundColor Yellow
        Pop-Location
        exit 0
    }

    & git add (Join-Path $DestDir $destName)
    if ($LASTEXITCODE -ne 0) { Write-Host 'git add failed' -ForegroundColor Yellow }
    else {
        & git commit -m "Add release AAB: $destName"
        if ($LASTEXITCODE -ne 0) { Write-Host 'git commit failed or nothing to commit' -ForegroundColor Yellow }
        else {
            Write-Host 'Committed AAB to git. Attempting push...'
            & git push
            if ($LASTEXITCODE -ne 0) { Write-Host 'git push failed; check remote and credentials' -ForegroundColor Yellow }
        }
    }
    Pop-Location
}

Write-Host 'Done.'
