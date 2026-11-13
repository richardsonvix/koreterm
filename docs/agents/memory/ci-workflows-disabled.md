---
name: ci-workflows-disabled
description: The fork's GitHub Actions CI was disabled and then deleted on 2026-11-13 at the user's request
metadata:
  type: project
---

On 2026-11-13 the user asked to remove the fork's CI because it kept failing on pushes to main (Test, Windows ARM64, Windows CLI Forwarder, ConPTY Sync). The 9 workflows were first disabled on GitHub (`gh workflow disable`), then deleted from the repo with `.github/workflows/`, `.github/actions/`, `.github/dependabot.yml` and `.github/pinact.yml`.

**Why:** the CI inherited from upstream fails on this fork and only produced error emails.

**How to apply:** there is no CI; verification is local builds and tests. Scripts that read workflow files (`test/windows/ci-scripts.ps1`, flagship `Contracts.80-Release.ps1` and `Contracts.94-Windows10.ps1`) now fail if run; that's expected, don't "fix" them by restoring workflows. See [[only-own-repo]].
