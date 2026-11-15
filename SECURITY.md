# Security policy

## Supported versions

Security fixes are provided for the current **1.x** release line.

## Reporting a vulnerability

Please do **not** open a public issue for a security problem. Use GitHub's private
vulnerability reporting:

<https://github.com/MuratovMikhail/dsh-widget/security/advisories/new>

Include:

- the affected version (About window or `config.json`);
- Windows version;
- steps to reproduce;
- impact and any proof of concept, with personal data removed.

## Scope

DSH Widget runs locally on Windows. It:

- reads DSH session journals from `%USERPROFILE%\.dsh` (or `DSH_HOME`);
- optionally asks `platform.deepseek.com` for the account balance;
- starts a local HTTP engine on `127.0.0.1`;
- stores settings in `config.json` next to the app.

The engine checks `Origin`/`Host` and is intended for loopback use only. It does not
provide an authentication token in 1.0.0, so other processes on the same Windows
account can query it. This is a known limitation, not a remote vulnerability.

## API keys and logs

A custom DeepSeek API key is stored in plain text in `config.json`, as are the other
settings. Do not commit or share `config.json`, `widget.log`, or session journals.
The release archive is scanned before publication, but the installed folder is your
own data.

## Installer

The 1.0.4 installer is **not code-signed**. Windows SmartScreen may show
"Unknown publisher". Verify the SHA-256 checksum published with the GitHub release
before running it.

## No telemetry

The widget has no telemetry, analytics, crash upload, or background network
connection except the optional balance request described above.
