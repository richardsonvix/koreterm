#Requires -Version 7.0
<#
.SYNOPSIS
Builds koreterm <Version>, makes its update.zip and publishes both, with the
installer and the portable ZIP, as a GitHub release of richardsonvix/koreterm.

.DESCRIPTION
A running koreterm looks at the latest release once per launch
(src/apprt/win32/site_update.zig). When the release is newer, koreterm
downloads its update.zip and update.zip.sha256 beside koreterm.exe and offers
the update, as it offers an update.zip copied there by hand.

Steps:
1. scripts\package-windows.ps1 -Version <Version> (in the VS dev + Zig
   shell, through scripts\dev-windows.cmd), unless -SkipPackage.
2. scripts\make-update-zip.ps1 with the <Version> section of
   dist\whats-new.txt as the dialog's notes.
3. update.zip.sha256, then `gh release create v<Version>` at this commit.

The commit has to be on origin already, since the release tag points at it.
-Push pushes the current branch first. -Draft makes a draft release, which
koreterm does not see until it is published on GitHub.

Example:
  pwsh scripts\publish-update.ps1 -Version 1.3.147 -Push
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [switch]$SkipPackage,
    [switch]$Push,
    [switch]$Draft
)

$ErrorActionPreference = "Stop"
$repo = "richardsonvix/koreterm"
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Version must be major.minor.patch, like 1.3.147." }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "GitHub CLI (gh) was not found." }
gh auth status --hostname github.com *> $null
if ($LASTEXITCODE -ne 0) { throw "gh is not signed in: run 'gh auth login'." }

$tag = "v$Version"
gh release view $tag --repo $repo *> $null
if ($LASTEXITCODE -eq 0) { throw "Release $tag already exists on $repo." }

# The tag points at this commit, which GitHub must have.
$commit = (git rev-parse HEAD).Trim()
if ($Push) {
    $branch = (git rev-parse --abbrev-ref HEAD).Trim()
    git push origin $branch
    if ($LASTEXITCODE -ne 0) { throw "git push failed." }
}
git fetch origin --quiet
$onRemote = git branch -r --contains $commit
if (-not $onRemote) { throw "Commit $commit is not on origin yet: push it, or run again with -Push." }

# What's new in this version: its section at the top of dist\whats-new.txt.
$notesPath = Join-Path $repoRoot "dist\whats-new.txt"
$allNotes = Get-Content -LiteralPath $notesPath -Raw
$pattern = "(?ms)^koreterm $([regex]::Escape($Version))\s*\r?\n(.*?)(?=^koreterm \d+\.\d+\.\d+\s*$|\z)"
$match = [regex]::Match($allNotes, $pattern)
if (-not $match.Success) { throw "dist\whats-new.txt has no 'koreterm $Version' section." }
$notes = "koreterm $Version`n`n" + $match.Groups[1].Value.Trim()
$notesFile = Join-Path ([System.IO.Path]::GetTempPath()) "koreterm-$Version-notes.txt"
Set-Content -LiteralPath $notesFile -Value $notes -Encoding utf8NoBOM

if (-not $SkipPackage) {
    & cmd /c "scripts\dev-windows.cmd pwsh -NoProfile -File scripts\package-windows.ps1 -Version $Version"
    if ($LASTEXITCODE -ne 0) { throw "Packaging failed." }
}
& pwsh -NoProfile -File (Join-Path $PSScriptRoot "make-update-zip.ps1") -Version $Version -NotesFile $notesFile
if ($LASTEXITCODE -ne 0) { throw "make-update-zip.ps1 failed." }

$stage = Join-Path $repoRoot "dist\artifacts\koreterm-$Version-windows-x64"
$zip = Join-Path $stage "update.zip"
$sha = Join-Path $stage "update.zip.sha256"
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath $sha -Value "$hash  update.zip" -Encoding ascii -NoNewline

$assets = @($zip, $sha)
$setup = Join-Path $stage "koreterm-$Version-windows-x64-setup.exe"
if (Test-Path -LiteralPath $setup) { $assets += $setup } else { Write-Warning "No installer at $setup (ISCC.exe missing?): the release has none." }
$portable = Join-Path $stage "koreterm-$Version-windows-x64-portable.zip"
if (Test-Path -LiteralPath $portable) { $assets += $portable }

$create = @("release", "create", $tag) + $assets + @("--repo", $repo, "--target", $commit, "--title", "koreterm $Version", "--notes-file", $notesFile)
if ($Draft) { $create += "--draft" }
& gh @create
if ($LASTEXITCODE -ne 0) { throw "gh release create failed." }
Remove-Item -LiteralPath $notesFile -Force -ErrorAction SilentlyContinue
Write-Host "Published $tag on https://github.com/$repo/releases/tag/$tag"
