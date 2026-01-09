<#
Initialize a git repository in the project root, create a .gitignore,
make an initial commit and optionally add a remote and push.

Usage:
  .\scripts\init-repo.ps1
  .\scripts\init-repo.ps1 -UserName 'Your Name' -UserEmail 'you@example.com' -CommitMessage 'Initial commit' -RemoteUrl 'git@github.com:you/repo.git'
#>

param(
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$UserName = '',
    [string]$UserEmail = '',
    [string]$CommitMessage = 'Initial commit',
    [string]$Files = '.',
    [string]$RemoteUrl = ''
)

try {
    Write-Host "Initializing git repo at: $ProjectRoot"
    Push-Location $ProjectRoot

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Error 'git is not installed or not on PATH. Install Git for Windows first.'
        Pop-Location
        exit 1
    }

    $isRepo = Test-Path (Join-Path $ProjectRoot '.git')
    if (-not $isRepo) {
        git init
        Write-Host 'Repository initialized.'
    } else {
        Write-Host 'Already a git repository.'
    }

    if ($UserName) { git config user.name "$UserName" }
    if ($UserEmail) { git config user.email "$UserEmail" }

    # Create a sensible .gitignore if not present
    $gitignore = Join-Path $ProjectRoot '.gitignore'
    if (-not (Test-Path $gitignore)) {
        $ignoreLines = @(
            '# Flutter / Android',
            './.gradle',
            './.idea',
            './.vscode',
            './local.properties',
            '**/build/',
            '*.iml',
            '.gradle',
            '.DS_Store',
            '# Keystore',
            '*.jks',
            '# Android Studio caches',
            '.cxx',
            '# VS Code',
            '.vscode/',
            '# Mac',
            '*.DS_Store',
            '# Do not ignore releases (we keep release artifacts)'
        )
        $ignoreLines | Out-File -FilePath $gitignore -Encoding UTF8 -Force
        Write-Host 'Created .gitignore'
    } else {
        Write-Host '.gitignore already exists; leaving it unchanged.'
    }

    # Add files and commit
    git add $Files
    $status = git status --porcelain
    if ($status) {
        git commit -m "$CommitMessage"
        Write-Host 'Initial commit created.'
    } else {
        Write-Host 'No changes to commit.'
    }

    if ($RemoteUrl) {
        # Add remote and push to main
        git remote add origin $RemoteUrl 2>$null
        git branch -M main
        Write-Host "Pushing to remote $RemoteUrl (branch main)..."
        git push -u origin main
    }

    Pop-Location
    Write-Host 'Done.'
} catch {
    Write-Error "Error: $_"
    Pop-Location -ErrorAction SilentlyContinue
    exit 1
}
