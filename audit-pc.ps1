# =====================================================================
#  AUDIT PC - LECTURE SEULE
#  Ce script ne modifie RIEN sur le systeme : il lit des informations
#  (WMI/CIM, registre en lecture, versions des outils) et ecrit
#  uniquement un rapport texte sur le Bureau : audit-pc.txt
#
#  Lancement (PowerShell en ADMIN recommande pour la sante des disques) :
#     powershell -ExecutionPolicy Bypass -File .\audit-pc.ps1
# =====================================================================

$ErrorActionPreference = 'SilentlyContinue'
$out = Join-Path ([Environment]::GetFolderPath('Desktop')) 'audit-pc.txt'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Section($t) { "`n==================== $t ====================" }
function GB($b) { [math]::Round($b / 1GB, 1) }

Write-Host 'Audit en cours (30-60 s)...' -ForegroundColor Cyan

& {
"AUDIT PC - $(Get-Date -Format 'yyyy-MM-dd HH:mm') - Admin: $isAdmin"

# ---------------------------------------------------------------- 1
Section '1. SYSTEME'
$os = Get-CimInstance Win32_OperatingSystem
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$cs = Get-CimInstance Win32_ComputerSystem
[pscustomobject]@{
    Machine      = $env:COMPUTERNAME
    OS           = $os.Caption
    Edition      = $cv.EditionID
    Version      = $cv.DisplayVersion
    Build        = "$($os.BuildNumber).$($cv.UBR)"
    Architecture = $os.OSArchitecture
    Fabricant    = $cs.Manufacturer
    Modele       = $cs.Model
    TypeChassis  = ((Get-CimInstance Win32_SystemEnclosure).ChassisTypes -join ',')  # 3-7=desktop, 8-14/31=portable
    DernierBoot  = $os.LastBootUpTime
    PlanAlim     = (powercfg /getactivescheme) -join ''
} | Format-List

# ---------------------------------------------------------------- 2
Section '2. PROCESSEUR'
Get-CimInstance Win32_Processor | Select-Object Name, Manufacturer, NumberOfCores,
    NumberOfLogicalProcessors, @{n='FreqBase_MHz';e={$_.MaxClockSpeed}},
    @{n='FreqActuelle_MHz';e={$_.CurrentClockSpeed}}, L2CacheSize, L3CacheSize,
    VirtualizationFirmwareEnabled | Format-List

# ---------------------------------------------------------------- 3
Section '3. RAM'
$ramType = @{20='DDR';21='DDR2';24='DDR3';26='DDR4';34='DDR5';35='LPDDR5'}
$mods = Get-CimInstance Win32_PhysicalMemory
$slots = (Get-CimInstance Win32_PhysicalMemoryArray | Measure-Object MemoryDevices -Sum).Sum
"Total installe : $(GB ($mods | Measure-Object Capacity -Sum).Sum) Go"
"Barrettes      : $($mods.Count)  /  Slots totaux : $slots  /  Slots libres : $($slots - $mods.Count)"
$mods | Select-Object DeviceLocator, BankLabel, @{n='Go';e={GB $_.Capacity}},
    @{n='Type';e={ $t = $ramType[[int]$_.SMBIOSMemoryType]; if ($t) { $t } else { "code $($_.SMBIOSMemoryType)" } }},
    @{n='Freq_Max';e={$_.Speed}}, @{n='Freq_Config';e={$_.ConfiguredClockSpeed}},
    Manufacturer, PartNumber, FormFactor | Format-Table -AutoSize

# ---------------------------------------------------------------- 4
Section '4. CARTE GRAPHIQUE'
$gpuReg = Get-ItemProperty 'HKLM:\SYSTEM\ControlSet001\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0*'
Get-CimInstance Win32_VideoController | ForEach-Object {
    $name = $_.Name
    $reg = $gpuReg | Where-Object { $_.DriverDesc -eq $name } | Select-Object -First 1
    $vram = if ($reg.'HardwareInformation.qwMemorySize') { GB ([uint64]$reg.'HardwareInformation.qwMemorySize') } else { GB $_.AdapterRAM }
    [pscustomobject]@{
        Nom = $name; VRAM_Go = $vram; Driver = $_.DriverVersion
        DateDriver = $_.DriverDate; Resolution = "$($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)"
        Hz = $_.CurrentRefreshRate
    }
} | Format-List
if (Get-Command nvidia-smi) {
    'nvidia-smi :'
    nvidia-smi --query-gpu=name,memory.total,memory.used,driver_version,temperature.gpu,utilization.gpu --format=csv
}

# ---------------------------------------------------------------- 5
Section '5. STOCKAGE'
Get-PhysicalDisk | ForEach-Object {
    $r = $_ | Get-StorageReliabilityCounter
    [pscustomobject]@{
        Disque = $_.FriendlyName; Type = $_.MediaType; Bus = $_.BusType
        Taille_Go = GB $_.Size; Sante = $_.HealthStatus; Etat = $_.OperationalStatus
        Usure_pct = $r.Wear; Temp_C = $r.Temperature; HeuresOn = $r.PowerOnHours
        ErreursLecture = $r.ReadErrorsUncorrected
    }
} | Format-Table -AutoSize
if (-not $isAdmin) { '(Usure/Temp/Heures vides = relancer en admin)' }
'Volumes :'
Get-Volume | Where-Object { $_.DriveLetter } | Select-Object DriveLetter, FileSystemLabel, FileSystem,
    @{n='Taille_Go';e={GB $_.Size}}, @{n='Libre_Go';e={GB $_.SizeRemaining}},
    @{n='Libre_pct';e={ if ($_.Size) { [math]::Round(100 * $_.SizeRemaining / $_.Size) } }},
    HealthStatus | Format-Table -AutoSize

# ---------------------------------------------------------------- 6
Section '6. CARTE MERE / BIOS'
$bb = Get-CimInstance Win32_BaseBoard; $bios = Get-CimInstance Win32_BIOS
[pscustomobject]@{
    Fabricant = $bb.Manufacturer; Modele = $bb.Product; Revision = $bb.Version
    BIOS = $bios.SMBIOSBIOSVersion; BIOS_Editeur = $bios.Manufacturer; BIOS_Date = $bios.ReleaseDate
    ModeBoot = $env:firmware_type
} | Format-List

# ---------------------------------------------------------------- 7
Section '7. ECRANS'
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System; using System.Runtime.InteropServices;
public class AuditDisp {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
    public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra; public int dmFields;
    public int dmPositionX; public int dmPositionY; public int dmDisplayOrientation; public int dmDisplayFixedOutput;
    public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
    public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight;
    public int dmDisplayFlags; public int dmDisplayFrequency; public int dmICMMethod; public int dmICMIntent;
    public int dmMediaType; public int dmDitherType; public int dmReserved1; public int dmReserved2; public int dmPanningWidth; public int dmPanningHeight;
  }
  [DllImport("user32.dll", CharSet=CharSet.Ansi)]
  public static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref AuditDisp.DEVMODE devMode);
}
'@
$screens = [System.Windows.Forms.Screen]::AllScreens
"Nombre d'ecrans : $($screens.Count)"
foreach ($s in $screens) {
    $dm = New-Object AuditDisp+DEVMODE; $dm.dmSize = [Runtime.InteropServices.Marshal]::SizeOf($dm)
    [void][AuditDisp]::EnumDisplaySettings($s.DeviceName, -1, [ref]$dm)
    $w = $dm.dmPelsWidth; $h = $dm.dmPelsHeight; $cur = $dm.dmDisplayFrequency
    # frequence max supportee a cette resolution (detecte un 144 Hz bride a 60 Hz)
    $max = 0; $i = 0; $m = New-Object AuditDisp+DEVMODE; $m.dmSize = $dm.dmSize
    while ([AuditDisp]::EnumDisplaySettings($s.DeviceName, $i, [ref]$m)) {
        if ($m.dmPelsWidth -eq $w -and $m.dmPelsHeight -eq $h -and $m.dmDisplayFrequency -gt $max) { $max = $m.dmDisplayFrequency }
        $i++
    }
    "{0}  {1}x{2} @ {3} Hz (max supporte : {4} Hz)  Principal={5}" -f $s.DeviceName, $w, $h, $cur, $max, $s.Primary
}
Get-CimInstance -Namespace root\wmi WmiMonitorID | ForEach-Object {
    $n = ($_.UserFriendlyName | Where-Object { $_ -gt 0 } | ForEach-Object { [char]$_ }) -join ''
    $f = ($_.ManufacturerName | Where-Object { $_ -gt 0 } | ForEach-Object { [char]$_ }) -join ''
    "Moniteur : $f $n (annee $($_.YearOfManufacture))"
}

# ---------------------------------------------------------------- 8
Section '8. RESEAU'
Get-NetAdapter -Physical | Select-Object Name, InterfaceDescription, Status, LinkSpeed, MediaType, MacAddress | Format-Table -AutoSize
'Wi-Fi :'
netsh wlan show interfaces | Select-String 'Description|SSID|Radio|Bande|Band|Canal|Channel|Reception|Receive|Transmission|Transmit|Signal' | ForEach-Object { $_.Line.Trim() }

# ---------------------------------------------------------------- 9
Section '9. LOGICIELS DEV'
$tools = [ordered]@{
    'Node.js'='node -v'; 'npm'='npm -v'; 'pnpm'='pnpm -v'; 'yarn'='yarn -v'; 'bun'='bun -v'; 'deno'='deno -v'
    'Python'='python --version'; 'py launcher'='py --version'; 'pip'='pip --version'; 'Git'='git --version'
    'GitHub CLI'='gh --version'; 'VS Code'='code --version'; 'Cursor'='cursor --version'; 'Claude Code'='claude --version'
    'Docker'='docker --version'; 'WSL'='wsl --version'; 'Java'='java -version'; '.NET'='dotnet --version'
    'Go'='go version'; 'Rust'='rustc --version'; 'FFmpeg'='ffmpeg -version'; 'PowerShell 7'='pwsh -v'
}
foreach ($k in $tools.Keys) {
    $exe = $tools[$k].Split(' ')[0]
    if (Get-Command $exe) {
        $v = (cmd /c "$($tools[$k]) 2>&1" | Select-Object -First 1) -replace '\x00', ''
        "{0,-14} {1}" -f $k, $v
    } else { "{0,-14} (absent)" -f $k }
}
'Logiciels video/creation installes :'
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' |
    Where-Object { $_.DisplayName -match 'Premiere|After Effects|DaVinci|CapCut|Photoshop|Media Encoder|Final Cut|Vegas|Filmora|OBS|Handbrake|Chrome|Edge|Brave|Firefox|AdsPower|GoLogin|Multilogin|Dolphin' } |
    Select-Object DisplayName, DisplayVersion -Unique | Sort-Object DisplayName | Format-Table -AutoSize

# ---------------------------------------------------------------- 10
Section '10. PERFORMANCE (instantane)'
$cpu = (1..3 | ForEach-Object { (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime; Start-Sleep 1 } | Measure-Object -Average).Average
$os = Get-CimInstance Win32_OperatingSystem
$tot = $os.TotalVisibleMemorySize * 1KB; $free = $os.FreePhysicalMemory * 1KB
"CPU moyen (3 s)  : $([math]::Round($cpu)) %"
"RAM utilisee     : $(GB ($tot - $free)) / $(GB $tot) Go ($([math]::Round(100 * ($tot - $free) / $tot)) %)"
"Fichier d'echange: $((Get-CimInstance Win32_PageFileUsage | ForEach-Object { "$($_.Name) $($_.CurrentUsage)/$($_.AllocatedBaseSize) Mo" }) -join ' ; ')"
'Activite disques :'
Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk | Where-Object Name -ne '_Total' |
    Select-Object Name, PercentDiskTime, AvgDiskQueueLength, DiskReadBytesPersec, DiskWriteBytesPersec | Format-Table -AutoSize
'Top 15 processus par RAM :'
Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 15 Name, Id,
    @{n='RAM_Mo';e={[math]::Round($_.WorkingSet64 / 1MB)}}, @{n='CPU_s';e={[math]::Round($_.CPU)}} | Format-Table -AutoSize
'RAM cumulee par application (navigateurs, etc.) :'
Get-Process | Group-Object Name | ForEach-Object {
    [pscustomobject]@{ App = $_.Name; Processus = $_.Count; RAM_Mo = [math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB) }
} | Sort-Object RAM_Mo -Descending | Select-Object -First 10 | Format-Table -AutoSize
'Programmes au demarrage :'
Get-CimInstance Win32_StartupCommand | Select-Object Name, Command, Location | Format-Table -AutoSize -Wrap
'Taches planifiees au logon (hors Microsoft) :'
Get-ScheduledTask | Where-Object { $_.State -ne 'Disabled' -and $_.TaskPath -notlike '\Microsoft\*' -and ($_.Triggers | Where-Object { $_.CimClass.CimClassName -match 'Logon|Boot' }) } |
    Select-Object TaskName, TaskPath | Format-Table -AutoSize
"Nombre de processus : $((Get-Process).Count)"

} | Out-String -Width 300 | Tee-Object -FilePath $out

Write-Host "`nRapport enregistre : $out" -ForegroundColor Green
Write-Host 'Copie-colle son contenu a Claude pour obtenir l''analyse.' -ForegroundColor Green
