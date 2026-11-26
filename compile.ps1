<#
.SYNOPSIS
    Baut Astocad-Self (FreeCAD) und erstellt den Windows-Installer.

.DESCRIPTION
    Ablauf:
      1. Voraussetzungen pruefen (Pixi, Visual Studio C++, Inno Setup, C#-Compiler)
      2. Konfigurieren und kompilieren (Pixi / CMake / Ninja)
      3. Staging-Verzeichnis dist\<release|debug> befuellen
      4. Launcher Astocad-Self.exe kompilieren
      5. Installer mit Inno Setup erstellen

.PARAMETER Debug
    Baut im Debug-Modus statt im Release-Modus.

.EXAMPLE
    .\compile.ps1
    .\compile.ps1 -Debug
#>
param (
    [switch]$Debug
)

# WICHTIG: Auf 'Continue' lassen, damit stderr von CMake/Ninja nicht faelschlich als Crash gewertet wird.
# Fehler externer Programme werden stattdessen ueber Assert-ExitCode anhand von $LASTEXITCODE erkannt.
$ErrorActionPreference = 'Continue'

# Alle Pfade im Skript sind relativ zum Repo-Root -> unabhaengig vom Aufrufort dorthin wechseln.
Push-Location $PSScriptRoot

# ==========================================
# Hilfsfunktionen
# ==========================================

# Bricht den Build mit Meldung ab und stellt das Ausgangsverzeichnis wieder her.
function Stop-Build {
    param(
        [string]$Message,
        [string]$Hint,
        [int]$Code = 1
    )
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Red
    Write-Host "[ABBRUCH] $Message" -ForegroundColor Red
    if ($Hint) { Write-Host $Hint -ForegroundColor Yellow }
    Write-Host "==========================================" -ForegroundColor Red
    Pop-Location
    exit $Code
}

# Prueft den ECHTEN Exit-Code von externen Programmen (Pixi, CMake, Ninja, csc, ISCC).
function Assert-ExitCode {
    param([string]$StepName)
    if ($LASTEXITCODE -ne 0) {
        Stop-Build -Message "$StepName ist fehlgeschlagen! (Code: $LASTEXITCODE)" `
                   -Hint "Das Skript wird gestoppt, um fehlerhafte Pakete zu verhindern." `
                   -Code $LASTEXITCODE
    }
}

# Einheitliche Ueberschrift fuer jeden Hauptschritt.
function Write-Step {
    param([string]$Title)
    Write-Host ""
    Write-Host "==> $Title" -ForegroundColor Cyan
}

# ==========================================
# Konfiguration
# ==========================================
$buildType = if ($Debug) { "debug" } else { "release" }
$buildDir  = ".\build\$buildType"
$distDir   = ".\dist\$buildType"
$pixiEnv   = ".\.pixi\envs\default"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Starte Build im Modus: $($buildType.ToUpper())" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# ==========================================
# 1. Voraussetzungen pruefen
# ==========================================
Write-Step "[1/5] Pruefe Voraussetzungen..."

# 1.1 Pixi (notfalls aus dem Standard-Installationsordner in den PATH holen)
$pixiCmd = Get-Command pixi -ErrorAction SilentlyContinue
if (-not $pixiCmd -and (Test-Path "$env:USERPROFILE\.pixi\bin\pixi.exe")) {
    $env:Path += ";$env:USERPROFILE\.pixi\bin"
    $pixiCmd = Get-Command pixi -ErrorAction SilentlyContinue
}
if (-not $pixiCmd) {
    Stop-Build -Message "Pixi ist nicht installiert oder nicht im PATH!" `
               -Hint "Installationsbefehl: iwr -useb https://pixi.sh/install.ps1 | iex"
}

# 1.2 Visual Studio C++ Build Tools
$vswhere  = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$hasVsCpp = $false
if (Test-Path $vswhere) {
    $vsPath   = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $hasVsCpp = [bool]($vsPath -and (Test-Path $vsPath))
}
if (-not $hasVsCpp) {
    Stop-Build -Message "Visual Studio C++ Build Tools fehlen!" `
               -Hint "Bitte installiere 'Desktopentwicklung mit C++': https://aka.ms/vs/17/release/vs_community.exe"
}

# 1.3 Inno Setup - wird erst in Schritt 5 gebraucht, aber vorab geprueft,
#     damit der Build nicht erst nach der langen Kompilierung scheitert.
$isccCandidates = @(
    (Get-Command iscc.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
)
$iscc = $isccCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $iscc) {
    Stop-Build -Message "ISCC.exe (Inno Setup 6) konnte nicht gefunden werden!" `
               -Hint "Download: https://jrsoftware.org/isdl.php"
}

# 1.4 C#-Compiler des .NET Frameworks (fuer den Launcher in Schritt 4)
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) {
    Stop-Build -Message "C#-Compiler nicht gefunden: $csc" `
               -Hint "Benoetigt wird das .NET Framework 4.x (unter Windows 10/11 normalerweise vorhanden)."
}

Write-Host "Alle Tools vorhanden (Pixi, Visual Studio C++, Inno Setup, csc)." -ForegroundColor Green

# ==========================================
# 2. Konfigurieren & Kompilieren (Pixi / CMake / Ninja)
# ==========================================
Write-Step "[2/5] Konfiguriere und kompiliere ($buildType)..."

# 2.1 CMake-Konfiguration
pixi run "configure-$buildType"
Assert-ExitCode "CMake Konfiguration ($buildType)"

# 2.2 Kompilierung
pixi run "build-$buildType"
Assert-ExitCode "Kompilierung / Ninja Build ($buildType)"

# ==========================================
# 3. Staging-Verzeichnis befuellen (dist\release bzw. dist\debug)
# ==========================================
Write-Step "[3/5] Bereite Staging-Verzeichnis $distDir vor..."

New-Item -ItemType Directory -Path $distDir -Force | Out-Null
$distPath = (Resolve-Path $distDir).Path

# 3.1 FreeCAD-Binaries installieren
Write-Host "Installiere Binaries nach $distPath..."
pixi run cmake --install "build/$buildType" --prefix "$distPath"
Assert-ExitCode "CMake Install nach $distPath"

# 3.2 Laufzeit-DLLs & Qt-Plugins aus der Pixi-Umgebung
Write-Host "Kopiere Laufzeit-DLLs und Qt-Plugins..."
Copy-Item -Path "$pixiEnv\Library\bin\*.dll"         -Destination "$distDir\bin\" -Force
Copy-Item -Path "$pixiEnv\Library\lib\qt6\plugins\*" -Destination "$distDir\bin\" -Recurse -Force

# 3.3 FreeCAD-Module und Daten aus dem Build (Mod ist Pflicht, der Rest optional)
Write-Host "Kopiere FreeCAD-Module und Daten..."
Copy-Item -Path "$buildDir\Mod" -Destination "$distDir\" -Recurse -Force
foreach ($optionalDir in 'Ext', 'data', 'resources') {
    Copy-Item -Path "$buildDir\$optionalDir" -Destination "$distDir\" -Recurse -Force -ErrorAction SilentlyContinue
}

# 3.4 Python-Laufzeitumgebung
#     DLLs\ landet sowohl im dist-Root (neben Lib\) als auch in bin\ (neben FreeCAD.exe).
Write-Host "Kopiere Python-Laufzeitumgebung..."
Copy-Item -Path "$pixiEnv\Lib"         -Destination "$distDir\"     -Recurse -Force
Copy-Item -Path "$pixiEnv\DLLs"        -Destination "$distDir\"     -Recurse -Force
Copy-Item -Path "$pixiEnv\DLLs"        -Destination "$distDir\bin\" -Recurse -Force
Copy-Item -Path "$pixiEnv\python*.exe" -Destination "$distDir\bin\" -Force -ErrorAction SilentlyContinue
Copy-Item -Path "$pixiEnv\python*.dll" -Destination "$distDir\bin\" -Force -ErrorAction SilentlyContinue

# ==========================================
# 4. Isolations-Launcher Astocad-Self.exe kompilieren
# ==========================================
Write-Step "[4/5] Kompiliere eigenstaendigen Launcher Astocad-Self.exe..."

# Startet bin\FreeCAD.exe mit eigenem Benutzerverzeichnis (%APPDATA%\Astocad-Self),
# damit sich Einstellungen/Makros nicht mit einer normalen FreeCAD-Installation vermischen.
# Single-Quote-Here-String: PowerShell ersetzt darin nichts, der C#-Code bleibt unveraendert.
$launcherCode = @'
using System;
using System.Diagnostics;
using System.IO;

class Program {
    // Argumente mit Leerzeichen (z. B. Dateipfade per Doppelklick) wieder in Anfuehrungszeichen setzen
    static string Quote(string arg) {
        if (arg.Length > 0 && arg.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return arg;
        return "\"" + arg.Replace("\"", "\\\"") + "\"";
    }

    static void Main(string[] args) {
        string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        string userDir = Path.Combine(appData, "Astocad-Self");
        if (!Directory.Exists(userDir)) Directory.CreateDirectory(userDir);

        // Setzt die Umgebungsvariablen NUR fuer diesen Prozess und seine Kindprozesse
        Environment.SetEnvironmentVariable("FREECAD_USER_DATA", userDir);
        Environment.SetEnvironmentVariable("FREECAD_USER_HOME", userDir);

        string binDir  = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "bin");
        string exePath = Path.Combine(binDir, "FreeCAD.exe");

        ProcessStartInfo psi = new ProcessStartInfo(exePath);
        psi.Arguments        = string.Join(" ", Array.ConvertAll(args, Quote));
        psi.WorkingDirectory = binDir;
        psi.UseShellExecute  = false; // Wichtig: Kindprozess erbt die isolierten Umgebungsvariablen

        Process.Start(psi);
    }
}
'@

$tempCs = Join-Path $env:TEMP "AstocadLauncher.cs"
Set-Content -Path $tempCs -Value $launcherCode -Encoding UTF8

& $csc /nologo /target:winexe /optimize+ /out:"$distDir\Astocad-Self.exe" $tempCs
Assert-ExitCode "Launcher Kompilierung (Astocad-Self.exe)"
Remove-Item -Path $tempCs -Force -ErrorAction SilentlyContinue

# ==========================================
# 5. Installer mit Inno Setup erstellen
# ==========================================
$outputName = "Astocad-Self-$buildType-Setup"
Write-Step "[5/5] Erstelle Setup ($outputName) mit $iscc..."

& $iscc "/DSourceDir=$distDir" "/F$outputName" '.\installer.iss'
Assert-ExitCode "Inno Setup Compiler"

Pop-Location

Write-Host ""
Write-Host "========================================================" -ForegroundColor Green
Write-Host " Installer erfolgreich erstellt!" -ForegroundColor Green
Write-Host " Datei: .\Installer-Output\$outputName.exe" -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Green
