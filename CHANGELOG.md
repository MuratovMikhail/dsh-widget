**English** · [Русский](CHANGELOG.ru.md)

# Changelog

## 1.0.4 — 2026-11-15

### Fixed

- A failing `dsh` CLI no longer terminates the plugin installer before the direct fallback: stderr is treated as output, not as a fatal PowerShell error.
- DSH home discovery now also checks uninstall registry entries, so a portable install with the profile next to the executable is found when `InstallLocation` is registered.
- Plugin failure messages no longer block `/VERYSILENT` installs; they are written to the setup log instead of showing a modal dialog.

### Verified

- Local matrix: custom `DSH_HOME`, default profile, no profile, existing plugin, manual mode, registry-based portable profile, malformed profile. All installer exit codes are 0 and `launchMode` matches the actual bundle state.

## 1.0.3 — 2026-11-14

### Fixed

- The installer now writes `launchMode=plugin` only after the bridge plugin is actually present in the DSH profile. If the plugin cannot be installed, the effective mode is rolled back to manual instead of leaving `config.json` and the real profile out of sync.
- DSH is discovered through the running process, uninstall registry, `PATH`, `DSH_HOME`, and `%USERPROFILE%\.dsh`, not only `%LOCALAPPDATA%\Programs`.
- "Open DeepSeek Harness" and the settings plugin check now use the same portable-install discovery, so a folder-based DSH can be opened and detected correctly.

## 1.0.2 — 2026-11-14

### Fixed

- The installer now finds the DSH CLI in portable or non-default installations and falls back to installing the bridge plugin directly into the DSH profile. This fixes the false "DeepSeek Harness has never been opened" message when DSH is running from a folder.
- The direct plugin install no longer depends on the CLI being under `%LOCALAPPDATA%\Programs\DeepSeek Harness`.

## 1.0.1 — 2026-11-14

### Fixed

- The installer no longer crashes with `Unknown constant 'userprofile'` when DSH's Node is found only under `%USERPROFILE%` instead of `%LOCALAPPDATA%`.
- Plan mode now shows **Waiting for approval** in the widget instead of **Working** while DSH waits for "Approve" or "Request changes".

### Changed

- The tray icon is a single static branded "D"; the current state is shown in its tooltip.
- Removed the duplicated state contact sheet and the tray previews with Russian labels from the English README.
- README, privacy, and Windows 10 notes were cleaned up; the unused empty-state preview was removed.

## 1.0.0 — 2026-11-14

### Widget

- New compact layout: 328×92 px per session (down from 114), with no progress bar.
- One status indicator instead of a bar: an accent spinner for work, violet for subagents, a pulsing dot for waiting, a green halo dot for Done, and a red one for errors.
- The spinner and session title use the Windows accent color (adjusted for readability); the setting is "Use Windows accent for indicator and title".
- The header shows the project (`DSH · billing-service`) instead of `DEEPSEEK HARNESS`; the balance no longer carries a source label.
- Removed "step 12", "after tool", duplicate subagent counters, the "double-click — DSH" hint, and the "sessions: N" footer (replaced by "N more sessions" only when there is overflow).
- Plan progress is a compact `2/5` chip; time is shown only where useful (`4:32`, `took 3:12`).
- Waiting shows the agent's question text, while approval is a separate "Waiting for approval" state.
- A turn that failed is no longer presented as Done: "Stopped", a red halo dot, and the Windows error sound.
- An error no longer disappears just because the DSH window is in focus: the widget keeps it until you click the block (an explicit "seen") or until `doneVisibleSec` expires.
- Settings were rewritten in plain language: "Startup", "Window", "Widget", "DeepSeek balance"; a mode unavailable without the plugin is not shown as a greyed-out stub, the key field appears only for your own key, numbers are centered, and the system white arrows were replaced with a compact dark stepper.
- The tray menu now has "About": version, author (Mikhail Muratov), description, license, and a GitHub link; the window uses the current light/dark theme and closes with the cross or Esc, without a separate button.
- The settings gear was redrawn: a standard Windows icon instead of a star-like shape.
- Clicking a block focuses the separate DSH window for that session when it is open; the widget cannot switch tabs inside the main DSH window — DSH exposes no external API for that.
- Added languages: English (primary), Russian, and Simplified Chinese; the language follows Windows, can be switched in settings, and applies after a widget restart. The widget, tray, settings, About, plugin, and README with screenshots are localized.
- Windows 10 (1809+, x64) support: DWM rounded corners are used on Windows 11, with a rounded-window-region fallback on Windows 10; Segoe UI and Segoe MDL2 Assets replace Segoe UI Variable; the installer minimum is 10.0.17763.
- GitHub publishing: a tag-driven release workflow builds the portable zip, the installer, and SHA-256 checksums; CI, issue templates, security policy, and contribution docs were added.
- Version for the GitHub publication: 1.0.0.
- Removed the sound test button — "knock-knock" / system / no sound are self-explanatory.

### Engine

- Incremental journal reading: only new bytes are read instead of the whole file (8.8 MB → under 5 ms per update instead of ~560 ms for a full pass).
- `activeCount` for "N more sessions", `todo/write`, `callId` matching for results, and `remainder` for records on zstd frame boundaries.
- Closed a CORS hole: requests with `Origin` and a foreign `Host` receive 403; ACAO is no longer returned.
- The engine exits with the UI (`--parent-pid`) and cleans stale `store` records.
- Poll tick is 1 s; the version is exposed in `/health` and `/status`; there is a clear error if Node lacks zstd support.

### Other

- `widget.log` rotates after 256 KB.
- Removed the unused "custom sound" mode (it was never in the UI): only the built-in "knock-knock", the system signal, and "no sound" remain.
- Updated previews, README, installer 1.0.0, MIT license, and CI.
- Small fixes: `install.ps1` no longer copies the unused `widget.ico`; `installer.iss` merged two identical uninstall blocks; the bridge plugin correctly describes `DSH_WIDGET_DIR`.
