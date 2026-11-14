# Privacy policy

DSH Widget is a local Windows desktop widget. It does not collect telemetry,
analytics, or crash reports, and it does not sell or share user data.

## Local data

- Reads DSH session journals from `%USERPROFILE%\.dsh` or `DSH_HOME`.
- Stores settings in `config.json` next to the application.
- Writes a local `widget.log`.
- Reads the Windows accent color and theme setting.

These files stay on the user's computer. The release archive does not include
the user's `config.json` or logs.

## Network access

The only network request is the optional DeepSeek balance request to
`platform.deepseek.com`. It is performed when **Show DeepSeek balance** is
enabled (the default) and uses the DSH account or a user-supplied API key.
It requests the account balance only; session contents, prompts, logs, and
questions are not sent.

The balance feature can be disabled in Settings. The local engine listens on
`127.0.0.1` only and is not exposed to the network.

## Uninstallation

The installer provides an uninstaller. It removes the application, shortcuts,
and the optional autostart entry, and asks separately what to do with
`config.json`.

## Contact

Privacy questions can be opened as a GitHub issue:
<https://github.com/MuratovMikhail/dsh-widget/issues>
