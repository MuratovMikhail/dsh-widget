# Code signing policy

Free code signing provided by [SignPath.io](https://about.signpath.io),
certificate by [SignPath Foundation](https://signpath.org).

## What is signed

`DSHWidget-Setup-*.exe` — the Windows installer attached to GitHub Releases.
It is built by [.github/workflows/release.yml](.github/workflows/release.yml)
from a tagged commit in this repository. The portable `dsh-widget-1.0.zip`
contains PowerShell and JavaScript files and is not Authenticode-signed.

No upstream binaries are signed with this project's certificate.

## Team roles

| Role | Member |
|---|---|
| Authors / committers | Mikhail Muratov ([@MuratovMikhail](https://github.com/MuratovMikhail)) |
| Reviewers | Mikhail Muratov ([@MuratovMikhail](https://github.com/MuratovMikhail)) |
| Approvers | Mikhail Muratov ([@MuratovMikhail](https://github.com/MuratovMikhail)) |

Every pull request is reviewed before merging into `main`. Every signing
request is approved manually by the approver.

## Build and release

- A `v*` tag triggers [.github/workflows/release.yml](.github/workflows/release.yml).
- The workflow runs the engine tests, builds `dsh-widget-1.0.zip`,
  `DSHWidget-Setup-1.0.0.exe`, and `SHA256SUMS.txt`.
- The installer is submitted to SignPath for Authenticode signing.
- A release is published only after the signed installer is returned.

## Privacy

See [PRIVACY.md](PRIVACY.md).

## Third-party components

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). All source code is
MIT-licensed; the only non-code asset under a separate license is the
notification sound, which is a Pixabay media asset.

## Security reports

Please use GitHub's private vulnerability reporting:
<https://github.com/MuratovMikhail/dsh-widget/security/advisories/new>
