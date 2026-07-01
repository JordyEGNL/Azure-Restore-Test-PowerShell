# Azure-Restore-Test-PowerShell

> [!NOTE]
> Code is geschreven met behulp van Claude Sonet, alle code is gecontroleerd door mijzelf en wordt uitvoerig getest in een testomgeving!

Automatiseert het herstel van een Azure Virtual Machine (VM) naar een gescheiden herstelomgeving via PowerShell.

---

## Beschrijving

Dit script begeleidt het herstellen van een Azure VM-backup vanuit een Recovery Services Vault in een aparte, tijdelijke omgeving. Ideaal voor test/restores of validaties.

---

## Vereisten

- PowerShell 7.x of PowerShell 5.1
- Azure PowerShell modules:
  - Az.Accounts
  - Az.Resources
  - Az.Network
  - Az.Storage
  - Az.Compute
  - Az.RecoveryServices
- Geldige Azure inloggegevens of Service Principal credentials
- Minimaal Contributor role actief

---

## Installatie modules

Installeer de benodigde modules met:

```powershell
Install-Module -Name Az.Accounts, Az.Resources, Az.Network, Az.Storage, Az.Compute, Az.RecoveryServices -Scope CurrentUser
```

---

## Gebruik

Voer het script uit in PowerShell:

### Interactief

```powershell
.\Restore-AzureVM.ps1
```

### Automatisch (via service principal)

```powershell
.\Restore-AzureVM.ps1 -TenantID "0123456" |
-AppId "123456" |
-AppSecret "ABCDEFG" ` |
-OriginalVM "DC01" |
-Subscription "MySub" |
-CustomerName "Contoso" |
-Ticket "OT2606-01234" |
-CreatedBy "Jan de Vries" |
-Region "westeurope" |
-RecoveryPointIndex 1 |
-SkipConfirmation
```

### Extra opties

- `-UseExistingSession` : Gebruik bestaande Azure sessie
- `-SkipConfirmation` : Sla alle bevestigingsvragen over

---

## Parameters

| Parameter            | Beschrijving                                         | Verplicht   |
|----------------------|------------------------------------------------------|-------------|
| `OriginalVM`         | Naam van te herstellen VM                            | Nee         |
| `Subscription`       | Naam of ID van Azure Subscription                    | Nee         |
| `CustomerName`       | Naam van de klant                                    | Nee         |
| `Ticket`             | Ticketnummer of referentie                           | Nee         |
| `CreatedBy`          | Naam van de uitvoerder                               | Nee         |
| `Region`             | Azure regio (bv. westeurope, northeurope)            | Ne          |
| `TenantID`           | Service Principal Tenant ID                          | Nee         |
| `AppId`              | Service Principal applicatie ID                      | Nee         |
| `AppSecret`          | Service Principal secret                             | Nee         |
| `UseExistingSession` | Gebruik bestaande login sessie (switch)              | Nee         |
| `SkipConfirmation`   | Sla bevestigingsvragen over (switch)                 | Nee         |
| `RecoveryPointIndex` | Index van te kiezen herstelpunt (default: 0)         | Nee         |

---

## Opruimen

Verwijder de aangemaakte resources eenvoudig met:

```powershell
Remove-AzResourceGroup -Name <ResourceGroupNaam> -Force
```