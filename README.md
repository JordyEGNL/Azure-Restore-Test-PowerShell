# Restore-AzureVM.ps1
Automatiseert het restoren van een Azure Virtual Machine in een aparte herstelomgeving.

## Gebruik

1. Zorg dat je vooraf de modules **Az.Accounts, Az.Resources, Az.Network, Az.Storage, Az.Compute, Az.RecoveryServices** geïnstalleerd hebt.
2. Start Powershell als Admin.
3. Voer het script uit:

   ```powershell
   .\Restore-AzureVM.ps1
   ```

4. Volg de stappen op het scherm.

## Modules installeren

Installeer de benodigde Az-modules (incl. alle submodules) met:

```powershell
Install-Module -Name Az.Accounts, Az.Resources, Az.Network, Az.Storage, Az.Compute, Az.RecoveryServices -Scope CurrentUser
```

## Functies

- Zet automatisch resource group, netwerk, storage account, VM, NSG en public IP op in een gescheiden omgeving.
- Restore van VM-backup uit Recovery Services Vault (met keuzemenu voor herstelpunten).
- Instructie voor validatie en testomgeving opruimen.

## Opruimen

Verwijder de aangemaakte resources via het script of later handmatig met:

```powershell
Remove-AzResourceGroup -Name <ResourceGroupNaam> -Force
```