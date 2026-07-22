#Requires -Modules Az.Accounts, Az.Resources, Az.Network, Az.Storage, Az.Compute, Az.RecoveryServices

<#
.SYNOPSIS
    Automatisering voor het herstellen van een Azure Virtual Machine.

.DESCRIPTION
    Dit script zet een herstelomgeving klaar en begeleidt het restore-proces van een Azure VM.
    Ondersteunt authenticatie via Service Principal en Modern Authentication.
    Kan interactief gebruikt worden, of via onderstaande optionele parameters.

.PARAMETER TenantID
    (Optioneel) De Azure Active Directory Tenant ID.

.PARAMETER AppId
    (Optioneel) De applicatie-id van de Service Principal voor authenticatie.

.PARAMETER AppSecret
    (Optioneel) Het geheim van de Service Principal.

.PARAMETER UseExistingSession
    (Switch, optioneel) Gebruik een reeds bestaande Azure sessie.

.PARAMETER SkipConfirmation
    (Switch, optioneel) Sla bevestigingsvragen over.

.PARAMETER OriginalVM
    (Optioneel) Naam van de oorspronkelijke VM die hersteld moet worden.

.PARAMETER Subscription
    (Optioneel) Naam of ID van de Azure Subscription.

.PARAMETER CustomerName
    (Optioneel) Naam van de klant.

.PARAMETER Ticket
    (Optioneel) Ticketnummer of referentie voor deze restore-actie.

.PARAMETER CreatedBy
    (Optioneel) Naam van de uitvoerder van het script. Voor tagging

.PARAMETER Region
    (Optioneel) Azure-regio waar de herstelomgeving wordt opgebouwd.

.PARAMETER RecoveryPointIndex
    (Optioneel) Index van het te gebruiken herstelpunt.

.EXAMPLE
    .\Restore-AzureVM.ps1 -TenantID "0123456" -AppId "123456" -AppSecret "ABCDEFG" `
        -OriginalVM "DC01" -Subscription "MySub" -CustomerName "Contoso" `
        -Ticket "OT2606-01234" -CreatedBy "Jan de Vries" -Region "westeurope" `
        -RecoveryPointIndex 1 -SkipConfirmation

.NOTES
    Auteur  : Jordy Hoebergen
#>

[CmdletBinding()]
param(
    [string] $TenantId,             # Tenant ID
    [string] $AppId,                # Service Principal Application ID
    [string] $AppSecret,            # Service Principal Secret
    [switch] $UseExistingSession,   # Huidige AZ sessie hergebruiken
    [switch] $SkipConfirmation,     # Sla de samenvatting-bevestiging over
    [string] $OriginalVM,           # Naam van de te restoren VM
    [string] $Subscription,         # Naam of ID van de Azure subscription
    [string] $CustomerName,         # Klantnaam (alleen letters en cijfers)
    [string] $Ticket,               # Ticketnummer (bijv. OT2606-01234)
    [string] $CreatedBy,            # Volledige naam voor de CreatedBy-tag
    [string] $Region,               # Azure-regio (standaard: westeurope)
    [int]    $RecoveryPointIndex    # Index van herstelpunt (standaard: 1)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptVersion = "0.0.2"
$BaseUrl = "https://github.com/JordyEGNL/Azure-Restore-Test-PowerShell/raw/refs/heads/main/"
$LatestVersionUrl = "$BaseUrl/version.txt"
$ScriptUrl = "$BaseUrl/Restore-AzureVM.ps1"

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

function Write-Error {
    param([string]$Text)
    Write-Host "  ⚠ $Text" -ForegroundColor Red
}


# ─────────────────────────────────────────────────────────────
# STAP 0 – VERSIE CHECK
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 0 – Versie Controle"

function Update-Script {
    Invoke-WebRequest -Uri $ScriptUrl -OutFile $PSCommandPath -UseBasicParsing
    Write-Info "Script is bijgewerkt naar de nieuwste versie. Start opnieuw."
    exit
}

try {
    $LatestVersion = (Invoke-RestMethod -Uri $LatestVersionUrl -UseBasicParsing).Trim()
} catch {
    Write-Error "Kan laatste versie niet ophalen."
    $LatestVersion = $null
}

if ($null -eq $LatestVersion) {
    # Geen actie, fout is al getoond
} elseif ($LatestVersion -ne $ScriptVersion) {
    Write-Info "Huidige versie : $ScriptVersion"
    Write-Info "Nieuwste versie: $LatestVersion"
    $Update = Read-Host "`nNieuwe versie beschikbaar! Nu updaten? (J/n)"
    if ($Update -notin @("N", "n")) {
        Update-Script
    }
} else {
    Write-Info "Geen update gevonden"
}

# ─────────────────────────────────────────────────────────────
# STAP 1 – AZURE LOGIN
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 1 – Azure Login"

if ($UseExistingSession) {
    # ── Optie 1: bestaande sessie hergebruiken ────────────────
    $currentAccount = Get-AzContext -ErrorAction SilentlyContinue
    if ($null -eq $currentAccount -or $null -eq $currentAccount.Account) {
        Write-Step "Inloggen bij Azure... (inlogscherm kan verstopt zijn achter het huidige venster)"

        if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
            Connect-AzAccount -TenantId $TenantId -AuthScope https://management.azure.com/ | Out-Null
        } else {
            Connect-AzAccount -AuthScope https://management.azure.com/ | Out-Null
        }

        Write-OK "Succesvol ingelogd."
    }
    Write-OK "Bestaande sessie hergebruikt: $($currentAccount.Account.Id)"

} elseif (-not [string]::IsNullOrWhiteSpace($AppId) -and
          -not [string]::IsNullOrWhiteSpace($AppSecret) -and
          -not [string]::IsNullOrWhiteSpace($TenantId)) {
    # ── Optie 2: service principal ────────────────────────────
    Write-Step "Inloggen via Service Principal..."
    $secureSecret = ConvertTo-SecureString $AppSecret -AsPlainText -Force
    $credential   = New-Object System.Management.Automation.PSCredential($AppId, $secureSecret)
    Connect-AzAccount -ServicePrincipal -Credential $credential -Tenant $TenantId `
    -AuthScope https://management.azure.com/ | Out-Null
    Write-OK "Succesvol ingelogd via Service Principal: $AppId"

} else {
    # ── Optie 3: interactief (fallback) ───────────────────────
    Write-Step "Inloggen bij Azure... (inlogscherm kan verstopt zijn achter het huidige venster)"

    # Eerste login: zonder scope, puur om beschikbare tenants op te halen
    Connect-AzAccount | Out-Null

    # Tenant ID automatisch uitlezen
    $tenants = @(Get-AzTenant)

    if ($tenants.Count -eq 0) {
        Write-Error "Geen tenants gevonden na inloggen."
        exit 1
    } elseif ($tenants.Count -eq 1) {
        $resolvedTenant = $tenants[0]
        Write-OK "Tenant automatisch geselecteerd: $($resolvedTenant.Name) [$($resolvedTenant.Id)]"
    } else {
        Write-Host ""
        Write-Host "  Beschikbare tenants:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $tenants.Count; $i++) {
            Write-Host ("  [{0}] {1,-40} {2}" -f ($i + 1), $tenants[$i].Name, $tenants[$i].Id) -ForegroundColor White
        }
        Write-Host ""
        do {
            $tenantChoice = (Read-Host "  Kies een tenant (nummer)").Trim()
        } while (-not ($tenantChoice -match '^\d+$') -or
                 [int]$tenantChoice -lt 1 -or
                 [int]$tenantChoice -gt $tenants.Count)

        $resolvedTenant = $tenants[[int]$tenantChoice - 1]
        Write-OK "Tenant geselecteerd: $($resolvedTenant.Name) [$($resolvedTenant.Id)]"
    }

    # Sla Tenant ID op zodat STAP 2 hem kan gebruiken
    $TenantId = $resolvedTenant.Id

    # Tweede login: met juiste tenant EN ARM scope (vereist voor Get-AzAccessToken in STAP 2)
    Write-Step "Opnieuw verbinden met correcte tenant en ARM scope..."
    Connect-AzAccount -TenantId $TenantId -AuthScope https://management.azure.com/ | Out-Null
    Write-OK "Succesvol ingelogd op tenant: $($resolvedTenant.Name)"
}

# ─────────────────────────────────────────────────────────────
# STAP 2 – PIM ROLE ACTIVATIE
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 2 – PIM Role Activatie"

function Invoke-PimActivation {
    param(
        [string] $TenantId,
        [string] $RoleName      = "Contributor",
        [int]    $DurationHours = 2,
        [string] $Justification = "Azure VM Restore script - $env:USERNAME"
    )

    # Token ophalen voor ARM
    $tokenObj = Get-AzAccessToken -ResourceUrl "https://management.azure.com/" -TenantId $TenantId -AsSecureString:$false
    $token    = if ($tokenObj.Token -is [System.Security.SecureString]) {
        [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenObj.Token)
        )
    } else {
        $tokenObj.Token
    }
    $headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }
    $scope   = "/providers/Microsoft.Management/managementGroups/$TenantId"

    # Zoek de role definition ID op basis van naam
    Write-Step "Role definition ophalen voor '$RoleName'..."
    $roleDefsUri = "https://management.azure.com/$scope/providers/Microsoft.Authorization/roleDefinitions?`$filter=roleName eq '$RoleName'&api-version=2022-04-01"
    $roleDefs    = Invoke-RestMethod -Uri $roleDefsUri -Headers $headers -Method Get
    $roleDefId   = $roleDefs.value[0].id

    if ([string]::IsNullOrWhiteSpace($roleDefId)) {
        Write-Host "  ⚠ Role definition '$RoleName' niet gevonden op scope $scope." -ForegroundColor Red
        return $false
    }
    Write-OK "Role definition gevonden: $roleDefId"

Write-Step "Controleren of rol al actief is (permanent of PIM active)..."

try {
    # Object ID uit het JWT token halen
    $tokenPayload = $token.Split('.')[1]
    $tokenPayload = $tokenPayload.Replace('-', '+').Replace('_', '/')
    $padded       = $tokenPayload.PadRight($tokenPayload.Length + (4 - $tokenPayload.Length % 4) % 4, '=')
    $objectId     = ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($padded)) | ConvertFrom-Json).oid

    # Check op subscription scope
    $subScope       = "/subscriptions/$((Get-AzContext).Subscription.Id)"
    $assignmentsUri = "https://management.azure.com$subScope/providers/Microsoft.Authorization/roleAssignments?`$filter=principalId eq '$objectId'&api-version=2022-04-01"
    $assignments    = Invoke-RestMethod -Uri $assignmentsUri -Headers $headers -Method Get

    $activeRole = $assignments.value | Where-Object {
        $_.properties.roleDefinitionId.Split('/')[-1] -in @(
            "b24988ac-6180-42a0-ab88-20f7382dd24c", # Contributor
            "8e3af657-a8ff-443c-a75c-2fe8c4bcb635", # Owner
            "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9"  # User Access Administrator
        )
    } | Select-Object -First 1

    if ($null -ne $activeRole) {
        $foundRoleName = switch ($activeRole.properties.roleDefinitionId.Split('/')[-1]) {
            "b24988ac-6180-42a0-ab88-20f7382dd24c" { "Contributor" }
            "8e3af657-a8ff-443c-a75c-2fe8c4bcb635" { "Owner" }
            "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9" { "User Access Administrator" }
        }
        Write-OK "Actieve rol gevonden ($foundRoleName) — PIM activatie overgeslagen."
        Write-Info "Reden: permanente toewijzing of PIM al actief op subscription-niveau."
        return "already_active"
    }

    Write-Info "Geen actieve rol op subscription-niveau gevonden, controleer op management group niveau..."

    # Check ook op management group scope (root tenant)
    $mgScope         = "/providers/Microsoft.Management/managementGroups/$TenantId"
    $mgAssignUri     = "https://management.azure.com$mgScope/providers/Microsoft.Authorization/roleAssignments?`$filter=principalId eq '$objectId'&api-version=2022-04-01"
    $mgAssignments   = Invoke-RestMethod -Uri $mgAssignUri -Headers $headers -Method Get -ErrorAction SilentlyContinue

    $activeMgRole = $mgAssignments.value | Where-Object {
        $_.properties.roleDefinitionId.Split('/')[-1] -in @(
            "b24988ac-6180-42a0-ab88-20f7382dd24c",
            "8e3af657-a8ff-443c-a75c-2fe8c4bcb635",
            "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9"
        )
    } | Select-Object -First 1

    if ($null -ne $activeMgRole) {
        Write-OK "Actieve rol gevonden op management group niveau — PIM activatie overgeslagen."
        return "already_active"
    }

} catch {
    Write-Info "Kon actieve roltoewijzingen niet controleren, doorgaan met PIM... ($_)"
}

    # Haal de PIM eligible assignment op voor de huidige gebruiker
    Write-Step "Eligible PIM assignment ophalen..."
    $eligibleUri = "https://management.azure.com/$scope/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?`$filter=asTarget()&api-version=2020-10-01"

    try {
        $eligibleRoles  = Invoke-RestMethod -Uri $eligibleUri -Headers $headers -Method Get
        $eligibleAssign = $eligibleRoles.value | Where-Object {
            $_.properties.roleDefinitionId -eq $roleDefId
        } | Select-Object -First 1
    } catch {
        $errMsg = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($errMsg.error.code -eq "AadPremiumLicenseRequired") {
            Write-Info "Geen Entra ID P2 licentie gevonden — PIM is niet beschikbaar op deze tenant."
            Write-Info "PIM activatie overgeslagen, doorgaan zonder."
            return $false
        }
        Write-Host "  ⚠ Fout bij ophalen PIM assignments: $($errMsg.error.message)" -ForegroundColor Red
        return $false
    }

    if ($null -eq $eligibleAssign) {
        Write-Host "  ⚠ Geen eligible PIM assignment gevonden voor '$RoleName' op root tenant group." -ForegroundColor Red
        Write-Host "    Activeer handmatig via: https://entra.microsoft.com/#view/Microsoft_Azure_PIMCommon/ActivationMenuBlade/~/azurerbac" -ForegroundColor DarkGray
        return $false
    }
    Write-OK "Eligible assignment gevonden voor: $((Get-AzContext).Account.Id)"

    # Activeer de rol via een roleAssignmentScheduleRequest
    Write-Step "PIM rol '$RoleName' activeren voor $DurationHours uur..."
    $requestBody = @{
        properties = @{
            principalId                     = $eligibleAssign.properties.principalId
            roleDefinitionId                = $roleDefId
            requestType                     = "SelfActivate"
            linkedRoleEligibilityScheduleId = $eligibleAssign.properties.roleEligibilityScheduleId
            scheduleInfo                    = @{
                expiration = @{
                    type     = "AfterDuration"
                    duration = "PT$($DurationHours)H"
                }
            }
            justification                   = $Justification
        }
    } | ConvertTo-Json -Depth 5

    $activateUri = "https://management.azure.com/$scope/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/$(New-Guid)?api-version=2020-10-01"

    try {
        Invoke-RestMethod -Uri $activateUri -Headers $headers -Method Put -Body $requestBody | Out-Null
        Write-OK "PIM rol '$RoleName' succesvol geactiveerd voor $DurationHours uur."
        return "activated"
    } catch {
        $errMsg = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($errMsg.error.code -eq "RoleAssignmentExists") {
            Write-OK "PIM rol '$RoleName' was al actief."
            return "already_active"
        }
        Write-Host "  ⚠ PIM activatie mislukt: $($errMsg.error.message)" -ForegroundColor Red
        return $false
    }
}

$resolvedTenantId = if (-not [string]::IsNullOrWhiteSpace($TenantId)) { $TenantId } else { (Get-AzContext).Tenant.Id }

$pimActivated = Invoke-PimActivation -TenantId $resolvedTenantId -DurationHours 4 -Justification "Azure Restore Test"

if (-not $pimActivated) {
    Write-Host ""
    Write-Host "  ℹ PIM activatie overgeslagen of mislukt." -ForegroundColor Yellow
    Write-Host "  Activeer minimaal 'Contributor' handmatig en herstart het script, of ga door op eigen risico." -ForegroundColor Yellow
    Write-Host ""
    if (-not $SkipConfirmation) {
        Read-Host "  Druk Enter om toch door te gaan, of Ctrl+C om af te breken"
    }
}

if ($pimActivated -eq "activated") {
    Write-Step "Wachten op rol-propagatie (15 seconden)..."
    Start-Sleep -Seconds 15
    Write-OK "Propagatie voltooid."
}

# ─────────────────────────────────────────────────────────────
# STAP 3 – SUBSCRIPTION SELECTIE
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 3 – Subscription Selectie"

$allSubs = @(Get-AzSubscription | Sort-Object Name)
if ($allSubs.Count -eq 0) {
    Write-Error "Geen subscriptions gevonden voor dit account. (Heb je de juiste rollen actief?)
    https://entra.microsoft.com/#view/Microsoft_Azure_PIMCommon/ActivationMenuBlade/~/azurerbac"
    exit 1
}

if (-not [string]::IsNullOrWhiteSpace($Subscription)) {
    # Via parameter: zoek op naam of ID
    $selectedSub = $allSubs | Where-Object {
        $_.Name -eq $Subscription -or $_.Id -eq $Subscription
    } | Select-Object -First 1

    if ($null -eq $selectedSub) {
        Write-Error "Subscription '$Subscription' niet gevonden."
        exit 1
    }
    Write-OK "Subscription (parameter): $($selectedSub.Name) [$($selectedSub.Id)]"

} else {
    # Hergebruik de subscription die Connect-AzAccount al heeft geselecteerd
    $currentContext = Get-AzContext
    $selectedSub = $allSubs | Where-Object { $_.Id -eq $currentContext.Subscription.Id } | Select-Object -First 1
    Write-OK "Subscription overgenomen van inlogsessie: $($selectedSub.Name) [$($selectedSub.Id)]"
}

Set-AzContext -SubscriptionId $selectedSub.Id | Out-Null

# ─────────────────────────────────────────────────────────────
# STAP 4 – INVOER GEGEVENS
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 4 – Invoer gegevens"

# ── Klantnaam ─────────────────────────────────────────────────
if (-not [string]::IsNullOrWhiteSpace($CustomerName)) {
    if ($CustomerName -notmatch '^[a-zA-Z0-9]+$') {
        Write-Error "Klantnaam '$CustomerName' is ongeldig. Alleen letters en cijfers toegestaan."
        exit 1
    }
    Write-OK "Klantnaam (parameter): $CustomerName"
} else {
    do {
        $CustomerName = (Read-Host "  Klantnaam (geen spaties of speciale tekens, bijv. Contoso)").Trim()
        if ([string]::IsNullOrWhiteSpace($CustomerName)) {
            Write-Host "  ⚠ Klantnaam mag niet leeg zijn." -ForegroundColor Red
        } elseif ($CustomerName -notmatch '^[a-zA-Z0-9]+$') {
            Write-Host "  ⚠ Alleen letters en cijfers toegestaan." -ForegroundColor Red
            $CustomerName = ""
        }
    } while ([string]::IsNullOrWhiteSpace($CustomerName))
    Write-OK "Klantnaam: $CustomerName"
}

# ── Ticketnummer ──────────────────────────────────────────────
if (-not [string]::IsNullOrWhiteSpace($Ticket)) {
    if ($Ticket -notmatch '^[a-zA-Z0-9\-]+$') {
        Write-Error "Ticketnummer '$Ticket' is ongeldig. Alleen letters, cijfers en koppeltekens toegestaan."
        exit 1
    }
    Write-OK "Ticketnummer (parameter): $Ticket"
} else {
    do {
        $Ticket = (Read-Host "  Ticketnummer (bijv. OT2606-01234)").Trim()
        if ([string]::IsNullOrWhiteSpace($Ticket)) {
            Write-Host "  ⚠ Ticketnummer mag niet leeg zijn." -ForegroundColor Red
        } elseif ($Ticket -notmatch '^[a-zA-Z0-9\-]+$') {
            Write-Host "  ⚠ Ticketnummer mag alleen letters, cijfers en koppeltekens bevatten." -ForegroundColor Red
            $Ticket = ""
        }
    } while ([string]::IsNullOrWhiteSpace($Ticket))
    Write-OK "Ticketnummer: $Ticket"
}

# ── VM naam ───────────────────────────────────────────────────
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

if (-not [string]::IsNullOrWhiteSpace($OriginalVM)) {
    if ($OriginalVM -notmatch '^[a-zA-Z0-9\-]+$') {
        Write-Error "VM-naam '$OriginalVM' is ongeldig. Alleen letters, cijfers en koppeltekens toegestaan."
        exit 1
    }
    $DCName = $OriginalVM
    Write-OK "VM naam (parameter): $DCName"
} else {
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
}

# ── CreatedBy ─────────────────────────────────────────────────
if (-not [string]::IsNullOrWhiteSpace($CreatedBy)) {
    if ($CreatedBy -notmatch '^[a-zA-Z\s\-\.]+$' -or $CreatedBy.Length -lt 2) {
        Write-Error "CreatedBy-naam '$CreatedBy' is ongeldig. Alleen letters, spaties, koppeltekens en punten (min. 2 tekens)."
        exit 1
    }
    $CreatedByName = $CreatedBy
    Write-OK "CreatedBy (parameter): $CreatedByName"
} else {
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
}

# ── Regio ─────────────────────────────────────────────────────
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

if (-not [string]::IsNullOrWhiteSpace($Region)) {
    $Region = $Region.Trim().ToLower()
    if ($Region -notmatch '^[a-z0-9]+$') {
        Write-Error "Regio '$Region' is ongeldig. Alleen kleine letters en cijfers toegestaan."
        exit 1
    }
    if ($Region -notin $validRegions) {
        Write-Error "Regio '$Region' is geen bekende Azure-regio. Zie https://aka.ms/azureregions"
        exit 1
    }
    Write-OK "Regio (parameter): $Region"
} else {
    Write-Host ""
    Write-Host "  Veelgebruikte regio's:" -ForegroundColor Cyan
    Write-Host "  westeurope, northeurope, uksouth, germanywestcentral, francecentral" -ForegroundColor White
    Write-Host ""
    do {
        $RegionInput = (Read-Host "  Regio (Enter = $defaultRegion)").Trim().ToLower()
        if ([string]::IsNullOrWhiteSpace($RegionInput)) {
            $Region      = $defaultRegion
            $RegionInput = $defaultRegion
        } elseif ($RegionInput -notmatch '^[a-z0-9]+$') {
            Write-Host "  ⚠ Regio mag alleen kleine letters en cijfers bevatten." -ForegroundColor Red
            $RegionInput = $null
        } elseif ($RegionInput -notin $validRegions) {
            Write-Host "  ⚠ '$RegionInput' is geen bekende Azure-regio." -ForegroundColor Red
            Write-Host "    Tip: zie https://aka.ms/azureregions voor alle regio's." -ForegroundColor DarkGray
            $RegionInput = $null
        } else {
            $Region = $RegionInput
        }
    } while ($null -eq $RegionInput)
    Write-OK "Regio: $Region"
}

# ─────────────────────────────────────────────────────────────
# VARIABELEN AFLEIDEN
# ─────────────────────────────────────────────────────────────

$ResourceGroupName  = "RG-Restore-Test-$Ticket"
$NSGName            = "$CustomerName-Restore-Test-NSG"
$StorageAccountName = ("rgrestoretest$Ticket" -replace '[^a-z0-9]', '').ToLower()
if ($StorageAccountName.Length -gt 24) { $StorageAccountName = $StorageAccountName.Substring(0, 24) }
$VNetName           = "$CustomerName-Restore-Test-VNET"
$SubnetName         = "default"
$PIPName            = "$CustomerName-Restore-Test-PIP"
$VMRestoreName      = "$CustomerName-Restore-Test-$DCName"

$Tags = @{
    Omgeving  = "Restore"
    CreatedBy = "$CreatedByName"
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

# ── Bevestiging: overgeslagen als -SkipConfirmation opgegeven ─
if ($SkipConfirmation) {
    Write-OK "Bevestiging overgeslagen (-SkipConfirmation)."
} else {
    Read-Host "  Alles correct? Druk Enter om te starten, of Ctrl+C om af te breken"
}

# ─────────────────────────────────────────────────────────────
# STAP 5 – RESOURCE GROUP
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 5 – Resource Group"

$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if ($null -eq $rg) {
    Write-Step "Resource group '$ResourceGroupName' bestaat niet. Aanmaken..."
    New-AzResourceGroup -Name $ResourceGroupName -Location $Region -Tag $Tags | Out-Null
    Write-OK "Resource group aangemaakt: $ResourceGroupName"
} else {
    Write-OK "Resource group bestaat al: $ResourceGroupName"
}

# ─────────────────────────────────────────────────────────────
# STAP 6 – NETWORK SECURITY GROUP
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 6 – Network Security Group"

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
# STAP 7 – STORAGE ACCOUNT
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 7 – Storage Account"

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
# STAP 8 – VIRTUAL NETWORK
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 8 – Virtual Network"

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
# STAP 9 – PUBLIC IP
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 9 – Public IP"

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
# STAP 10 – AUTOMATISCHE VM-RESTORE VIA RECOVERY SERVICES
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 10 – Automatische VM-Restore"

Write-Step "Recovery Services Vaults ophalen..."
$allVaults = @(Get-AzRecoveryServicesVault)
if ($allVaults.Count -eq 0) {
    Write-Error "Geen Recovery Services Vaults gevonden in subscription '$($selectedSub.Name)'."
    exit 1
}

$targetVault = $null
$targetItem  = $null

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

Write-Step "Herstelpunten ophalen..."
Set-AzRecoveryServicesVaultContext -Vault $targetVault

$recoveryPoints = @(Get-AzRecoveryServicesBackupRecoveryPoint `
    -Item $targetItem `
    | Sort-Object -Property RecoveryPointTime -Descending)

if ($recoveryPoints.Count -eq 0) {
    Write-Error "Geen herstelpunten gevonden voor '$DCName'."
    exit 1
}

Write-Host ""
Write-Host "  Beschikbare herstelpunten (nieuwste eerst):" -ForegroundColor Cyan
$showCount = [Math]::Min(5, $recoveryPoints.Count)
for ($i = 0; $i -lt $showCount; $i++) {
    Write-Host ("  [{0}] {1}  ({2})" -f `
        ($i + 1), `
        $recoveryPoints[$i].RecoveryPointTime.ToString("yyyy-MM-dd HH:mm:ss"), `
        $recoveryPoints[$i].RecoveryPointType) -ForegroundColor White
}
Write-Host ""

# ── Herstelpunt kiezen: via flag of interactief ───────────────
if ($RecoveryPointIndex -gt 0) {
    if ($RecoveryPointIndex -gt $recoveryPoints.Count) {
        Write-Error "RecoveryPointIndex $RecoveryPointIndex is groter dan het aantal beschikbare herstelpunten ($($recoveryPoints.Count))."
        exit 1
    }
    $selectedRP = $recoveryPoints[$RecoveryPointIndex - 1]
    Write-OK "Herstelpunt (parameter [$RecoveryPointIndex]): $($selectedRP.RecoveryPointTime.ToString("yyyy-MM-dd HH:mm:ss"))"
} else {
    $rpChoice = Read-Host "  Kies herstelpunt (Enter = 1, meest recent)"
    if ([string]::IsNullOrWhiteSpace($rpChoice)) { $rpChoice = 1 }
    $selectedRP = $recoveryPoints[[int]$rpChoice - 1]
    Write-OK "Herstelpunt gekozen: $($selectedRP.RecoveryPointTime.ToString("yyyy-MM-dd HH:mm:ss"))"
}

Write-Step "Restore-configuratie opbouwen..."
$vnet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroupName
$sa   = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
Write-OK "Restore-configuratie opgebouwd."

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

Write-Step "Wachten op voltooiing van restore-job..."
Write-Host ""

$jobDone     = $false
$waitSeconds = 30
$elapsedSecs = 0
$spinChars   = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
$spinIndex   = 0
$barWidth    = 20
$barFilled   = 0
$lastStatus  = "InProgress"

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
    $pct       = [Math]::Min([int](($done / $Total) * 100), 99)
    Write-Host ("`r  {0} [{1}] {2}%  ⏱ {3}  Status: {4,-20}" -f `
        $Spinner, $bar, $pct, $Elapsed, $Status) -NoNewline -ForegroundColor Cyan
}

while (-not $jobDone) {
    for ($tick = $waitSeconds; $tick -gt 0; $tick--) {
        $spinChar       = $spinChars[$spinIndex % $spinChars.Count]
        $spinIndex++
        $elapsedDisplay = [string]::Format("{0:mm\:ss}", [timespan]::FromSeconds($elapsedSecs + ($waitSeconds - $tick)))
        Show-ProgressBar -Filled $barFilled -Total $barWidth -Spinner $spinChar -Elapsed $elapsedDisplay -Status $lastStatus
        Start-Sleep -Seconds 1
    }

    $elapsedSecs   += $waitSeconds
    $jobStatus      = Get-AzRecoveryServicesBackupJob -JobId $restoreJob.JobId -VaultId $targetVault.ID
    $lastStatus     = $jobStatus.Status
    $elapsedDisplay = [string]::Format("{0:mm\:ss}", [timespan]::FromSeconds($elapsedSecs))

    if ($barFilled -lt ($barWidth - 1)) { $barFilled++ }

    if ($lastStatus -in @("Completed", "Failed", "Cancelled")) {
        $jobDone = $true
    }
}

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

# ─────────────────────────────────────────────────────────────
# STAP 11 – VM EN NIC OPHALEN
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 11 – VM en NIC ophalen"

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
    Write-Error "VM '$VMRestoreName' niet gevonden na $maxRetries pogingen."
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
# STAP 12 – PUBLIC IP KOPPELEN AAN NIC
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 12 – Public IP koppelen"

Write-Step "Public IP koppelen aan NIC..."
$pip = Get-AzPublicIpAddress -Name $PIPName -ResourceGroupName $ResourceGroupName
$nic.IpConfigurations[0].PublicIpAddress = $pip
Set-AzNetworkInterface -NetworkInterface $nic | Out-Null
Write-OK "Public IP gekoppeld aan NIC."

# ─────────────────────────────────────────────────────────────
# STAP 13 – NSG KOPPELEN AAN NIC
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 13 – NSG koppelen aan NIC"

Write-Step "NSG koppelen aan NIC..."
$nsg = Get-AzNetworkSecurityGroup -Name $NSGName -ResourceGroupName $ResourceGroupName
$nic = Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName -Name $nicName
$nic.NetworkSecurityGroup = $nsg
Set-AzNetworkInterface -NetworkInterface $nic | Out-Null
Write-OK "NSG gekoppeld aan NIC."

# ─────────────────────────────────────────────────────────────
# STAP 14 – RDP INBOUND RULE
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 14 – RDP Inbound Rule toevoegen"

Write-Step "Publiek IP-adres ophalen via ifconfig.me..."
try {
    $PublicIP = (Invoke-RestMethod -Uri "https://ifconfig.me/ip" -UseBasicParsing).Trim()
    Write-OK "Publiek IP opgehaald: $PublicIP"
} catch {
    Write-Error "Kan publiek IP-adres niet ophalen."
    return
}

Write-Step "Inbound RDP-regel 'AllowRDP' toevoegen..."
$nsg = Get-AzNetworkSecurityGroup -Name $NSGName -ResourceGroupName $ResourceGroupName

$existingRule = $nsg.SecurityRules | Where-Object { $_.Name -eq "AllowRDP" }
if ($null -eq $existingRule) {
    $rdpRule = New-AzNetworkSecurityRuleConfig `
        -Name                     "AllowRDP" `
        -Protocol                 Tcp `
        -Direction                Inbound `
        -Priority                 100 `
        -SourceAddressPrefix      "$PublicIP/32" `
        -SourcePortRange          "*" `
        -DestinationAddressPrefix $privateIP `
        -DestinationPortRange     3389 `
        -Access                   Allow

    $nsg.SecurityRules.Add($rdpRule)
    Set-AzNetworkSecurityGroup -NetworkSecurityGroup $nsg | Out-Null
    Write-OK "RDP-regel 'AllowRDP' toegevoegd."
    Write-Info "  Source     : $PublicIP/32"
    Write-Info "  Destination: $privateIP"
    Write-Info "  Poort      : 3389"
} else {
    Write-OK "Regel 'AllowRDP' bestond al."
}

# ─────────────────────────────────────────────────────────────
# STAP 15 – RESULTAAT & INSTRUCTIES
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 15 – Resultaat & Instructies"

Start-Sleep -Seconds 10
$pipFinal        = Get-AzPublicIpAddress -Name $PIPName -ResourceGroupName $ResourceGroupName
$publicIPAddress = $pipFinal.IpAddress

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║                RESTORE OMGEVING GEREED               ║" -ForegroundColor Green
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
Write-Host "  1. Verbind met de server via RDP (opstarten kan even duren)" -ForegroundColor Yellow
Write-Host "     IP adres: $publicIPAddress" -ForegroundColor White
Write-Host ""
Write-Host "  2. Log in met je domain admin credentials" -ForegroundColor Yellow
Write-Host ""
Write-Host "  3. Controleer de Domain Controller:"                                                              -ForegroundColor Yellow
Write-Host "     - Open Active Directory Users and Computers"                                                   -ForegroundColor White
Write-Host "     - Voer uit: hostname (in cmd)"                                                                 -ForegroundColor White
Write-Host "     - Open Services en sorteer op 'Startup Type' 'Automatic', controleer of ze 'Running' zijn!"   -ForegroundColor White
Write-Host "     - Controleer of de FSMO-rollen correct zijn"                                                   -ForegroundColor White
Write-Host "     - Verifieer DNS-functionaliteit"                                                               -ForegroundColor White
Write-Host ""
Write-Host "  4. Verwijder de restore-omgeving na validatie via:"                                               -ForegroundColor Yellow
Write-Host "     Remove-AzResourceGroup -Name $ResourceGroupName -Force"                                        -ForegroundColor White
Write-Host ""
Write-Host "  Succes met de validatie :)"                                                                       -ForegroundColor Green
Write-Host ""

# ─────────────────────────────────────────────────────────────
# STAP 16 – OPRUIMEN (altijd interactief — bewuste keuze)
# ─────────────────────────────────────────────────────────────

Write-Header "STAP 16 – Opruimen (optioneel)"

Write-Host "  Wil je de volledige restore-omgeving verwijderen?" -ForegroundColor Yellow
Write-Host "  Dit verwijdert de resource group inclusief alle resources:" -ForegroundColor White
Write-Host "  → $ResourceGroupName" -ForegroundColor White
Write-Host ""
Write-Host "  ⚠ Dit kan NIET ongedaan worden gemaakt!" -ForegroundColor Red
Write-Host ""

do {
    $cleanupInput = (Read-Host "  Opruimen? (ja/nee, Enter = nee)").Trim().ToLower()
    if ([string]::IsNullOrWhiteSpace($cleanupInput)) { $cleanupInput = "nee" }
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
        if ([string]::IsNullOrWhiteSpace($confirmCleanup)) { $confirmCleanup = "annuleren" }
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
        Write-OK "Succesvol uitgelogd van Azure."
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