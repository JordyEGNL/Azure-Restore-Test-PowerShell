#Requires -Modules Az.Accounts, Az.Resources, Az.Network, Az.Storage, Az.Compute, Az.RecoveryServices

# ============================================================
#  Azure VM restore automation
#  Doel   : Herstelomgeving klaarzetten + VM-restore begeleiden
#  Gebruik: Voer uit als: .\Restore-AzureVM.ps1
# ============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────
# HELPFUNCTIES
# ─────────────────────────────────────────────────────────────

function Write-Header {
    param([string]$Text)
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step {
    param([string]$Text)
    Write-Host "  ► $Text" -ForegroundColor Yellow
}

function Write-OK {
    param([string]$Text)
    Write-Host "  ✔ $Text" -ForegroundColor Green
}

function Write-Info {
    param([string]$Text)
    Write-Host "  ℹ $Text" -ForegroundColor White
}

# ─────────────────────────────────────────────────────────────
# STAP 1 – LOGIN EN SUBSCRIPTION SELECTIE
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 0 - Huidige Azure credentials uitloggen"

Disconnect-AzAccount

Write-Header "STAP 1 – Azure Login"

Write-Step "Inloggen bij Azure... (inlogscherm kan verstopt zijn achter het huidige venster)"
Connect-AzAccount | Out-Null
Write-OK "Succesvol ingelogd."

# Haal alle subscriptions op
$allSubs = Get-AzSubscription | Sort-Object Name
if ($allSubs.Count -eq 0) {
    Write-Error "Geen subscriptions gevonden voor dit account."
    exit 1
}

# Bepaal standaard index op basis van *Recovery* in de naam
$defaultSubIndex = 1
for ($i = 0; $i -lt $allSubs.Count; $i++) {
    if ($allSubs[$i].Name -like "*Recovery*") {
        $defaultSubIndex = $i + 1
        break
    }
}

Write-Host ""
Write-Host "  Beschikbare subscriptions:" -ForegroundColor Cyan
for ($i = 0; $i -lt $allSubs.Count; $i++) {
    $marker = if (($i + 1) -eq $defaultSubIndex) { "  ← standaard" } else { "" }
    Write-Host ("  [{0,2}] {1}{2}" -f ($i + 1), $allSubs[$i].Name, $marker) -ForegroundColor White
}
Write-Host ""
$subChoice = Read-Host "  Kies subscriptienummer (Enter = $defaultSubIndex)"
if ([string]::IsNullOrWhiteSpace($subChoice)) { $subChoice = $defaultSubIndex }
$selectedSub = $allSubs[[int]$subChoice - 1]
# Zet context direct — geen tweede keuze meer nodig verderop
Set-AzContext -SubscriptionId $selectedSub.Id | Out-Null
Write-OK "Ingelogd en subscription ingesteld: $($selectedSub.Name)"

# ─────────────────────────────────────────────────────────────
# STAP 2 – GEBRUIKERSINVOER
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 2 – Invoer gegevens"

# ── Klantnaam ─────────────────────────────────────────────────
do {
    $CustomerName = (Read-Host "  Klantnaam (geen spaties of speciale tekens, bijv. Contoso)").Trim()
    if ([string]::IsNullOrWhiteSpace($CustomerName)) {
        Write-Host "  ⚠ Klantnaam mag niet leeg zijn." -ForegroundColor Red
    } elseif ($CustomerName -notmatch '^[a-zA-Z0-9]+$') {
        Write-Host "  ⚠ Alleen letters en cijfers toegestaan, geen spaties of speciale tekens." -ForegroundColor Red
        $CustomerName = ""
    }
} while ([string]::IsNullOrWhiteSpace($CustomerName))
Write-OK "Klantnaam: $CustomerName"

# ── Ticketnummer ──────────────────────────────────────────────
do {
    $TicketNumber = (Read-Host "  Ticketnummer (bijv. OT2606-01234)").Trim()
    if ([string]::IsNullOrWhiteSpace($TicketNumber)) {
        Write-Host "  ⚠ Ticketnummer mag niet leeg zijn." -ForegroundColor Red
    } elseif ($TicketNumber -notmatch '^[a-zA-Z0-9\-]+$') {
        Write-Host "  ⚠ Ticketnummer mag alleen letters, cijfers en koppeltekens bevatten." -ForegroundColor Red
        $TicketNumber = ""
    }
} while ([string]::IsNullOrWhiteSpace($TicketNumber))
Write-OK "Ticketnummer: $TicketNumber"

# ── DC-naam (uit VM-lijst of handmatig) ───────────────────────
Write-Step "Huidige VM's ophalen uit alle subscriptions..."
$allVMs = @()
foreach ($sub in $allSubs) {
    try {
        Set-AzContext -SubscriptionId $sub.Id -ErrorAction SilentlyContinue | Out-Null
        $vms = Get-AzVM -ErrorAction SilentlyContinue
        foreach ($vm in $vms) {
            $allVMs += [PSCustomObject]@{
                Name          = $vm.Name
                ResourceGroup = $vm.ResourceGroupName
                Subscription  = $sub.Name
                Location      = $vm.Location
            }
        }
    } catch { }
}
Set-AzContext -SubscriptionId $selectedSub.Id | Out-Null

if ($allVMs.Count -gt 0) {
    Write-Host ""
    Write-Host "  Gevonden VM's:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $allVMs.Count; $i++) {
        Write-Host ("  [{0,2}] {1,-35} Sub: {2}" -f ($i + 1), $allVMs[$i].Name, $allVMs[$i].Subscription) -ForegroundColor White
    }
    Write-Host ""
    do {
        $vmChoice = (Read-Host "  Nummer van te restoren Domain Controller (of typ naam handmatig)").Trim()
        if ([string]::IsNullOrWhiteSpace($vmChoice)) {
            Write-Host "  ⚠ Keuze mag niet leeg zijn." -ForegroundColor Red
        } elseif ($vmChoice -match '^\d+$') {
            if ([int]$vmChoice -lt 1 -or [int]$vmChoice -gt $allVMs.Count) {
                Write-Host "  ⚠ Kies een nummer tussen 1 en $($allVMs.Count)." -ForegroundColor Red
                $vmChoice = ""
            } else {
                $DCName = $allVMs[[int]$vmChoice - 1].Name
            }
        } else {
            if ($vmChoice -notmatch '^[a-zA-Z0-9\-]+$') {
                Write-Host "  ⚠ VM-naam mag alleen letters, cijfers en koppeltekens bevatten." -ForegroundColor Red
                $vmChoice = ""
            } else {
                $DCName = $vmChoice
            }
        }
    } while ([string]::IsNullOrWhiteSpace($vmChoice))
} else {
    Write-Host "  ℹ Geen VM's gevonden of geen toegang. Typ de naam handmatig." -ForegroundColor Yellow
    do {
        $DCName = (Read-Host "  Naam van de te restoren Domain Controller").Trim()
        if ([string]::IsNullOrWhiteSpace($DCName)) {
            Write-Host "  ⚠ Naam mag niet leeg zijn." -ForegroundColor Red
        } elseif ($DCName -notmatch '^[a-zA-Z0-9\-]+$') {
            Write-Host "  ⚠ VM-naam mag alleen letters, cijfers en koppeltekens bevatten." -ForegroundColor Red
            $DCName = ""
        }
    } while ([string]::IsNullOrWhiteSpace($DCName))
}
Write-OK "Domain Controller: $DCName"

# ── Volledige naam (CreatedBy) ────────────────────────────────
do {
    $CreatedByName = (Read-Host "  Jouw volledige naam (voor de CreatedBy-tag, bijv. Jan de Vries)").Trim()
    if ([string]::IsNullOrWhiteSpace($CreatedByName)) {
        Write-Host "  ⚠ Naam mag niet leeg zijn." -ForegroundColor Red
    } elseif ($CreatedByName -notmatch '^[a-zA-Z\s\-\.]+$') {
        Write-Host "  ⚠ Naam mag alleen letters, spaties, koppeltekens en punten bevatten." -ForegroundColor Red
        $CreatedByName = ""
    } elseif ($CreatedByName.Length -lt 2) {
        Write-Host "  ⚠ Naam is te kort." -ForegroundColor Red
        $CreatedByName = ""
    }
} while ([string]::IsNullOrWhiteSpace($CreatedByName))
Write-OK "CreatedBy: $CreatedByName"

# ── Regio ─────────────────────────────────────────────────────
# Geldige Azure-regio's (meest gebruikte westeurope-gerelateerd en NL)
$validRegions = @(
    "westeurope", "northeurope", "eastus", "eastus2", "westus", "westus2",
    "centralus", "northcentralus", "southcentralus", "westcentralus",
    "uksouth", "ukwest", "francecentral", "francesouth",
    "germanywestcentral", "germanynorth", "switzerlandnorth", "switzerlandwest",
    "norwayeast", "norwaywest", "swedencentral", "swedensouth",
    "southeastasia", "eastasia", "australiaeast", "australiasoutheast",
    "brazilsouth", "canadacentral", "canadaeast", "japaneast", "japanwest",
    "koreacentral", "koreasouth", "southafricanorth", "southafricawest",
    "uaenorth", "uaecentral", "israelcentral", "polandcentral",
    "italynorth", "spaincentral"
)

$defaultRegion = "westeurope"
Write-Host ""
Write-Host "  Veelgebruikte regio's:" -ForegroundColor Cyan
Write-Host "  westeurope, northeurope, uksouth, germanywestcentral, francecentral" -ForegroundColor White
Write-Host ""

do {
    $RegionInput = (Read-Host "  Regio (Enter = $defaultRegion)").Trim().ToLower()
    if ([string]::IsNullOrWhiteSpace($RegionInput)) {
        $Region = $defaultRegion
    } elseif ($RegionInput -notmatch '^[a-z0-9]+$') {
        Write-Host "  ⚠ Regio mag alleen kleine letters en cijfers bevatten (bijv. westeurope)." -ForegroundColor Red
        $RegionInput = $null
    } elseif ($RegionInput -notin $validRegions) {
        Write-Host "  ⚠ '$RegionInput' is geen bekende Azure-regio. Controleer de naam en probeer opnieuw." -ForegroundColor Red
        Write-Host "    Tip: zie https://aka.ms/azureregions voor alle regio's." -ForegroundColor DarkGray
        $RegionInput = $null
    } else {
        $Region = $RegionInput
    }
} while ($null -eq $RegionInput)
Write-OK "Regio: $Region"

# ─────────────────────────────────────────────────────────────
# VARIABELEN AFLEIDEN
# ─────────────────────────────────────────────────────────────

$ResourceGroupName  = "RG-Restore-Test-$TicketNumber"
$NSGName            = "$CustomerName-Restore-Test-NSG"
$StorageAccountName = ("rgrestoretest$TicketNumber" -replace '[^a-z0-9]', '').ToLower()
if ($StorageAccountName.Length -gt 24) { $StorageAccountName = $StorageAccountName.Substring(0, 24) }
$VNetName           = "$CustomerName-Restore-Test-VNET"
$SubnetName         = "default"
$PIPName            = "$CustomerName-Restore-Test-PIP"
$VMRestoreName      = "$CustomerName-Restore-Test-$DCName"

$Tags = @{
    Omgeving         = "Restore"
    CreatedBy        = "$CreatedByName"
}

Write-Host ""
Write-Host "  ─────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  SAMENVATTING INVOER" -ForegroundColor Cyan
Write-Host ""
Write-Host "  ORIGINELE VM" -ForegroundColor Cyan
Write-Host "  Subscription    : $($selectedSub.Name)" -ForegroundColor White
Write-Host "  VM name         : $DCName" -ForegroundColor White
Write-Host ""
Write-Host "  RESTORE TEST VM" -ForegroundColor Cyan
Write-Host "  Subscription    : $($selectedSub.Name)" -ForegroundColor White
Write-Host "  Resource Group  : $ResourceGroupName" -ForegroundColor White
Write-Host "  VM name         : $VMRestoreName" -ForegroundColor White
Write-Host "  NSG             : $NSGName" -ForegroundColor White
Write-Host "  Storage Account : $StorageAccountName" -ForegroundColor White
Write-Host "  VNet            : $VNetName" -ForegroundColor White
Write-Host "  Public IP       : $PIPName" -ForegroundColor White
Write-Host "  Region          : $Region" -ForegroundColor White
Write-Host "  CreatedBy tag   : $($Tags.CreatedBy)" -ForegroundColor White
Write-Host "  Overwrite VM    : false" -ForegroundColor White
Write-Host "  ─────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""
Read-Host "  Alles correct? Druk Enter om te starten, of Ctrl+C om af te breken"

# ─────────────────────────────────────────────────────────────
# STAP 3 – RESOURCE GROUP
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 3 – Resource Group"

$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if ($null -eq $rg) {
    Write-Step "Resource group '$ResourceGroupName' bestaat niet. Aanmaken..."
    New-AzResourceGroup -Name $ResourceGroupName -Location $Region -Tag $Tags | Out-Null
    Write-OK "Resource group aangemaakt: $ResourceGroupName"
} else {
    Write-OK "Resource group bestaat al: $ResourceGroupName"
}

# ─────────────────────────────────────────────────────────────
# STAP 4 – NETWORK SECURITY GROUP
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 4 – Network Security Group"

$nsg = Get-AzNetworkSecurityGroup -Name $NSGName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if ($null -eq $nsg) {
    Write-Step "NSG '$NSGName' aanmaken..."
    $nsg = New-AzNetworkSecurityGroup `
        -Name $NSGName `
        -ResourceGroupName $ResourceGroupName `
        -Location $Region `
        -Tag $Tags
    Write-OK "NSG aangemaakt: $NSGName"
} else {
    Write-OK "NSG bestaat al: $NSGName"
}

# ─────────────────────────────────────────────────────────────
# STAP 5 – STORAGE ACCOUNT
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 5 – Storage Account"

$sa = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction SilentlyContinue
if ($null -eq $sa) {
    Write-Step "Storage account '$StorageAccountName' aanmaken..."
    New-AzStorageAccount `
        -ResourceGroupName $ResourceGroupName `
        -Name $StorageAccountName `
        -Location $Region `
        -SkuName Standard_LRS `
        -Kind StorageV2 `
        -Tag $Tags | Out-Null
    Write-OK "Storage account aangemaakt: $StorageAccountName"
} else {
    Write-OK "Storage account bestaat al: $StorageAccountName"
}

# ─────────────────────────────────────────────────────────────
# STAP 6 – VIRTUAL NETWORK
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 6 – Virtual Network"

$vnet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if ($null -eq $vnet) {
    Write-Step "VNet '$VNetName' aanmaken met subnet '$SubnetName'..."
    $subnetConfig = New-AzVirtualNetworkSubnetConfig `
        -Name $SubnetName `
        -AddressPrefix "10.10.0.0/24"
    $vnet = New-AzVirtualNetwork `
        -Name $VNetName `
        -ResourceGroupName $ResourceGroupName `
        -Location $Region `
        -AddressPrefix "10.10.0.0/16" `
        -Subnet $subnetConfig `
        -Tag $Tags
    Write-OK "VNet aangemaakt: $VNetName (10.10.0.0/16), subnet: $SubnetName (10.10.0.0/24)"
} else {
    Write-OK "VNet bestaat al: $VNetName"
}

# ─────────────────────────────────────────────────────────────
# STAP 7 – PUBLIC IP
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 7 – Public IP"

$pip = Get-AzPublicIpAddress -Name $PIPName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if ($null -eq $pip) {
    Write-Step "Public IP '$PIPName' aanmaken..."
    $pip = New-AzPublicIpAddress `
        -Name $PIPName `
        -ResourceGroupName $ResourceGroupName `
        -Location $Region `
        -AllocationMethod Static `
        -Sku Standard `
        -Tag $Tags
    Write-OK "Public IP aangemaakt: $PIPName"
} else {
    Write-OK "Public IP bestaat al: $PIPName"
}

# ─────────────────────────────────────────────────────────────
# STAP 8 – AUTOMATISCHE VM-RESTORE VIA RECOVERY SERVICES
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 8 – Automatische VM-Restore"

# ── 8.1 Zoek de Recovery Services Vault die de DC bevat ──────
Write-Step "Recovery Services Vaults ophalen..."
$allVaults = @(Get-AzRecoveryServicesVault)
if ($allVaults.Count -eq 0) {
    Write-Error "Geen Recovery Services Vaults gevonden in subscription '$($selectedSub.Name)'."
    exit 1
}

# Zoek automatisch de vault die een backup heeft van $DCName
$targetVault    = $null
$targetItem     = $null

foreach ($vault in $allVaults) {
    Set-AzRecoveryServicesVaultContext -Vault $vault
    $container = Get-AzRecoveryServicesBackupContainer `
        -ContainerType AzureVM `
        -FriendlyName $DCName `
        -ErrorAction SilentlyContinue

    if ($null -ne $container) {
        $item = Get-AzRecoveryServicesBackupItem `
            -Container $container `
            -WorkloadType AzureVM `
            -ErrorAction SilentlyContinue
        if ($null -ne $item) {
            $targetVault = $vault
            $targetItem  = $item
            break
        }
    }
}

if ($null -eq $targetVault) {
    Write-Error "Geen backup gevonden voor VM '$DCName' in een van de beschikbare vaults."
    exit 1
}
Write-OK "Vault gevonden: $($targetVault.Name)"
Write-OK "Backup item  : $($targetItem.Name)"

# ── 8.2 Herstelpunten ophalen en meest recente kiezen ───────
Write-Step "Herstelpunten ophalen..."
Set-AzRecoveryServicesVaultContext -Vault $targetVault

$recoveryPoints = @(Get-AzRecoveryServicesBackupRecoveryPoint `
    -Item $targetItem `
    | Sort-Object -Property RecoveryPointTime -Descending)

if ($recoveryPoints.Count -eq 0) {
    Write-Error "Geen Herstelpunten gevonden voor '$DCName'."
    exit 1
}

# Toon de 5 meest recente Herstelpunten ter keuze
Write-Host ""
Write-Host "  Beschikbare Herstelpunten (nieuwste eerst):" -ForegroundColor Cyan
$showCount = [Math]::Min(5, $recoveryPoints.Count)
for ($i = 0; $i -lt $showCount; $i++) {
    Write-Host ("  [{0}] {1}  ({2})" -f `
        ($i + 1), `
        $recoveryPoints[$i].RecoveryPointTime.ToString("yyyy-MM-dd HH:mm:ss"), `
        $recoveryPoints[$i].RecoveryPointType) -ForegroundColor White
}

Write-Host ""
$rpChoice = Read-Host "  Kies Herstelpunt (Enter = 1, meest recent)"
if ([string]::IsNullOrWhiteSpace($rpChoice)) { $rpChoice = 1 }
$selectedRP = $recoveryPoints[[int]$rpChoice - 1]
Write-OK "Herstelpunt gekozen: $($selectedRP.RecoveryPointTime.ToString("yyyy-MM-dd HH:mm:ss"))"

# ── 8.3 Restore-configuratie opbouwen ────────────────────────
Write-Step "Restore-configuratie opbouwen..."

$vnet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroupName
$sa   = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName

Write-OK "Restore-configuratie opgebouwd."

# ── 8.4 Restore starten ───────────────────────────────────────
Write-Step "Restore-job starten voor '$VMRestoreName'..."
$restoreJob = Restore-AzRecoveryServicesBackupItem `
    -RecoveryPoint                   $selectedRP `
    -TargetResourceGroupName         $ResourceGroupName `
    -StorageAccountName              $StorageAccountName `
    -StorageAccountResourceGroupName $ResourceGroupName `
    -TargetVMName                    $VMRestoreName `
    -TargetVNetName                  $VNetName `
    -TargetVNetResourceGroup         $ResourceGroupName `
    -TargetSubnetName                $SubnetName `
    -VaultId                         $targetVault.ID `
    -ErrorAction                     Stop

Write-OK "Restore-job gestart. Job ID: $($restoreJob.JobId)"

# ── 8.5 Wachten tot restore klaar is (met voortgang) ─────────
Write-Step "Wachten op voltooiing van restore-job..."
Write-Host ""

$jobDone      = $false
$waitSeconds  = 30
$elapsedSecs  = 0
$spinChars    = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
$spinIndex    = 0
$barWidth     = 20
$barFilled    = 0
$lastStatus   = "InProgress"

function Show-ProgressBar {
    param(
        [int]    $Filled,
        [int]    $Total,
        [string] $Spinner,
        [string] $Elapsed,
        [string] $Status
    )
    $done      = [Math]::Min($Filled, $Total)
    $remaining = $Total - $done
    $bar       = "█" * $done + "░" * $remaining
    $pct       = [Math]::Min([int](($done / $Total) * 100), 99)  # nooit 100% tonen tot écht klaar

    # Schrijf op dezelfde regel (geen newline)
    Write-Host ("`r  {0} [{1}] {2}%  ⏱ {3}  Status: {4,-20}" -f `
        $Spinner, $bar, $pct, $Elapsed, $Status) -NoNewline -ForegroundColor Cyan
}

while (-not $jobDone) {
    # Countdown van waitSeconds naar 0, per seconde spinner updaten
    for ($tick = $waitSeconds; $tick -gt 0; $tick--) {
        $spinChar       = $spinChars[$spinIndex % $spinChars.Count]
        $spinIndex++
        $elapsedDisplay = [string]::Format("{0:mm\:ss}", [timespan]::FromSeconds($elapsedSecs + ($waitSeconds - $tick)))
        Show-ProgressBar -Filled $barFilled -Total $barWidth -Spinner $spinChar -Elapsed $elapsedDisplay -Status $lastStatus
        Start-Sleep -Seconds 1
    }

    $elapsedSecs += $waitSeconds

    $jobStatus      = Get-AzRecoveryServicesBackupJob -JobId $restoreJob.JobId -VaultId $targetVault.ID
    $lastStatus     = $jobStatus.Status
    $elapsedDisplay = [string]::Format("{0:mm\:ss}", [timespan]::FromSeconds($elapsedSecs))

    # Balk langzaam laten vullen (elke poll 1 blokje, max tot 19 — laatste blokje pas bij Completed)
    if ($barFilled -lt ($barWidth - 1)) { $barFilled++ }

    if ($lastStatus -in @("Completed", "Failed", "Cancelled")) {
        $jobDone = $true
    }
}

# Eindstatus op nieuwe regel tonen
if ($jobStatus.Status -eq "Completed") {
    $barFilled = $barWidth
    Show-ProgressBar -Filled $barFilled -Total $barWidth -Spinner "✔" -Elapsed $elapsedDisplay -Status "Completed"
    Write-Host ""
    Write-Host ""
    Write-OK "Restore succesvol afgerond na $elapsedDisplay. VM '$VMRestoreName' is aangemaakt."
} else {
    Write-Host ""
    Write-Host ""
    Write-Error "Restore-job geëindigd met status: $($jobStatus.Status). Controleer de vault in de Azure Portal."
    exit 1
}

Write-OK "Restore succesvol afgerond. VM '$VMRestoreName' is aangemaakt."

# ─────────────────────────────────────────────────────────────
# STAP 9 – VM EN NIC OPHALEN
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 9 – VM en NIC ophalen"

Write-Step "Herstelde VM '$VMRestoreName' ophalen..."
$restoredVM = $null
$retryCount = 0
$maxRetries = 5

while ($null -eq $restoredVM -and $retryCount -lt $maxRetries) {
    $restoredVM = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMRestoreName -ErrorAction SilentlyContinue
    if ($null -eq $restoredVM) {
        $retryCount++
        Write-Host "  ⚠ VM nog niet gevonden. Poging $retryCount/$maxRetries. Wacht 15 seconden..." -ForegroundColor Red
        Start-Sleep -Seconds 15
    }
}

if ($null -eq $restoredVM) {
    Write-Error "VM '$VMRestoreName' niet gevonden na $maxRetries pogingen. Controleer de naam in de Portal en herstart het script vanaf stap 9."
    exit 1
}
Write-OK "VM gevonden: $($restoredVM.Name)"

$nicId   = $restoredVM.NetworkProfile.NetworkInterfaces[0].Id
$nicName = $nicId.Split('/')[-1]
Write-Step "NIC ophalen: $nicName..."
$nic       = Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName -Name $nicName
$privateIP = $nic.IpConfigurations[0].PrivateIpAddress
Write-OK "NIC opgehaald. Privé IP: $privateIP"

# ─────────────────────────────────────────────────────────────
# STAP 10 – PUBLIC IP KOPPELEN AAN NIC
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 10 – Public IP koppelen"

Write-Step "Public IP koppelen aan NIC..."
$pip = Get-AzPublicIpAddress -Name $PIPName -ResourceGroupName $ResourceGroupName
$nic.IpConfigurations[0].PublicIpAddress = $pip
Set-AzNetworkInterface -NetworkInterface $nic | Out-Null
Write-OK "Public IP gekoppeld aan NIC."

# ─────────────────────────────────────────────────────────────
# STAP 11 – NSG KOPPELEN AAN NIC
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 11 – NSG koppelen aan NIC"

Write-Step "NSG koppelen aan NIC..."
$nsg = Get-AzNetworkSecurityGroup -Name $NSGName -ResourceGroupName $ResourceGroupName
$nic = Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName -Name $nicName
$nic.NetworkSecurityGroup = $nsg
Set-AzNetworkInterface -NetworkInterface $nic | Out-Null
Write-OK "NSG gekoppeld aan NIC."

# ─────────────────────────────────────────────────────────────
# STAP 12 – RDP INBOUND RULE TOEVOEGEN AAN NSG
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 12 – RDP Inbound Rule toevoegen"

Write-Step "Inbound RDP-regel 'AllowRDP' toevoegen..."
$nsg = Get-AzNetworkSecurityGroup -Name $NSGName -ResourceGroupName $ResourceGroupName

$existingRule = $nsg.SecurityRules | Where-Object { $_.Name -eq "AllowRDP" }
if ($null -eq $existingRule) {
    $rdpRule = New-AzNetworkSecurityRuleConfig `
        -Name                     "AllowRDP" `
        -Protocol                 Tcp `
        -Direction                Inbound `
        -Priority                 100 `
        -SourceAddressPrefix      "0.0.0.0/0" `
        -SourcePortRange          "*" `
        -DestinationAddressPrefix $privateIP `
        -DestinationPortRange     3389 `
        -Access                   Allow

    $nsg.SecurityRules.Add($rdpRule)
    Set-AzNetworkSecurityGroup -NetworkSecurityGroup $nsg | Out-Null
    Write-OK "RDP-regel 'AllowRDP' toegevoegd."
    Write-Info "  Source     : 0.0.0.0/0"
    Write-Info "  Destination: $privateIP"
    Write-Info "  Poort      : 3389"
} else {
    Write-OK "Regel 'AllowRDP' bestond al."
}

# ─────────────────────────────────────────────────────────────
# STAP 13 – PUBLIC IP OPHALEN EN EINDRAPPORT
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 13 – Resultaat & Instructies"

Start-Sleep -Seconds 10
$pipFinal        = Get-AzPublicIpAddress -Name $PIPName -ResourceGroupName $ResourceGroupName
$publicIPAddress = $pipFinal.IpAddress

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║            RESTORE OMGEVING GEREED                  ║" -ForegroundColor Green
Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  OVERZICHT AANGEMAAKTE RESOURCES:" -ForegroundColor Cyan
Write-Host "  ┌─────────────────────────────────────────────────────┐" -ForegroundColor DarkGray
Write-Host ("  │ Resource Group  : {0,-34}│" -f $ResourceGroupName)  -ForegroundColor White
Write-Host ("  │ VM name         : {0,-34}│" -f $VMRestoreName)      -ForegroundColor White
Write-Host ("  │ VNet            : {0,-34}│" -f $VNetName)           -ForegroundColor White
Write-Host ("  │ NSG             : {0,-34}│" -f $NSGName)            -ForegroundColor White
Write-Host ("  │ Storage Account : {0,-34}│" -f $StorageAccountName) -ForegroundColor White
Write-Host ("  │ Private IP      : {0,-34}│" -f $privateIP)          -ForegroundColor White
Write-Host ("  │ Public IP       : {0,-34}│" -f $publicIPAddress)    -ForegroundColor Green
Write-Host "  └─────────────────────────────────────────────────────┘" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  VOLGENDE STAP – HANDMATIGE VALIDATIE:" -ForegroundColor Magenta
Write-Host ""
Write-Host "  1. Verbind met de server via RDP (opstarten van de VM kan even duren)" -ForegroundColor Yellow
Write-Host "     IP adres: $publicIPAddress" -ForegroundColor White
Write-Host ""
Write-Host "  2. Log in met de domeinbeheerder-credentials" -ForegroundColor Yellow
Write-Host ""
Write-Host "  3. Controleer de Domain Controller:"                                                                 -ForegroundColor Yellow
Write-Host "     - Open Active Directory Users and Computers"                                                      -ForegroundColor White
Write-Host "     - Voer uit: hostname (in cmd)"                                                                    -ForegroundColor White
Write-Host "     - Open Services en sorteer op 'Startup Type' 'Automatic', controleer of deze 'Running' zijn!"     -ForegroundColor White
Write-Host "     - Controleer of de FSMO-rollen correct zijn"                                                      -ForegroundColor White
Write-Host "     - Verifieer DNS-functionaliteit"                                                                  -ForegroundColor White
Write-Host ""
Write-Host "  4. Verwijder de restore-omgeving na validatie via:"                                                  -ForegroundColor Yellow
Write-Host "     Remove-AzResourceGroup -Name $ResourceGroupName -Force"                                           -ForegroundColor White
Write-Host ""
Write-Host "  Succes met de validatie :)"                                                                          -ForegroundColor Green
Write-Host ""

# ─────────────────────────────────────────────────────────────
# STAP 14 – OPRUIMEN
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 14 – Opruimen (optioneel)"

Write-Host "  Wil je de volledige restore-omgeving verwijderen?" -ForegroundColor Yellow
Write-Host "  Dit verwijdert de volgende resource group inclusief alle resources:" -ForegroundColor White
Write-Host "  → $ResourceGroupName" -ForegroundColor White
Write-Host ""
Write-Host "  ⚠ Dit kan NIET ongedaan worden gemaakt!" -ForegroundColor Red
Write-Host ""

do {
    $cleanupInput = (Read-Host "  Opruimen? (ja/nee, Enter = nee)").Trim().ToLower()
    if ([string]::IsNullOrWhiteSpace($cleanupInput)) {
        $cleanupInput = "nee"
    }
    if ($cleanupInput -notin @("ja", "nee")) {
        Write-Host "  ⚠ Typ 'ja' of 'nee'." -ForegroundColor Red
        $cleanupInput = $null
    }
} while ($null -eq $cleanupInput)

if ($cleanupInput -eq "ja") {
    Write-Host ""
    Write-Host "  Laatste bevestiging — dit verwijdert alles inclusief de herstelde VM." -ForegroundColor Red
    do {
        $confirmCleanup = (Read-Host "  Typ 'VERWIJDER' om te bevestigen, of druk Enter om te annuleren").Trim()
        if ([string]::IsNullOrWhiteSpace($confirmCleanup)) {
            $confirmCleanup = "annuleren"
        }
        if ($confirmCleanup -notin @("VERWIJDER", "annuleren")) {
            Write-Host "  ⚠ Typ exact 'VERWIJDER' of druk Enter om te annuleren." -ForegroundColor Red
            $confirmCleanup = $null
        }
    } while ($null -eq $confirmCleanup)

    if ($confirmCleanup -eq "VERWIJDER") {
        Write-Step "Resource group '$ResourceGroupName' wordt verwijderd..."
        Remove-AzResourceGroup -Name $ResourceGroupName -Force | Out-Null
        Write-OK "Resource group '$ResourceGroupName' succesvol verwijderd."
        Disconnect-AzAccount | Out-Null
        Write-OK "Succesvol uitgelogd van Azure"
    } else {
        Write-Host "  ℹ Verwijderen geannuleerd. Resource group blijft bestaan." -ForegroundColor Yellow
    }
} else {
    Write-Host ""
    Write-Host "  ℹ Omgeving blijft bestaan. Verwijder later handmatig via:" -ForegroundColor Yellow
    Write-Host "    Remove-AzResourceGroup -Name $ResourceGroupName -Force" -ForegroundColor White
}

Write-Host ""
Write-Host "  Script voltooid!" -ForegroundColor Green
Write-Host ""