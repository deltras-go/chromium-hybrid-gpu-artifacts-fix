#Requires -RunAsAdministrator
<#
  Auto-Fix-Chromium-All.ps1

  Находит АБСОЛЮТНО ЛЮБЫЕ Chromium-based приложения в системе:
  - Обычные Electron-приложения (Claude, Cursor, VS Code, Telegram...)
  - "Голые" Chromium-движки без Electron (ядра AdsPower/SunBrowser, другие антидетект-браузеры)

  Отпечаток: наличие связки файлов chrome_100_percent.pak + папка locales
  Это есть у ЛЮБОГО Chromium-движка, независимо от того как называется программа.

  Можно запускать повторно в любой момент — например, после того как
  AdsPower скачал новую версию ядра. Скрипт сам найдёт новые файлы
  и добавит фикс, не трогая уже настроенные.

  Запускать от администратора.
#>

$ErrorActionPreference = "SilentlyContinue"
$flag = "--disable-direct-composition"
$stubDir = "C:\GPUFixStubs"
New-Item -ItemType Directory -Path $stubDir -Force | Out-Null

Write-Host "=== Полное сканирование системы на ЛЮБЫЕ Chromium-движки ===" -ForegroundColor Magenta
Write-Host "(это может занять 3-7 минут, т.к. ищем везде, включая профили антидетект-браузеров)`n"

# Расширенный список корней поиска — включая типичные места хранения
# кэшей/ядер антидетект-браузеров
$searchRoots = @(
    "$env:LOCALAPPDATA\Programs",
    "$env:LOCALAPPDATA",
    "$env:APPDATA",
    "C:\Program Files",
    "C:\Program Files (x86)",
    "$env:USERPROFILE\AppData\Local"
) | Select-Object -Unique

$found = @{}
$processedDirs = New-Object System.Collections.Generic.HashSet[string]

foreach ($root in $searchRoots) {
    if (-not (Test-Path $root)) { continue }

    Write-Host "Сканирую: $root ..." -ForegroundColor DarkGray

    # Ищем "locales" папки как якорь — они почти всегда рядом с движком
    $localesDirs = Get-ChildItem -Path $root -Recurse -Depth 6 -Directory -Filter "locales" -ErrorAction SilentlyContinue

    foreach ($localesDir in $localesDirs) {
        $engineDir = $localesDir.Parent
        if ($null -eq $engineDir) { continue }
        if ($processedDirs.Contains($engineDir.FullName)) { continue }
        $processedDirs.Add($engineDir.FullName) | Out-Null

        # Подтверждаем что это реально Chromium-движок, а не случайная папка locales
        $hasPak = Test-Path (Join-Path $engineDir.FullName "chrome_100_percent.pak")
        $hasIcudtl = Test-Path (Join-Path $engineDir.FullName "icudtl.dat")

        if (-not ($hasPak -or $hasIcudtl)) { continue }

        # Ищем главный исполняемый файл в этой папке
        $candidateExes = Get-ChildItem -Path $engineDir.FullName -Filter "*.exe" -File -ErrorAction SilentlyContinue |
                          Where-Object {
                              $_.Name -notmatch "^Update\.exe$" -and
                              $_.Name -notmatch "uninstall" -and
                              $_.Name -notmatch "elevate" -and
                              $_.Name -notmatch "crashpad" -and
                              $_.Name -notmatch "chrome_proxy"
                          } |
                          Sort-Object Length -Descending  # самый большой exe обычно главный

        foreach ($exe in $candidateExes) {
            if (-not $found.ContainsKey($exe.Name)) {
                $found[$exe.Name] = $exe.FullName
            }
        }
    }
}

if ($found.Count -eq 0) {
    Write-Host "`nНичего не найдено." -ForegroundColor Yellow
    exit
}

Write-Host "`nНайдено Chromium-движков: $($found.Count)`n" -ForegroundColor Green
$i = 1
$foundList = @()
foreach ($key in $found.Keys) {
    Write-Host "  $i. $key  ->  $($found[$key])"
    $foundList += [PSCustomObject]@{ Name = $key; Path = $found[$key] }
    $i++
}

Write-Host "`nПрименить фикс ($flag) ко ВСЕМ найденным? (Y/N)" -ForegroundColor Cyan
$confirm = Read-Host
if ($confirm -notmatch "^[YyДд]") {
    Write-Host "Отменено." -ForegroundColor Yellow
    exit
}

function Install-Hook {
    param([string]$ExeName, [string]$RealPath)

    $dir = Split-Path $RealPath -Parent
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($ExeName)
    $ext = [System.IO.Path]::GetExtension($ExeName)
    $realRenamedPath = Join-Path $dir "$baseName.real$ext"

    if (Test-Path $realRenamedPath) {
        Write-Host "[УЖЕ НАСТРОЕНО] $ExeName" -ForegroundColor Cyan
        return
    }

    try {
        Rename-Item -Path $RealPath -NewName "$baseName.real$ext" -Force -ErrorAction Stop
    } catch {
        Write-Host "[ОШИБКА переименования] $ExeName : $_" -ForegroundColor Red
        return
    }

    $stubScript = Join-Path $stubDir "$baseName-stub.ps1"
    $stubContent = "Start-Process -FilePath '$realRenamedPath' -ArgumentList '$flag'"
    Set-Content -Path $stubScript -Value $stubContent -Encoding UTF8

    $ifeoPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$ExeName"
    if (-not (Test-Path $ifeoPath)) { New-Item -Path $ifeoPath -Force | Out-Null }
    $debuggerCmd = "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$stubScript`""
    Set-ItemProperty -Path $ifeoPath -Name "Debugger" -Value $debuggerCmd

    Write-Host "[OK] $ExeName" -ForegroundColor Green
}

Write-Host "`n=== Применяю фикс ===`n" -ForegroundColor Magenta
foreach ($app in $foundList) {
    Install-Hook -ExeName $app.Name -RealPath $app.Path
}

Write-Host "`n=== Готово. Все найденные Chromium-движки теперь запускаются с фиксом автоматически. ===" -ForegroundColor Magenta
Write-Host "Это касается ЛЮБОГО способа запуска — вручную, через ярлык, через API/автоматизацию (например AdsPower Local API)."
Write-Host "`nЕсли появятся новые версии/ядра — просто запусти этот скрипт ещё раз, он найдёт и добавит только новое." -ForegroundColor Yellow
