param (
    [switch]$Debug
)

# WICHTIG: Auf 'Continue' lassen, damit stderr von Git/CMake nicht fälschlich als Crash gewertet wird.
$ErrorActionPreference = 'Continue'

# Hilfsfunktion: Prüft den ECHTEN Exit-Code von externen Programmen (Pixi, Ninja, CMake, Git etc.)
function Check-ExitCode {
    param([string]$StepName)
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "==========================================" -ForegroundColor Red
        Write-Host "[ABBRUCH] $StepName ist fehlgeschlagen! (Code: $LASTEXITCODE)" -ForegroundColor Red
        Write-Host "Das Skript wird gestoppt, um fehlerhafte Pakete zu verhindern." -ForegroundColor Red
        Write-Host "==========================================" -ForegroundColor Red
        exit $LASTEXITCODE
    }
}

# -------------------------------------------------------------
# Modus festlegen (Default = release, bei -Debug Flag = debug)
# -------------------------------------------------------------
$buildType = if ($Debug) { "debug" } else { "release" }

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Starte Build im Modus: $($buildType.ToUpper())" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# ==========================================
# 0. Vorab-Prüfung: Tooling (Pixi & Visual Studio)
# ==========================================
Write-Host "Pruefe Voraussetzungen..." -ForegroundColor Cyan

# 0.1 Pixi prüfen
$pixiCmd = Get-Command pixi -ErrorAction SilentlyContinue
if (-not $pixiCmd -and (Test-Path "$env:USERPROFILE\.pixi\bin\pixi.exe")) {
    $env:Path += ";$env:USERPROFILE\.pixi\bin"
    $pixiCmd = Get-Command pixi -ErrorAction SilentlyContinue
}

if (-not $pixiCmd) {
    Write-Host "`n[FEHLER] Pixi ist nicht installiert oder nicht im PATH!" -ForegroundColor Red
    Write-Host "Installationsbefehl: iwr -useb https://pixi.sh/install.ps1 | iex`n" -ForegroundColor Yellow
    exit 1
}

# 0.2 Visual Studio C++ Compiler prüfen
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$hasVsCpp = $false

if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($vsPath -and (Test-Path $vsPath)) {
        $hasVsCpp = $true
    }
}

if (-not $hasVsCpp) {
    Write-Host "`n[FEHLER] Visual Studio C++ Build Tools fehlen!" -ForegroundColor Red
    Write-Host "Bitte installiere 'Desktopentwicklung mit C++': https://aka.ms/vs/17/release/vs_community.exe`n" -ForegroundColor Yellow
    exit 1
}

Write-Host "Alle Tools vorhanden (Pixi & Visual Studio C++ erkannt)." -ForegroundColor Green

# ==========================================
# 1. OndselSolver Branch-Prüfung
# ==========================================
$ondselDir = "src\3rdParty\OndselSolver"
$targetBranch = "paddle/codex/forward-rigid-body-dynamics"

if (-not (Test-Path $ondselDir)) {
    Write-Host "Submodul-Ordner fehlt, fuehre Initialisierung aus..." -ForegroundColor Yellow
    git submodule update --init --recursive $ondselDir
    Check-ExitCode "Git Submodule Init"
}

Push-Location $ondselDir
try {
    $remotes = git remote
    if ($remotes -notcontains "paddle") {
        Write-Host "Fuege Remote 'paddle' zu OndselSolver hinzu..." -ForegroundColor Cyan
        git remote add paddle https://github.com/PaddleStroke/OndselSolver.git
    }

    $branchOutput = git branch --show-current
    $currentBranch = if ($branchOutput) { "$branchOutput".Trim() } else { "" }

    if ($currentBranch -ne $targetBranch) {
        Write-Host "OndselSolver ist nicht auf '$targetBranch' (aktuell: detached HEAD oder '$currentBranch')." -ForegroundColor Yellow
        Write-Host "Hole aktuellen Stand von paddle..." -ForegroundColor Cyan
        git fetch paddle --quiet
        Check-ExitCode "Git Fetch OndselSolver"
        
        git checkout $targetBranch --quiet 2>$null
        if ($LASTEXITCODE -ne 0) {
            git checkout -B $targetBranch "paddle/$targetBranch" --quiet
        }
        Check-ExitCode "Git Checkout OndselSolver ($targetBranch)"
        Write-Host "OndselSolver erfolgreich auf Branch '$targetBranch' gesetzt." -ForegroundColor Green
    } else {
        Write-Host "OndselSolver befindet sich bereits auf Branch: $targetBranch" -ForegroundColor Green
    }
}
finally {
    Pop-Location
}

# ==========================================
# 2. Kompilieren (Pixi)
# ==========================================
Write-Host "`nKonfiguriere ($buildType)..." -ForegroundColor Cyan
pixi run "configure-$buildType"
Check-ExitCode "CMake Konfiguration ($buildType)"

Write-Host "`nKompiliere ($buildType)..." -ForegroundColor Cyan
pixi run "build-$buildType"
Check-ExitCode "Kompilierung / Ninja Build ($buildType)"

# ==========================================
# 3. Staging-Verzeichnis vorbereiten (dist\release oder dist\debug)
# ==========================================
$distDir = ".\dist\$buildType"
if (-not (Test-Path -Path $distDir)) {
    New-Item -ItemType Directory -Path $distDir -Force | Out-Null
}
$distPath = (Resolve-Path $distDir).Path

Write-Host "`nInstalliere Binaries nach $distPath..." -ForegroundColor Cyan
pixi run cmake --install "build/$buildType" --prefix "$distPath"
Check-ExitCode "CMake Install nach $distPath"

Write-Host "Kopiere Laufzeitdateien, Qt-Plugins und Python..." -ForegroundColor Cyan

# DLLs & Qt-Plugins
Copy-Item -Path ".\.pixi\envs\default\Library\bin\*.dll" -Destination "$distDir\bin\" -Force
Copy-Item -Path ".\.pixi\envs\default\Library\lib\qt6\plugins\*" -Destination "$distDir\bin\" -Recurse -Force

# FreeCAD-Module und Daten
Copy-Item -Path ".\build\$buildType\Mod" -Destination "$distDir\" -Recurse -Force
Copy-Item -Path ".\build\$buildType\Ext" -Destination "$distDir\" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item -Path ".\build\$buildType\data" -Destination "$distDir\" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item -Path ".\build\$buildType\resources" -Destination "$distDir\" -Recurse -Force -ErrorAction SilentlyContinue

# Python-Laufzeitumgebung
Copy-Item -Path ".\.pixi\envs\default\Lib" -Destination "$distDir\" -Recurse -Force
Copy-Item -Path ".\.pixi\envs\default\python*.exe" -Destination "$distDir\bin\" -Force -ErrorAction SilentlyContinue
Copy-Item -Path ".\.pixi\envs\default\python*.dll" -Destination "$distDir\bin\" -Force -ErrorAction SilentlyContinue
Copy-Item -Path ".\.pixi\envs\default\DLLs" -Destination "$distDir\" -Recurse -Force
Copy-Item -Path ".\.pixi\envs\default\DLLs" -Destination "$distDir\bin\" -Recurse -Force

# ==========================================
# 4. Inno Setup Compiler ausführen
# ==========================================
$isccCandidates = @(
    (Get-Command iscc.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
)

$compiler = $isccCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

if ($compiler) {
    $outputName = "Astocad-Self-$buildType-Setup"
    Write-Host "`nErstelle Setup ($outputName) mit $compiler..." -ForegroundColor Green

    & $compiler "/DSourceDir=$distDir" "/F$outputName" '.\installer.iss'
    Check-ExitCode "Inno Setup Compiler"

    Write-Host "`n========================================================" -ForegroundColor Green
    Write-Host " Installer erfolgreich erstellt!" -ForegroundColor Green
    Write-Host " Datei: .\Installer-Output\$outputName.exe" -ForegroundColor Green
    Write-Host "========================================================" -ForegroundColor Green
} else {
    Write-Host "`n[FEHLER] ISCC.exe (Inno Setup) konnte nicht gefunden werden!" -ForegroundColor Red
    exit 1
}