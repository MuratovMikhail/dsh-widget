; Inno Setup: установщик DSH Widget.
; Сборка: powershell -ExecutionPolicy Bypass -File .\build-installer.ps1
; Требуется только на машине сборки: https://jrsoftware.org/isdl.php

#define AppName "DSH Widget"
#ifndef AppVersion
  #define AppVersion "1.0.6"
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
DisableDirPage=no
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
Source: "VERSION"; DestDir: "{app}"; Flags: ignoreversion
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
Source: "tools\status.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "tools\write-pointer.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "tools\restart-widget.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "tools\dsh-common.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "tools\install-plugin.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "tools\finish-plugin.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "tools\cancel-pending-plugin.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "tools\remove-plugin.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "tools\set-mode.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "plugin\dsh-widget-bridge-1.0.1.tgz"; DestDir: "{app}\plugin"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\start-widget.vbs"""; IconFilename: "{app}\assets\DSHWidget.ico"; WorkingDir: "{app}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\start-widget.vbs"""; IconFilename: "{app}\assets\DSHWidget.ico"; WorkingDir: "{app}"; Tasks: desktopicon
Name: "{userstartup}\{#AppName}"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\start-widget.vbs"""; IconFilename: "{app}\assets\DSHWidget.ico"; WorkingDir: "{app}"; Tasks: mode_startup

[Run]
Filename: "wscript.exe"; Parameters: """{app}\start-widget.vbs"""; WorkingDir: "{app}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\tools\stop-widget.ps1"""; Flags: runhidden; RunOnceId: "StopWidget"
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\tools\cancel-pending-plugin.ps1"" -AppDir ""{app}"""; Flags: runhidden; RunOnceId: "CancelPending"
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\tools\remove-plugin.ps1"""; Flags: runhidden; RunOnceId: "RemovePlugin"

[UninstallDelete]
Type: files; Name: "{app}\widget.log"
Type: files; Name: "{app}\runtime.json"
Type: files; Name: "{app}\bridge-stderr.log"
Type: files; Name: "{app}\finish-plugin.log"
Type: files; Name: "{app}\cancel-plugin.log"
Type: files; Name: "{app}\pending-plugin.json"
Type: files; Name: "{localappdata}\DSH Widget\install-dir.txt"

[Code]
procedure Notify(const Text: String);
begin
  if WizardSilent then
    Log(Text)
  else
    MsgBox(Text, mbInformation, MB_OK);
end;
function DshNodeFound: Boolean;
begin
  // Проверяем оба известных места, где DSH держит node.exe.
  Result := FileExists(ExpandConstant('{localappdata}\Programs\DeepSeek Harness\resources\runtime\primary-runtime\dependencies\node\bin\node.exe'))
         or FileExists(GetEnv('USERPROFILE') + '\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe');
end;

procedure WriteInstallPointer;
var
  ResultCode: Integer;
  Params: String;
begin
  // Плагин запускается из профиля DSH и не знает, куда пользователь
  // поставил виджет. Указатель пишет PowerShell в UTF-8 без BOM.
  Params := '-NoProfile -ExecutionPolicy Bypass -File "' +
            ExpandConstant('{app}\tools\write-pointer.ps1') + '" -AppDir "' +
            ExpandConstant('{app}') + '"';
  if not Exec('powershell.exe', Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Log('Could not start install pointer writer');
end;

procedure WritePendingMarker;
var
  FileName: String;
begin
  FileName := ExpandConstant('{app}\pending-plugin.json');
  if not SaveStringToFile(FileName, '{"requestedMode":"plugin"}', False) then
    Log('Could not write pending plugin marker: ' + FileName);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  Params: String;
  Mode: String;
  StartPending: Boolean;
begin
  if CurStep = ssPostInstall then
  begin
    StartPending := False;
    WriteInstallPointer;

    if WizardIsTaskSelected('mode_plugin') then Mode := 'plugin'
    else if WizardIsTaskSelected('mode_startup') then Mode := 'startup'
    else Mode := 'manual';

    // Перед любой сменой режима отменяем старый finisher и удаляем bridge.
    // Иначе startup/manual мог бы унаследовать plugin от прошлой установки.
    Params := '-NoProfile -ExecutionPolicy Bypass -File "' +
              ExpandConstant('{app}\tools\cancel-pending-plugin.ps1') + '" -AppDir "' +
              ExpandConstant('{app}') + '"';
    if not Exec('powershell.exe', Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
      RaiseException(ExpandConstant('{cm:ModeSwitchFail}'))
    else if ResultCode <> 0 then
      RaiseException(ExpandConstant('{cm:ModeSwitchFail}'));

    if Mode = 'plugin' then
    begin
      Params := '-NoProfile -ExecutionPolicy Bypass -File "' +
                ExpandConstant('{app}\tools\install-plugin.ps1') + '" -Quiet';
      if not Exec('powershell.exe', Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
      begin
        Notify(ExpandConstant('{cm:PluginStartFail}'));
        Mode := 'manual';
      end
      else if ResultCode = 3 then
      begin
        Notify(ExpandConstant('{cm:PluginNoDsh}'));
        Mode := 'manual';
        StartPending := True;
      end
      else if ResultCode <> 0 then
      begin
        Notify(ExpandConstant('{cm:PluginInstallCode}') + ' ' + IntToStr(ResultCode));
        Mode := 'manual';
      end;
    end;

    // Режим записываем только после успешной установки плагина:
    // иначе config.json говорил бы «plugin», а профиль DSH — «manual».
    Params := '-NoProfile -ExecutionPolicy Bypass -File "' +
              ExpandConstant('{app}\tools\set-mode.ps1') + '" -Mode ' + Mode;
    Exec('powershell.exe', Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

    // Ярлык автозапуска — часть режима, а не «остаток» прошлой установки.
    if Mode <> 'startup' then
      DeleteFile(ExpandConstant('{userstartup}\DSH Widget.lnk'));
    if not WizardIsTaskSelected('desktopicon') then
      DeleteFile(ExpandConstant('{autodesktop}\DSH Widget.lnk'));

    // DSH ещё ни разу не открывали: профиля нет. Ждём первый запуск и
    // закрытие DSH, затем ставим плагин и переключаем режим на plugin.
    if StartPending then
    begin
      WritePendingMarker;
      Params := '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
                ExpandConstant('{app}\tools\finish-plugin.ps1') + '" -TimeoutSec 1800';
      if not Exec('powershell.exe', Params, '', SW_HIDE, ewNoWait, ResultCode) then
        Notify(ExpandConstant('{cm:PluginStartFail}'));
    end;
  end;
end;
function InitializeSetup: Boolean;
begin
  Result := True;
  if not DshNodeFound then
    Notify(ExpandConstant('{cm:NodeMissing}'));
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
      if UninstallSilent then
        DeleteFile(ExpandConstant('{app}\config.json'))
      else
      begin
        Answer := MsgBox('Удалить настройки виджета (config.json)?' + #13#10 +
                         'Если оставить, они пригодятся при повторной установке.',
                         mbConfirmation, MB_YESNO);
        if Answer = IDYES then
          DeleteFile(ExpandConstant('{app}\config.json'));
      end;
    end;
    DeleteFile(ExpandConstant('{app}\pending-plugin.json'));
    DeleteFile(ExpandConstant('{localappdata}\DSH Widget\install-dir.txt'));
    RemoveDir(ExpandConstant('{localappdata}\DSH Widget'));
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
russian.PluginNoDsh=Профиль DeepSeek Harness ещё не создан.%nВиджет установлен. Запустите DSH один раз и закройте его — плагин и режим «вместе с DSH» включатся автоматически.
english.PluginNoDsh=The DeepSeek Harness profile does not exist yet.%nThe widget is installed. Start DSH once and close it — the plugin and “with DSH” mode will be enabled automatically.
russian.PluginInstallCode=Плагин не установлен, код:
english.PluginInstallCode=The plugin wasn't installed, code:
russian.ModeSwitchFail=Не удалось корректно переключить режим запуска и убрать старый плагин.%nУстановка остановлена, чтобы не оставить два механизма запуска.
english.ModeSwitchFail=Could not switch the launch mode and remove the old plugin cleanly.%nSetup stopped to avoid leaving two launch mechanisms.
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
