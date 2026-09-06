# Артефакты рендеринга в Chromium / Electron приложениях на ноутбуках с гибридной графикой

> **Rendering artifacts in Chromium / Electron apps on hybrid-graphics laptops**
> [English version below](#english)

---

## Проблема

На ноутбуках с гибридной графикой (Intel iGPU + дискретная NVIDIA / AMD) в приложениях на движке Chromium появляются визуальные артефакты: линии, полосы и блочный «мусор», тянущиеся от элементов интерфейса.

**Характерные признаки:**

- Артефакты появляются сразу при запуске приложения
- Пропадают, если провести курсором мыши по затронутой области (принудительная перерисовка)
- Проявляются одновременно во **всех** Chromium-приложениях: Electron-программы (мессенджеры, редакторы кода, десктопные клиенты) и Chromium-браузеры
- Остаются на внешнем мониторе, а не только на встроенном экране
- Остаются в диагностическом и безопасном режиме Windows

**Затронутые конфигурации:**

| Компонент | Значение |
|---|---|
| ОС | Windows 11 (24H2 / 25H2 и новее) |
| Графика | Intel iGPU + дискретная GPU (Optimus / switchable graphics) |
| Приложения | Любые на движке Chromium (Electron, Chromium-браузеры) |

---

## Причина

Баг возникает на стыке трёх компонентов:

1. **DirectComposition** — механизм Windows, отвечающий за композицию (склейку) окон на экране
2. **Multi-Plane Overlay (MPO)** — аппаратное ускорение композиции через отдельные «плоскости» GPU
3. **Chromium** — использует DirectComposition для вывода своего содержимого

На гибридной графике рендеринг выполняется на одной видеокарте, а вывод на экран физически идёт через другую. В момент передачи кадра между адаптерами композитор не всегда корректно очищает буфер — старые пиксели остаются на экране. Курсор мыши инициирует перерисовку области, поэтому артефакты под ним исчезают.

Проблема известна с 2020 года, периодически исправляется и регрессирует в обновлениях Windows. Ответственность распределена между Microsoft, производителями GPU-драйверов и Chromium, из-за чего единого окончательного исправления до сих пор нет.

---

## Решение

### Способ 1. Системная политика Chromium (рекомендуется)

Chromium читает настройки из реестра Windows при каждом запуске. Это работает для **всех** Chromium-приложений сразу, не привязано к путям и версиям, и переживает обновления программ.

Выполнить в **PowerShell от имени администратора**:

```powershell
# Chrome и приложения, читающие политику Google Chrome
reg add "HKLM\SOFTWARE\Policies\Google\Chrome" /v "HardwareAccelerationModeEnabled" /t REG_DWORD /d 0 /f

# Microsoft Edge
reg add "HKLM\SOFTWARE\Policies\Microsoft\Edge" /v "HardwareAccelerationModeEnabled" /t REG_DWORD /d 0 /f

# Чистые сборки Chromium
reg add "HKLM\SOFTWARE\Policies\Chromium" /v "HardwareAccelerationModeEnabled" /t REG_DWORD /d 0 /f
```

Перезапустить приложения.

**Откат:**

```powershell
reg delete "HKLM\SOFTWARE\Policies\Google\Chrome" /v "HardwareAccelerationModeEnabled" /f
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Edge" /v "HardwareAccelerationModeEnabled" /f
reg delete "HKLM\SOFTWARE\Policies\Chromium" /v "HardwareAccelerationModeEnabled" /f
```

> **Важно:** этот способ отключает аппаратное ускорение целиком. WebGL и Canvas переходят на программный рендеринг (SwiftShader). Для большинства задач это незаметно, но если приложение зависит от GPU-рендеринга или от того, как оно определяется сайтами, используйте способ 2.

---

### Способ 2. Точечный флаг запуска

`--disable-direct-composition` отключает только проблемный композитор, оставляя остальное аппаратное ускорение (WebGL, Canvas, декодирование видео) рабочим.

**Для обычных приложений** — добавить флаг в ярлык:

ПКМ на ярлыке → **Свойства** → поле **Объект** → дописать в конец через пробел:

```
"C:\Path\To\App.exe" --disable-direct-composition
```

**Для приложений из Microsoft Store (MSIX/UWP)** — у них нет обычного пути к exe, нужен запуск через `shell:AppsFolder`. Создать ярлык с объектом:

```
powershell -WindowStyle Hidden -command "Start-Process (\"shell:AppsFolder\$((Get-AppxPackage *ИМЯ_ПРИЛОЖЕНИЯ*).PackageFamilyName)!ИДЕНТИФИКАТОР\") --disable-direct-composition"
```

Такой ярлык не привязан к номеру версии и переживает обновления приложения.

**Для приложений с полем пользовательских аргументов запуска** — вписать `--disable-direct-composition` в соответствующее поле настроек программы.

---

### Способ 3. Автоматизация для всех приложений сразу

Если способ 1 не подошёл, а приложений много, можно автоматизировать применение флага через **Image File Execution Options (IFEO)** — механизм Windows, перехватывающий запуск программы по имени исполняемого файла независимо от способа запуска.

Скрипт [`Auto-Fix-Chromium-All.ps1`](Auto-Fix-Chromium-All.ps1):

1. Сканирует систему и находит все Chromium-движки по универсальному отпечатку (`chrome_100_percent.pak` + папка `locales`)
2. Показывает список найденного
3. После подтверждения настраивает перехват запуска с нужным флагом

```powershell
# Запуск от имени администратора
.\Auto-Fix-Chromium-All.ps1
```

> **Ограничение:** при крупном обновлении приложения инсталлятор может восстановить оригинальное имя exe-файла и сбросить перехват. В этом случае скрипт нужно запустить повторно.

---

## Что не помогает

Эти методы часто советуют, но в описанном случае они не решают проблему:

| Метод | Результат |
|---|---|
| `OverlayTestMode = 5` в реестре (отключение MPO) | Не помогает |
| Отключение Hardware-accelerated GPU Scheduling | Не помогает |
| Отключение Variable Refresh Rate / Auto HDR | Не помогает |
| Откат или обновление драйвера видеокарты | Не помогает |
| Установка последних обновлений Windows | Не помогает |
| Установка приоритета дискретной GPU в панели драйвера | Не помогает |
| Утилиты пакетного отключения MPO | Не помогают |
| Отключение iGPU в BIOS / диспетчере устройств | Недоступно или опасно на ноутбуках без MUX-переключателя — экран может погаснуть |

---

## Диагностика

Чтобы убедиться, что проблема именно эта:

1. **Проверить внешний монитор.** Если артефакты видны и на нём — проблема программная, а не в матрице ноутбука
2. **Загрузиться в безопасном режиме.** Если артефакты остались — дело не в фоновых программах и не в проприетарном драйвере
3. **Проверить не-Chromium приложения.** Если артефакты только в Chromium-приложениях, а в обычных окнах Windows их нет — диагноз подтверждён

---

<a name="english"></a>

# English

## Problem

On laptops with hybrid graphics (Intel iGPU + discrete NVIDIA / AMD), Chromium-based applications display visual artifacts: lines, streaks, and blocky garbage trailing from interface elements.

**Symptoms:**

- Artifacts appear immediately on application launch
- They disappear when the mouse cursor passes over the affected area (forced repaint)
- They occur simultaneously across **all** Chromium applications: Electron apps (messengers, code editors, desktop clients) and Chromium browsers
- They persist on an external monitor, not just the built-in display
- They persist in Windows Safe Mode and Diagnostic Startup

**Affected configurations:**

| Component | Value |
|---|---|
| OS | Windows 11 (24H2 / 25H2 and newer) |
| Graphics | Intel iGPU + discrete GPU (Optimus / switchable graphics) |
| Applications | Anything built on Chromium (Electron, Chromium browsers) |

---

## Root cause

The bug lives at the intersection of three components:

1. **DirectComposition** — the Windows mechanism responsible for compositing windows on screen
2. **Multi-Plane Overlay (MPO)** — hardware-accelerated composition using separate GPU planes
3. **Chromium** — uses DirectComposition to present its content

On hybrid graphics, rendering happens on one GPU while display output physically goes through another. When a frame is handed between adapters, the compositor does not always clear the buffer correctly, leaving stale pixels on screen. Moving the mouse cursor triggers a repaint of that region, which is why artifacts vanish under the cursor.

The issue has been reported since 2020 and has been fixed and regressed repeatedly across Windows updates. Responsibility is split between Microsoft, GPU driver vendors, and Chromium, which is why no single permanent fix exists.

---

## Solution

### Option 1. Chromium system policy (recommended)

Chromium reads settings from the Windows registry on every launch. This applies to **all** Chromium applications at once, is not tied to install paths or versions, and survives application updates.

Run in **PowerShell as Administrator**:

```powershell
# Chrome and applications reading the Google Chrome policy branch
reg add "HKLM\SOFTWARE\Policies\Google\Chrome" /v "HardwareAccelerationModeEnabled" /t REG_DWORD /d 0 /f

# Microsoft Edge
reg add "HKLM\SOFTWARE\Policies\Microsoft\Edge" /v "HardwareAccelerationModeEnabled" /t REG_DWORD /d 0 /f

# Vanilla Chromium builds
reg add "HKLM\SOFTWARE\Policies\Chromium" /v "HardwareAccelerationModeEnabled" /t REG_DWORD /d 0 /f
```

Restart the applications.

**Rollback:**

```powershell
reg delete "HKLM\SOFTWARE\Policies\Google\Chrome" /v "HardwareAccelerationModeEnabled" /f
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Edge" /v "HardwareAccelerationModeEnabled" /f
reg delete "HKLM\SOFTWARE\Policies\Chromium" /v "HardwareAccelerationModeEnabled" /f
```

> **Note:** this disables hardware acceleration entirely. WebGL and Canvas fall back to software rendering (SwiftShader). This is unnoticeable for most workloads, but if an application depends on GPU rendering — or on how it is detected by websites — use Option 2 instead.

---

### Option 2. Targeted launch flag

`--disable-direct-composition` disables only the problematic compositor, leaving the rest of hardware acceleration (WebGL, Canvas, video decoding) intact.

**For regular applications** — add the flag to the shortcut:

Right-click the shortcut → **Properties** → **Target** field → append after a space:

```
"C:\Path\To\App.exe" --disable-direct-composition
```

**For Microsoft Store (MSIX/UWP) applications** — these have no conventional exe path and must be launched via `shell:AppsFolder`. Create a shortcut with this target:

```
powershell -WindowStyle Hidden -command "Start-Process (\"shell:AppsFolder\$((Get-AppxPackage *APP_NAME*).PackageFamilyName)!APP_ID\") --disable-direct-composition"
```

This shortcut is not tied to a version number and survives application updates.

**For applications with a custom launch arguments field** — enter `--disable-direct-composition` in the relevant settings field.

---

### Option 3. Automating the flag across all applications

If Option 1 is unsuitable and there are many applications, the flag can be applied automatically via **Image File Execution Options (IFEO)** — a Windows mechanism that intercepts process launch by executable name, regardless of how it was started.

The [`Auto-Fix-Chromium-All.ps1`](Auto-Fix-Chromium-All.ps1) script:

1. Scans the system for all Chromium engines using a universal fingerprint (`chrome_100_percent.pak` + `locales` folder)
2. Displays what it found
3. Sets up launch interception with the flag after confirmation

```powershell
# Run as Administrator
.\Auto-Fix-Chromium-All.ps1
```

> **Limitation:** a major application update may restore the original executable name and reset the interception. Re-run the script if this happens.

---

## What does not work

These are commonly suggested but do not resolve the issue in this scenario:

| Method | Result |
|---|---|
| `OverlayTestMode = 5` registry key (disabling MPO) | No effect |
| Disabling Hardware-accelerated GPU Scheduling | No effect |
| Disabling Variable Refresh Rate / Auto HDR | No effect |
| Rolling back or updating GPU drivers | No effect |
| Installing the latest Windows updates | No effect |
| Setting the discrete GPU as preferred in the driver panel | No effect |
| Batch MPO-disabling utilities | No effect |
| Disabling the iGPU in BIOS / Device Manager | Unavailable or dangerous on laptops without a MUX switch — the display may go dark |

---

## Diagnostics

To confirm this is the issue you are facing:

1. **Check an external monitor.** If artifacts appear there too, the problem is software-side, not the laptop panel
2. **Boot into Safe Mode.** If artifacts persist, background software and proprietary drivers are not the cause
3. **Check non-Chromium applications.** If only Chromium apps are affected while regular Windows windows are clean, the diagnosis is confirmed

---

## License

MIT
