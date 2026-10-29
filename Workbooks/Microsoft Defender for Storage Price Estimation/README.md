# Microsoft Defender for Storage - Price Estimation

**Version 4.2**

Estimate **30-day costs from seven days of usage** for Defender for Storage and on-upload malware scanning, including accounts where protection is not yet enabled.

Creating or importing this workbook does not enable paid Defender plans or scanning.

## Views

| Tab | Contents |
| --- | --- |
| Defender for Storage coverage | Subscription coverage, plan status, and scanning settings. |
| Cost estimation | Estimated activity-monitoring, malware-scanning, and associated costs. |

**Estimated monthly uploaded** uses automatic size units (MB/GB/TB). **Malware scanning cap (GB/month)** is the monthly limit per storage account.

## Workbook files

| File | Use |
| --- | --- |
| [D4StorageDeployment.json](./D4StorageDeployment.json) | Paste-ready workbook JSON for the Advanced Editor. |
| [armTemplate.json](./armTemplate.json) | ARM template for deploying a saved workbook. |

## Manual import with the Advanced Editor

1. Open [D4StorageDeployment.json](./D4StorageDeployment.json), select **Raw**, and copy the entire JSON.
2. Open **Microsoft Defender for Cloud > Workbooks > New > Advanced Editor (</>)**, or **Edit > Advanced Editor** on an existing workbook.
3. Choose **Workbook Template** (**Gallery Template** in some portal versions), replace the editor contents, and select **Apply > Done Editing > Save**.

**No conversion or extraction is required.** Paste the standalone workbook JSON, not [armTemplate.json](./armTemplate.json).

## Deploy to Azure

<a href="https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FMicrosoft-Defender-for-Cloud%2Frefs%2Fheads%2Fmain%2FWorkbooks%2FMicrosoft%2520Defender%2520for%2520Storage%2520Price%2520Estimation%2FarmTemplate.json" target="_blank"><img src="https://aka.ms/deploytoazurebutton" alt="Deploy to Azure"/></a>

1. Select the button, sign in, and choose a subscription, resource group, and region.
2. Keep `workbookSourceId` as `azure security center`, then select **Review + create > Create**.
3. Open the saved workbook under **Microsoft Defender for Cloud > Workbooks** and select your scope.

Importing JSON does not rename an existing saved workbook; update its saved name separately.

**Permissions:** workbook deployment/write access to the resource group, plus read access to selected subscriptions, storage accounts, and metrics.

The button uses upstream `main`. To test an unmerged change, upload that branch's [armTemplate.json](./armTemplate.json) through **Deploy a custom template > Build your own template in the editor**.

## Maintaining the workbook JSON

Keep the standalone workbook JSON identical to `resources[0].properties.serializedData` in the ARM template when editing.

## PowerShell estimation at scale

For large scopes or timeouts, use the [PowerShell estimator](../../Powershell%20scripts/Storage%20Price%20Estimation%20Script/DefenderForStorage-CostEstimation-ResourceLevelVisibility.ps1).
See its [README](../../Powershell%20scripts/Storage%20Price%20Estimation%20Script/README.md#defenderforstorage-costestimation-resourcelevelvisibilityps1) for prerequisites, examples, CSV fields, and pricing options.

## Pricing and limitations

- Estimates are not invoices or quotes; check [current pricing](https://azure.microsoft.com/pricing/details/defender-for-cloud/) and your agreement.
- Upload ingress is a proxy for scanned volume, not measured scanning or billing data. Review incomplete or errored results before using totals.
- Large scopes can be truncated or time out. Narrow the selection or use PowerShell; partial results are not tenant-wide totals.

## Overview

![Workbook overview](WorkbookSample.png)

**Credits:** [Eitan Shteinberg](https://www.linkedin.com/in/eitan-shteinberg/), [Fernanda Vela](https://www.linkedin.com/in/mfvelah/), [Shay Amar](https://www.linkedin.com/in/shay-amar/)
