# Microsoft Defender for Storage - Price Estimation Dashboard 4.2

Estimate the monthly cost of Defender for Storage and on-upload malware scanning across selected storage accounts, whether protection is already enabled or not. The workbook samples the last seven days and projects usage to 30 days.

There is **one JSON source**, [D4StorageARMTemplate.json](D4StorageARMTemplate.json), for both workflows below. It contains an ARM deployment wrapper and the workbook content in `properties.serializedData`. A decoded workbook alone cannot be used with Deploy to Azure.

## Deploy to Azure

<a href="https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FMicrosoft-Defender-for-Cloud%2Fmain%2FWorkbooks%2FMicrosoft%20Defender%20for%20Storage%20Price%20Estimation%2FD4StorageARMTemplate.json" target="_blank"><img src="https://aka.ms/deploytoazurebutton" alt="Deploy to Azure"/></a>

1. Select the button and sign in to Azure.
2. Select your subscription, resource group, and region. Keep `workbookSourceId` as `azure security center` to associate the workbook with Defender for Cloud.
3. Review the parameters, then select **Review + create** and **Create**.
4. Open **Microsoft Defender for Cloud > Workbooks**, open the saved workbook, and select your subscription/storage-account scope.

You need permission to deploy `Microsoft.Insights/workbooks` into the resource group, plus read access to the selected storage accounts and metrics. The template creates only a workbook; it does not enable a paid Defender plan or malware scanning.

The button uses upstream `main`. For an unmerged PR, use its branch-specific deployment link instead. You can also download the same ARM JSON and load it through **Deploy a custom template > Build your own template in the editor**.

## Manual import with the Advanced Editor

1. Download [D4StorageARMTemplate.json](D4StorageARMTemplate.json).
2. From the directory containing the download, run this PowerShell command to copy the decoded workbook content:

   ```powershell
   $template = Get-Content -LiteralPath .\D4StorageARMTemplate.json -Raw | ConvertFrom-Json
   $workbookJson = $template.resources[0].properties.serializedData
   $workbookJson | Set-Clipboard
   ```

3. In **Microsoft Defender for Cloud > Workbooks**, select **New** and open **Advanced Editor** using **</>**.
4. Select **Format: Workbook Template** (called **Gallery Template** in some portal versions), replace all editor content with your clipboard, and select **Apply**.
5. Select **Done Editing** and save.

The pasted content starts with `"version": "Notebook/1.0"`, not `"contentVersion"`. Do not paste the whole ARM JSON into Workbook Template mode, and do not manually unescape the `serializedData` string. The ARM Template editor format is for exporting deployment templates, not applying workbook content.

If clipboard access is unavailable, replace the last command with `$workbookJson | Set-Content -LiteralPath .\Workbook.import.json -Encoding utf8`, then copy that generated file's contents. This is a local extraction, not a second maintained JSON source.

The template uses the HTTPS [ARM resource-group schema](https://learn.microsoft.com/azure/azure-resource-manager/templates/syntax) `2019-04-01`
and [workbook API](https://learn.microsoft.com/azure/templates/microsoft.insights/workbooks) `2023-06-01`.
The workbook content format remains `Notebook/1.0`.
**No schema request service available (768)** is an embedded-editor schema-fetch limitation, not evidence that the deployment JSON is malformed;
changing the schema URL does not add that service.

## PowerShell estimation at scale

Use [DefenderForStorage-CostEstimation-ResourceLevelVisibility.ps1](../../Powershell%20scripts/Storage%20Price%20Estimation%20Script/DefenderForStorage-CostEstimation-ResourceLevelVisibility.ps1)
when the workbook's metrics limits make a large scope impractical.
It follows storage-account pagination, processes accounts with bounded parallelism, and includes **on-upload malware-scanning estimates**.

### Prerequisites and usage

Use PowerShell 7 or later, the `Az.Accounts` module, and a signed-in Azure context. Reader access to subscriptions, storage accounts, and Azure Monitor metrics is required. The script makes read-only ARM requests and does not change Defender settings.

Download the script, then run these examples from its [original script directory](../../Powershell%20scripts/Storage%20Price%20Estimation%20Script/).

```powershell
Install-Module Az.Accounts -Scope CurrentUser
Connect-AzAccount -TenantId '<tenant-id>'

# All enabled subscriptions accessible in the signed-in tenant.
.\DefenderForStorage-CostEstimation-ResourceLevelVisibility.ps1

# Selected subscriptions; arrays and comma-separated IDs are accepted.
.\DefenderForStorage-CostEstimation-ResourceLevelVisibility.ps1 `
    -SubscriptionIds '<subscription-id-1>,<subscription-id-2>' `
    -SampleDays 30 -ThrottleLimit 5 -OutputPath .\CostEstimation.csv

# Model a 10,000-GB monthly on-upload scanning cap per storage account.
.\DefenderForStorage-CostEstimation-ResourceLevelVisibility.ps1 `
    -SubscriptionIds '<subscription-id>' -MalwareScanningCapGB 10000
```

By default, the script samples seven days and projects to 30 days, like the workbook. `-SampleDays 30` uses the full preceding 30 days. It writes one CSV row per account to `CostEstimation.csv` and also returns those rows to the PowerShell pipeline. Totals are printed separately, not inserted as extra CSV headers or footer rows. The caller's Azure context is restored when requests finish or fail.

### Model and limitations

- The defaults match the workbook: USD 10/account/month, USD 0.1492 per million transactions above 73 million/account/month,
  and USD 0.15 per GB of estimated malware scanning.
  Override `-CostPerStorageAccount`, `-PricePer1MOverageTransactions`, and `-MalwareScanningPricePerGB` for your agreement.
  Check [current pricing](https://azure.microsoft.com/pricing/details/defender-for-cloud/); estimates are not a bill or a price quote.
- Transactions include Blob and File services where those endpoints exist. Malware scanning uses only upload-related **Blob ingress**, not File ingress. The GB conversion is 1,073,741,824 bytes, consistent with the workbook.
- Ingress is a proxy for scan volume, not a measurement of completed scans.
  Incremental uploads, repeated commits, server-side copies, scan exclusions, and unsupported blobs can change actual charges.
  On-demand scanning and additional Storage read, blob-index, and Event Grid charges are not included in the script.
  See [on-upload scanning behavior](https://learn.microsoft.com/azure/defender-for-cloud/on-upload-malware-scanning).
- Scanning is uncapped in the model by default (`-MalwareScanningCapGB -1`). An explicit cap models that limit; it does not read or change configured Defender settings. File-only accounts have no Blob malware-scanning charge.
- `StorageAccountCost` contains the base plan plus overage. `MalwareScanningCost` is separate, and `EstimatedMonthlyCost` includes both. `OldEstimateCost` retains the legacy per-transaction comparison.
- Missing metric observations produce warnings, blank affected cost fields, and `MetricsStatus=Incomplete`, not zero-cost estimates. A subtotal must not be interpreted as a complete scope total when any account is incomplete. HTTP/authentication failures stop the run without exporting a new completed report.

## Overview

![Workbook overview](WorkbookSample.png)

The workbook's Azure Monitor queries can time out for large selections and can display only a limited number of accounts. Narrow the scope or use the script above; a truncated workbook result is not a tenant-wide total.

**Credits:** [Eitan Shteinberg](https://www.linkedin.com/in/eitan-shteinberg/), [Fernanda Vela](https://www.linkedin.com/in/mfvelah/), [Shay Amar](https://www.linkedin.com/in/shay-amar/)
