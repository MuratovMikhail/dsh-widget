; Inno Setup: установщик DSH Widget.
; Сборка: powershell -ExecutionPolicy Bypass -File .\build-installer.ps1
; Требуется только на машине сборки: https://jrsoftware.org/isdl.php

#define AppName "DSH Widget"
#ifndef AppVersion
  #define AppVersion "1.0.2"
#endif
#define AppPublisher "DSH Widget"
#define AppId "{{B7E1C0D4-5A62-4F0B-9A3E-2D7C6B1F0A55}"

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={localappdata}\Programs\DSH Widget
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=dist
OutputBaseFilename=DSHWidget-Setup-{#AppVersion}
SetupIconFile=assets\DSHWidget.ico
UninstallDisplayIcon={app}\assets\DSHWidget.ico
UninstallDisplayName={#AppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
MinVersion=10.0.17763
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=no
RestartApplications=no
AllowNoIcons=yes

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "mode_plugin"; Description: "{cm:ModePlugin}"; GroupDescription: "{cm:GroupLaunch}"; Flags: exclusive
Name: "mode_startup"; Description: "{cm:ModeStartup}"; GroupDescription: "{cm:GroupLaunch}"; Flags: exclusive unchecked
Name: "mode_manual"; Description: "{cm:ModeManual}"; GroupDescription: "{cm:GroupLaunch}"; Flags: exclusive unchecked
Name: "desktopicon"; Description: "{cm:DesktopIcon}"; GroupDescription: "{cm:GroupExtra}"; Flags: unchecked

[Files]
Source: "widget-ui.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "widget-engine.js"; DestDir: "{app}"; Flags: ignoreversion
Source: "start-widget.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "README.ru.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "README.zh-CN.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "CHANGELOG.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "CHANGELOG.ru.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "assets\DSHWidget.ico"; DestDir: "{app}\assets"; Flags: ignoreversion
Source: "assets\DSHWidget-Tray.ico"; DestDir: "{app}\assets"; Flags: ignoreversion
Source: "assets\notify.wav"; DestDir: "{app}\assets"; Flags: ignoreversion
Source: "locale\*.json"; DestDir: "{app}\locale"; Flags: ignoreversion
Source: "tools\stop-widget.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "tools\restart-widget.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "tools\install-plugin.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "tools\remove-plugin.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "tools\set-mode.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "plugin\dsh-widget-bridge-1.0.0.tgz"; DestDir: "{app}\plugin"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\start-widget.vbs"""; IconFilename: "{app}\assets\DSHWidget.ico"; WorkingDir: "{app}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\start-widget.vbs"""; IconFilename: "{app}\assets\DSHWidget.ico"; WorkingDir: "{app}"; Tasks: desktopicon
Name: "{userstartup}\{#AppName}"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\start-widget.vbs"""; IconFilename: "{app}\assets\DSHWidget.ico"; WorkingDir: "{app}"; Tasks: mode_startup

[Run]
Filename: "wscript.exe"; Parameters: """{app}\start-widget.vbs"""; WorkingDir: "{app}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\tools\stop-widget.ps1"""; Flags: runhidden; RunOnceId: "StopWidget"
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\tools\remove-plugin.ps1"""; Flags: runhidden; RunOnceId: "RemovePlugin"

[UninstallDelete]
Type: files; Name: "{app}\widget.log"
Type: files; Name: "{app}\runtime.json"
Type: files; Name: "{app}\bridge-stderr.log"

[Code]
function DshNodeFound: Boolean;
begin
  // Проверяем оба известных места, где DSH держит node.exe.
  Result := FileExists(ExpandConstant('{localappdata}\Programs\DeepSeek Harness\resources\runtime\primary-runtime\dependencies\node\bin\node.exe'))
         or FileExists(GetEnv('USERPROFILE') + '\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe');
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  Params: String;
  Mode: String;
begin
  if CurStep = ssPostInstall then
  begin
    if WizardIsTaskSelected('mode_plugin') then Mode := 'plugin'
    else if WizardIsTaskSelected('mode_startup') then Mode := 'startup'
    else Mode := 'manual';

    // Запоминаем режим (если config.json ещё нет) и задаём согласованный авто-выход.
    Params := '-NoProfile -ExecutionPolicy Bypass -File "' +
              ExpandConstant('{app}\tools\set-mode.ps1') + '" -Mode ' + Mode;
    Exec('powershell.exe', Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

    if Mode = 'plugin' then
    begin
      Params := '-NoProfile -ExecutionPolicy Bypass -File "' +
                ExpandConstant('{app}\tools\install-plugin.ps1') + '" -Quiet';
      if not Exec('powershell.exe', Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
        MsgBox(ExpandConstant('{cm:PluginStartFail}'), mbInformation, MB_OK)
      else if ResultCode = 3 then
        MsgBox(ExpandConstant('{cm:PluginNoDsh}'), mbInformation, MB_OK)
      else if ResultCode <> 0 then
        MsgBox(ExpandConstant('{cm:PluginInstallCode}') + ' ' + IntToStr(ResultCode), mbInformation, MB_OK);
    end;
  end;
end;
function InitializeSetup: Boolean;
begin
  Result := True;
  if not DshNodeFound then
    MsgBox(ExpandConstant('{cm:NodeMissing}'), mbInformation, MB_OK);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
  StopScript: String;
begin
  Result := '';
  NeedsRestart := False;
  // Если виджет уже запущен (обновление поверх), гасим его перед копированием файлов.
  StopScript := ExpandConstant('{app}\tools\stop-widget.ps1');
  if FileExists(StopScript) then
    Exec('powershell.exe', '-NoProfile -ExecutionPolicy Bypass -File "' + StopScript + '"',
         '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Answer: Integer;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    if FileExists(ExpandConstant('{app}\config.json')) then
    begin
      Answer := MsgBox('Удалить настройки виджета (config.json)?' + #13#10 +
                       'Если оставить, они пригодятся при повторной установке.',
                       mbConfirmation, MB_YESNO);
      if Answer = IDYES then
        DeleteFile(ExpandConstant('{app}\config.json'));
    end;
    // Пустую папку после себя не оставляем.
    RemoveDir(ExpandConstant('{app}'));
  end;
end;

[Messages]
russian.WizardSelectTasks=Режим запуска
russian.SelectTasksTitle=Режим запуска
russian.SelectTasksDesc=Выберите, как виджет должен запускаться. Это можно изменить позже в настройках.
russian.SelectTasksLabel2= 

english.WizardSelectTasks=Startup mode
english.SelectTasksTitle=Startup mode
english.SelectTasksDesc=Choose how the widget should start. You can change this later in the widget settings.
english.SelectTasksLabel2= 


[CustomMessages]
russian.PluginStartFail=Не удалось запустить установку плагина. Виджет будет работать отдельно;%nплагин можно поставить позже из папки программы.
english.PluginStartFail=Could not start the plugin installer. The widget will run separately;%nyou can install the plugin later from the app folder.
russian.PluginNoDsh=Плагин не установлен: профиль DeepSeek Harness не найден.%nВиджет установлен; запустите DSH один раз и запустите установщик ещё раз, чтобы включить автозапуск.
english.PluginNoDsh=The plugin wasn't installed: the DeepSeek Harness profile was not found.%nThe widget is installed; start DSH once and run the installer again to enable autostart.
russian.PluginInstallCode=Плагин не установлен, код:
english.PluginInstallCode=The plugin wasn't installed, code:
russian.NodeMissing=DeepSeek Harness не найден: нет node.exe в его каталоге.%nВиджет установится, но запустится только после установки DeepSeek Harness.
english.NodeMissing=DeepSeek Harness was not found: node.exe is missing from its folder.%nThe widget will install but can only start after DeepSeek Harness is installed.
russian.GroupLaunch=Способ запуска
english.GroupLaunch=Startup mode
russian.ModePlugin=Вместе с DeepSeek Harness (рекомендуется)
english.ModePlugin=With DeepSeek Harness (recommended)
russian.ModeStartup=При входе в Windows
english.ModeStartup=At Windows sign-in
russian.ModeManual=Вручную, по ярлыку
english.ModeManual=Manually, from a shortcut
russian.GroupExtra=Дополнительно
english.GroupExtra=Extras
russian.DesktopIcon=Создать ярлык на рабочем столе
english.DesktopIcon=Create a desktop shortcut
