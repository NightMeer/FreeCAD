#ifndef SourceDir
  #define SourceDir "dist\release"
#endif

[Setup]
AppName=Astocad-Self
AppVersion=1.0
DefaultDirName={localappdata}\Programs\Astocad-Self
DefaultGroupName=Astocad-Self
OutputDir=.\Installer-Output
OutputBaseFilename=Astocad-Self-Setup
Compression=lzma2/ultra64
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\bin\FreeCAD.exe
PrivilegesRequired=lowest
DisableDirPage=no
AppendDefaultDirName=yes

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; WICHTIG: Nutzt jetzt dynamisch {#SourceDir} statt fest dist\*
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\Astocad-Self\Astocad-Self"; Filename: "{app}\bin\FreeCAD.exe"
Name: "{userdesktop}\Astocad-Self"; Filename: "{app}\bin\FreeCAD.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\bin\FreeCAD.exe"; Description: "{cm:LaunchProgram,Astocad-Self}"; Flags: nowait postinstall skipifsilent