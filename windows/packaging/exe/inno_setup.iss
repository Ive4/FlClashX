[Setup]
AppId={{APP_ID}}
AppVersion={{APP_VERSION}}
AppName={{DISPLAY_NAME}}
AppPublisher={{PUBLISHER_NAME}}
AppPublisherURL={{PUBLISHER_URL}}
AppSupportURL={{PUBLISHER_URL}}
AppUpdatesURL={{PUBLISHER_URL}}
DefaultDirName={{INSTALL_DIR_NAME}}
DisableProgramGroupPage=yes
OutputDir=.
OutputBaseFilename={{OUTPUT_BASE_FILENAME}}
Compression=lzma
SolidCompression=yes
SetupIconFile={{SETUP_ICON_FILE}}
SetupLogging=yes
WizardStyle=modern
PrivilegesRequired={{PRIVILEGES_REQUIRED}}
ArchitecturesAllowed={{ARCH}}
ArchitecturesInstallIn64BitMode={{ARCH}}

[Code]
procedure KillProcesses;
var
  Locator, Wmi, Processes, Process, ImagePath: Variant;
  AppDir, Path: String;
  i, ResultCode: Integer;
begin
  AppDir := AddBackslash(ExpandConstant('{app}'));
  try
    Locator := CreateOleObject('WbemScripting.SWbemLocator');
    Locator.Security_.Privileges.AddAsString('SeDebugPrivilege', True);
    Wmi := Locator.ConnectServer('.', 'root\CIMV2');
    Processes := Wmi.ExecQuery('SELECT * FROM Win32_Process WHERE Name = ''FlClashX.exe'' OR ' +
      'Name = ''FlClash.exe'' OR Name = ''FlClashDesktop.exe'' OR Name = ''FlClashCore.exe''');
    for i := 0 to Processes.Count - 1 do
    begin
      try
        Process := Processes.ItemIndex(i);
        ImagePath := Process.ExecutablePath;
        if not VarIsNull(ImagePath) then
        begin
          Path := ImagePath;
          if CompareText(Copy(Path, 1, Length(AppDir)), AppDir) = 0 then
          begin
            ResultCode := Process.Terminate(0);
            if ResultCode <> 0 then
              Log('Could not stop an installed process: ' + IntToStr(ResultCode));
          end;
        end;
      except
        Log('Could not check or stop an installed process.');
      end;
    end;
  except
    Log('Could not check for running installed processes.');
  end;
end;

function ServiceCommandMatches(Command, HelperPath: String): Boolean;
begin
  Command := Trim(Command);
  if Copy(Command, 1, 1) = '"' then
    HelperPath := '"' + HelperPath + '"'
  else if (Pos(' ', HelperPath) > 0) or (Pos(#9, HelperPath) > 0) then
  begin
    Result := False;
    Exit;
  end;
  Result := (CompareText(Copy(Command, 1, Length(HelperPath)), HelperPath) = 0) and
    (Pos(Copy(Command + ' ', Length(HelperPath) + 1, 1), ' ' + #9) > 0);
end;

function UnregisterHelperService: Boolean;
var
  HelperPath, Command: String;
  ResultCode: Integer;
begin
  HelperPath := AddBackslash(ExpandConstant('{app}')) + 'FlClashHelperService.exe';
  Result := True;
  if FileExists(HelperPath) and
    RegQueryStringValue(HKLM, 'SYSTEM\CurrentControlSet\Services\FlClashHelperService', 'ImagePath', Command) and
    ServiceCommandMatches(Command, HelperPath) then
  begin
    if not ExecAndLogOutput(HelperPath, 'uninstall', '', SW_HIDE, ewWaitUntilTerminated, ResultCode, nil) then
    begin
      Log('Could not run Helper uninstall: ' + SysErrorMessage(ResultCode));
      Result := False;
    end
    else if ResultCode <> 0 then
    begin
      Log('Helper uninstall exited with code ' + IntToStr(ResultCode));
      Result := False;
    end;
  end;
end;

procedure ClearStaleProxy;
var
  AppPath: String;
  ResultCode: Integer;
begin
  AppPath := ExpandConstant('{app}\\{{EXECUTABLE_NAME}}');
  if FileExists(AppPath) then
  begin
    Exec(AppPath, '--clear-stale-proxy', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;

function PointsIntoApp(Value: String): Boolean;
begin
  Result := Pos(Lowercase(AddBackslash(ExpandConstant('{app}'))), Lowercase(Value)) > 0;
end;

// The value name is appName and the schemes are protocolSchemes, both in
// lib/common.
procedure RemoveUserRegistrations;
var
  Schemes: TArrayOfString;
  Value: String;
  i: Integer;
begin
  if RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', '{{APP_NAME}}', Value) and PointsIntoApp(Value) then
  begin
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', '{{APP_NAME}}');
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run', '{{APP_NAME}}');
  end;

  Schemes := ['clash', 'clashmeta', 'flclash'];
  for i := 0 to GetArrayLength(Schemes)-1 do
  begin
    if RegQueryStringValue(HKCU, 'Software\Classes\' + Schemes[i] + '\shell\open\command', '', Value) and PointsIntoApp(Value) then
    begin
      RegDeleteKeyIncludingSubkeys(HKCU, 'Software\Classes\' + Schemes[i]);
    end;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  if not UnregisterHelperService then
  begin
    Result := CustomMessage('HelperUninstallFailed');
    Exit;
  end;
  KillProcesses;
  Result := '';
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    ClearStaleProxy;
  end;
end;

function InitializeUninstall(): Boolean;
begin
  Result := UnregisterHelperService;
  if not Result then
  begin
    SuppressibleMsgBox(CustomMessage('HelperUninstallFailed'), mbError, MB_OK, IDOK);
    Exit;
  end;
  KillProcesses;
  ClearStaleProxy;
end;

// path_provider names these folders after CompanyName and ProductName in
// windows/runner/Runner.rc.
procedure RemoveUserData;
begin
  DelTree(ExpandConstant('{userappdata}\com.follow\clash'), True, True, True);
  DelTree(ExpandConstant('{localappdata}\com.follow\clash'), True, True, True);
  RemoveDir(ExpandConstant('{userappdata}\com.follow'));
  RemoveDir(ExpandConstant('{localappdata}\com.follow'));
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    RemoveUserRegistrations;
    if not UninstallSilent and (MsgBox(CustomMessage('RemoveUserData'), mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES) then
    begin
      RemoveUserData;
    end;
  end;
end;

[Languages]
{% for locale in LOCALES %}
{% if locale.lang == 'en' %}Name: "english"; MessagesFile: "compiler:Default.isl"{% endif %}
{% if locale.lang == 'hy' %}Name: "armenian"; MessagesFile: "compiler:Languages\\Armenian.isl"{% endif %}
{% if locale.lang == 'bg' %}Name: "bulgarian"; MessagesFile: "compiler:Languages\\Bulgarian.isl"{% endif %}
{% if locale.lang == 'ca' %}Name: "catalan"; MessagesFile: "compiler:Languages\\Catalan.isl"{% endif %}
{% if locale.lang == 'zh' %}
Name: "chineseSimplified"; MessagesFile: {% if locale.file %}{{ locale.file }}{% else %}"compiler:Languages\\ChineseSimplified.isl"{% endif %}
{% endif %}
{% if locale.lang == 'co' %}Name: "corsican"; MessagesFile: "compiler:Languages\\Corsican.isl"{% endif %}
{% if locale.lang == 'cs' %}Name: "czech"; MessagesFile: "compiler:Languages\\Czech.isl"{% endif %}
{% if locale.lang == 'da' %}Name: "danish"; MessagesFile: "compiler:Languages\\Danish.isl"{% endif %}
{% if locale.lang == 'nl' %}Name: "dutch"; MessagesFile: "compiler:Languages\\Dutch.isl"{% endif %}
{% if locale.lang == 'fi' %}Name: "finnish"; MessagesFile: "compiler:Languages\\Finnish.isl"{% endif %}
{% if locale.lang == 'fr' %}Name: "french"; MessagesFile: "compiler:Languages\\French.isl"{% endif %}
{% if locale.lang == 'de' %}Name: "german"; MessagesFile: "compiler:Languages\\German.isl"{% endif %}
{% if locale.lang == 'he' %}Name: "hebrew"; MessagesFile: "compiler:Languages\\Hebrew.isl"{% endif %}
{% if locale.lang == 'is' %}Name: "icelandic"; MessagesFile: "compiler:Languages\\Icelandic.isl"{% endif %}
{% if locale.lang == 'it' %}Name: "italian"; MessagesFile: "compiler:Languages\\Italian.isl"{% endif %}
{% if locale.lang == 'ja' %}Name: "japanese"; MessagesFile: "compiler:Languages\\Japanese.isl"{% endif %}
{% if locale.lang == 'no' %}Name: "norwegian"; MessagesFile: "compiler:Languages\\Norwegian.isl"{% endif %}
{% if locale.lang == 'pl' %}Name: "polish"; MessagesFile: "compiler:Languages\\Polish.isl"{% endif %}
{% if locale.lang == 'pt' %}Name: "portuguese"; MessagesFile: "compiler:Languages\\Portuguese.isl"{% endif %}
{% if locale.lang == 'ru' %}Name: "russian"; MessagesFile: "compiler:Languages\\Russian.isl"{% endif %}
{% if locale.lang == 'sk' %}Name: "slovak"; MessagesFile: "compiler:Languages\\Slovak.isl"{% endif %}
{% if locale.lang == 'sl' %}Name: "slovenian"; MessagesFile: "compiler:Languages\\Slovenian.isl"{% endif %}
{% if locale.lang == 'es' %}Name: "spanish"; MessagesFile: "compiler:Languages\\Spanish.isl"{% endif %}
{% if locale.lang == 'tr' %}Name: "turkish"; MessagesFile: "compiler:Languages\\Turkish.isl"{% endif %}
{% if locale.lang == 'uk' %}Name: "ukrainian"; MessagesFile: "compiler:Languages\\Ukrainian.isl"{% endif %}
{% endfor %}

[CustomMessages]
english.HelperUninstallFailed=Could not stop the FlClash Helper service. Restart Windows and try again.
chineseSimplified.HelperUninstallFailed=无法停止 FlClash Helper 服务。请重启 Windows 后重试。
english.RemoveUserData=Also delete your profiles and settings?

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: {% if CREATE_DESKTOP_ICON != true %}unchecked{% else %}checkedonce{% endif %}
[Files]
Source: "{{SOURCE_DIR}}\\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; NOTE: Don't use "Flags: ignoreversion" on any shared system files

[Icons]
Name: "{autoprograms}\\{{DISPLAY_NAME}}"; Filename: "{app}\\{{EXECUTABLE_NAME}}"
Name: "{autodesktop}\\{{DISPLAY_NAME}}"; Filename: "{app}\\{{EXECUTABLE_NAME}}"; Tasks: desktopicon
[Run]
Filename: "{app}\\{{EXECUTABLE_NAME}}"; Description: "{cm:LaunchProgram,{{DISPLAY_NAME}}}"; Flags: {% if PRIVILEGES_REQUIRED == 'admin' %}runascurrentuser{% endif %} nowait postinstall skipifsilent
