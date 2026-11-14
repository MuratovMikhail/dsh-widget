# Contributing

Thanks for helping with DSH Widget. The project is a small Windows desktop tool:
PowerShell 5.1 + WinForms for the UI and a dependency-free Node engine.

## Requirements

- Windows 10 (1809+, x64) or Windows 11 (x64)
- Windows PowerShell 5.1
- Node.js 22.15+ (24.x is what DSH bundles)
- Inno Setup 6 only for building the installer

## Local checks

```powershell
node --check widget-engine.js
node tools\test-subagents.js
node tools\test-selection.js
node tools\test-ack.js
node tools\test-content.js
```

PowerShell files must be UTF-8 with BOM. The CI checks this for every `.ps1` file.

## UI and previews

```powershell
# all localized card previews (needs a desktop session)
powershell -ExecutionPolicy Bypass -File .\tools\make-previews.ps1 -Lang en
powershell -ExecutionPolicy Bypass -File .\tools\make-previews.ps1 -Lang ru
powershell -ExecutionPolicy Bypass -File .\tools\make-previews.ps1 -Lang zh-CN

# contact sheet for one language
powershell -ExecutionPolicy Bypass -File .\tools\make-states-sheet.ps1 -Lang en
```

## Pull requests

- Keep changes focused; one concern per PR.
- Run the checks above and say what you ran.
- Update README/CHANGELOG when behavior or public settings change.
- Keep user-facing strings in `locale/en.json`, `ru.json`, and `zh-CN.json`.
- Do not commit `config.json`, logs, `dist/`, or generated test screenshots.

## Commit style

Short imperative subject, for example:

```text
Fix first completion sound
Add Windows 10 fallback for rounded corners
```

## License

By contributing, you agree that your changes are released under the MIT License.
