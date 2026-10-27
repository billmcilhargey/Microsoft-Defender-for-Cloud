# Microsoft Defender for Storage - Price Estimation Dashboard 4.2

Estimate **30-day costs from seven days of usage** for Defender for Storage and on-upload malware scanning, including accounts where protection is not yet enabled.

**One JSON, two import methods:** [D4StorageARMTemplate.json](D4StorageARMTemplate.json) supports deployment and manual extraction. Creating the workbook does not enable paid Defender plans or scanning.

## Deploy to Azure

<a href="https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FMicrosoft-Defender-for-Cloud%2Fmain%2FWorkbooks%2FMicrosoft%20Defender%20for%20Storage%20Price%20Estimation%2FD4StorageARMTemplate.json" target="_blank"><img src="https://aka.ms/deploytoazurebutton" alt="Deploy to Azure"/></a>

1. Select the button, sign in, and choose a subscription, resource group, and region.
2. Keep `workbookSourceId` as `azure security center`, then select **Review + create > Create**.
3. Open the saved workbook under **Microsoft Defender for Cloud > Workbooks** and select your scope.

**Permissions:** workbook deployment/write access to the resource group, plus read access to selected subscriptions, storage accounts, and metrics.

The button uses upstream `main`; use the deployment link in the PR description to test an unmerged change.
Alternatively, load the same ARM JSON through **Deploy a custom template > Build your own template in the editor**.

## Manual import with the Advanced Editor

1. Download [D4StorageARMTemplate.json](D4StorageARMTemplate.json).
2. From its download directory, copy the decoded workbook content:

   ```powershell
   $template = Get-Content -LiteralPath .\D4StorageARMTemplate.json -Raw | ConvertFrom-Json
   $workbookJson = $template.resources[0].properties.serializedData
   $workbookJson | Set-Clipboard
   ```

3. Open **Defender for Cloud > Workbooks > New > Advanced Editor (</>)**.
4. Choose **Workbook Template** (or **Gallery Template**), replace the contents with your clipboard, and select **Apply > Done Editing > Save**.

Paste the decoded `Notebook/1.0` content, **not the ARM wrapper**. ARM Template mode is for deployment export, not applying workbook content.

Without clipboard access, replace the last command with `$workbookJson | Set-Content -LiteralPath .\Workbook.import.json -Encoding utf8` and copy that generated file's contents.

### Import troubleshooting

| Symptom | Action |
|---|---|
| Invalid workbook content or Apply unavailable | Extract `serializedData` and use **Workbook Template**, not ARM Template mode. |
| No schema request service available (768) | The editor cannot fetch external schemas. Follow the manual-import steps; changing the schema URL does not fix that editor limitation. |

## PowerShell estimation at scale

For large scopes or workbook timeouts, use the [PowerShell estimator](../../Powershell%20scripts/Storage%20Price%20Estimation%20Script/DefenderForStorage-CostEstimation-ResourceLevelVisibility.ps1).
It handles pagination and bounded parallelism without changing Azure resources, and restores your Azure context afterward.

Use **PowerShell 7+**, `Az.Accounts`, and Reader access to the selected scope.
Download the script and run from its [script directory](../../Powershell%20scripts/Storage%20Price%20Estimation%20Script/):

```powershell
Install-Module Az.Accounts -Scope CurrentUser
Connect-AzAccount -TenantId '<tenant-id>'

# All accessible, enabled subscriptions in the signed-in tenant.
.\DefenderForStorage-CostEstimation-ResourceLevelVisibility.ps1

# Selected subscriptions, a 30-day sample, and a modeled scanning cap.
.\DefenderForStorage-CostEstimation-ResourceLevelVisibility.ps1 `
    -SubscriptionIds '<subscription-id-1>,<subscription-id-2>' `
    -SampleDays 30 -ThrottleLimit 5 -MalwareScanningCapGB 10000
```

The script defaults to a seven-day sample. `-OutputPath` changes the default `CostEstimation.csv`; output has one row per account, with totals printed separately.
`StorageAccountCost` is base plus overage; `MalwareScanningCost` is separate; `EstimatedMonthlyCost` includes both. `OldEstimateCost` is the legacy-plan comparison.

## Pricing and limitations

| Component | Default estimate (USD) |
|---|---|
| Base plan | 10/account/month |
| Transaction overage | 0.1492/million above 73 million/account/month |
| On-upload scanning | 0.15/GB |

Override `-CostPerStorageAccount`, `-PricePer1MOverageTransactions`, and `-MalwareScanningPricePerGB` for your agreement.
Check [current pricing](https://azure.microsoft.com/pricing/details/defender-for-cloud/); estimates are not invoices or quotes.

- Transactions cover Blob and File services; scanning uses **Blob upload ingress only** (1 GB = 1,073,741,824 bytes).
  Ingress is a proxy: repeated commits, copies, exclusions, and unsupported blobs can change actual scan volume.
- The script excludes on-demand scanning and additional Storage read, blob-index, and Event Grid charges.
  See [scanning behavior](https://learn.microsoft.com/azure/defender-for-cloud/on-upload-malware-scanning).
- Scanning is modeled as uncapped by default (`-MalwareScanningCapGB -1`). Setting a cap changes the estimate, not Azure settings.
- Missing metrics produce warnings, blank affected costs, and `MetricsStatus=Incomplete`. Such subtotals are **not complete scope totals**.
  HTTP/authentication failures stop the script without exporting a new report.
- Workbook limits can truncate results or cause timeouts. Narrow the scope or use PowerShell; truncated results are not tenant-wide totals.

## Overview

![Workbook overview](WorkbookSample.png)

**Credits:** [Eitan Shteinberg](https://www.linkedin.com/in/eitan-shteinberg/), [Fernanda Vela](https://www.linkedin.com/in/mfvelah/), [Shay Amar](https://www.linkedin.com/in/shay-amar/)
