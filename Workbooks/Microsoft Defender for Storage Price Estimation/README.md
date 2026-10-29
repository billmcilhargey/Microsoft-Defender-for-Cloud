# Microsoft Defender for Storage - Price Estimation

**Version 4.3** | [Version history](#version-history)

Estimate **30-day costs from seven days of usage** for Defender for Storage and on-upload malware scanning, including accounts where protection is not yet enabled.
Associated-cost details use the seven-day sample and are not included in those monthly totals.

Creating or importing this workbook does not enable paid Defender plans or scanning.

## Views

| Tab | Contents |
| --- | --- |
| Defender for Storage coverage | Subscription coverage, plan status, and scanning settings. |
| Storage & scanning costs | Monthly activity-monitoring and on-upload malware-scanning estimates. |
| Scanning associated costs | Event Grid, read-operation, and index-tag estimates from the seven-day sample. |

### Loading and shared data

The cost views share the same selected subscriptions, storage accounts, time range, and activity-metric source. The activity source is defined once, not duplicated for each tab.
Cost groups wait for a nonempty subscription and storage-account selection before loading.

- **Defender for Storage coverage** does not initialize the cost-view metric sources.
- **Storage & scanning costs** loads the monthly estimates without creating the associated-cost table or its additional blob-count metric source.
- **Scanning associated costs** is a separate lazy-loaded group. Its blob-count query, merge, and table are created when that tab first opens, using the shared activity data.

This reduces initial query and table work, not the underlying scope of the shared activity query. Once opened, groups can remain loaded; later scope changes can refresh previously opened views, and metric reuse depends on portal caching. Large selections can still time out.

**In trial** shows **Yes** when trial time remains, **No** when the reported remaining time is zero (`PT0S`), and **Unknown** when trial data is unavailable.

**Estimated monthly transactions** and **Overage transactions** use automatic count units (K/M/B).
**Estimated monthly uploaded** uses automatic size units (MB/GB/TB). **Malware scanning cap (GB/month)** is the monthly limit per storage account.
Display units do not change numeric sorting, totals, or the GB-based scanning-cost calculation.

**Monthly activity monitoring cost** and **Monthly malware scanning cost** are monthly estimates displayed as USD with two decimal places, matching the storage account cost and overage charge columns.

## Workbook files

| File | Use |
| --- | --- |
| [D4StorageDeployment.json](./D4StorageDeployment.json) | Paste-ready workbook JSON for the Advanced Editor. |
| [armTemplate.json](./armTemplate.json) | ARM template for deploying a saved workbook. |

The workbook header links to the published GitHub README for usage guidance and version history. Before this PR is merged, use this branch's README for the latest changes.

## Manual import with the Advanced Editor

1. Open [D4StorageDeployment.json](./D4StorageDeployment.json), select **Raw**, and copy the entire JSON.
2. Open **Microsoft Defender for Cloud > Workbooks > New > Advanced Editor (</>)**, or **Edit > Advanced Editor** on an existing workbook.
3. Choose **Workbook Template** (**Gallery Template** in some portal versions), replace the editor contents, and select **Apply > Done Editing > Save**.

**No conversion or extraction is required.** Paste the standalone workbook JSON, not [armTemplate.json](./armTemplate.json).

## Deploy to Azure

**PR preview - current v4.3 changes**

<a href="https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fbillmcilhargey%2FMicrosoft-Defender-for-Cloud%2Frefs%2Fheads%2Ffix%2Fstorage-estimator-v4-2%2FWorkbooks%2FMicrosoft%2520Defender%2520for%2520Storage%2520Price%2520Estimation%2FarmTemplate.json" target="_blank">
  <img src="https://aka.ms/deploytoazurebutton" alt="Deploy PR preview to Azure"/>
</a>

**Published workbook - available after merge**

<a href="https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FMicrosoft-Defender-for-Cloud%2Frefs%2Fheads%2Fmain%2FWorkbooks%2FMicrosoft%2520Defender%2520for%2520Storage%2520Price%2520Estimation%2FarmTemplate.json" target="_blank"><img src="https://aka.ms/deploytoazurebutton" alt="Deploy to Azure"/></a>

1. Select the appropriate button, sign in, and choose a subscription, resource group, and region.
2. Keep `workbookSourceId` as `azure security center`, then select **Review + create > Create**.
3. Open the saved workbook under **Microsoft Defender for Cloud > Workbooks** and select your scope.

Importing JSON does not rename an existing saved workbook; update its saved name separately.

**Permissions:** workbook deployment/write access to the resource group, plus read access to selected subscriptions, storage accounts, and metrics.

The preview button uses this PR's branch; the published button uses upstream `main`. Alternatively, upload [armTemplate.json](./armTemplate.json) through **Deploy a custom template > Build your own template in the editor**.

## Maintaining the workbook JSON

Keep the standalone workbook JSON identical to `resources[0].properties.serializedData` in the ARM template when editing.

## PowerShell estimation at scale

For large scopes or timeouts, use the [PowerShell estimator](../../Powershell%20scripts/Storage%20Price%20Estimation%20Script/DefenderForStorage-CostEstimation-ResourceLevelVisibility.ps1).
It also reports automatic upload-size units while preserving numeric byte/GB fields for sorting and totals.
See its [README](../../Powershell%20scripts/Storage%20Price%20Estimation%20Script/README.md#defenderforstorage-costestimation-resourcelevelvisibilityps1) for prerequisites, examples, CSV fields, and pricing options.

## Pricing and limitations

- Estimates are not invoices or quotes; check [current pricing](https://azure.microsoft.com/pricing/details/defender-for-cloud/) and your agreement.
- Upload ingress is a proxy for scanned volume, not measured scanning or billing data. Review incomplete or errored results before using totals.
- The coverage cap is informational; workbook scanning-cost estimates do not apply it. The PowerShell estimator offers a separate modeled cap.
- Large scopes can be truncated or time out. Narrow the selection or use PowerShell; partial results are not tenant-wide totals.

## Troubleshooting

**No "matrix" implementation available** in **Read Operations Associated Cost** is a workbook formula-evaluation error, not a malware finding or an account protection status.
Earlier copies wrapped the entire read-operation expression in square brackets, incorrectly requesting a matrix instead of a numeric cost.
Both affected calculated columns now use `(["eventgrid"] / 10000) * 0.005`; the brackets around the column reference are required.

Only rows that evaluate the faulty expression show the error. Rows that take the existing empty-metric fallback can show `$0.00` instead; small calculated amounts can also round to `$0.00`.
Neither an empty-metric fallback nor a rounded display confirms zero billable usage.

If a saved workbook still shows the message, reimport the updated [standalone workbook JSON](./D4StorageDeployment.json), or redeploy the updated [ARM template](./armTemplate.json).
Until corrected, treat affected costs as **Not calculated**, not zero, and related totals as incomplete.

## Overview

![Workbook overview](WorkbookSample.png)

**Credits:** [Eitan Shteinberg](https://www.linkedin.com/in/eitan-shteinberg/), [Fernanda Vela](https://www.linkedin.com/in/mfvelah/), [Shay Amar](https://www.linkedin.com/in/shay-amar/)

## Version history

| Version | Changes |
| --- | --- |
| 4.3 | Split the cost views into **Storage & scanning costs** and **Scanning associated costs**. Kept one shared activity source and deferred the blob-count source and associated-cost table until their tab first opens. Added a GitHub documentation link in the workbook header and documented loading behavior, sampling periods, and version history. |
| 4.2 | Added paste-ready workbook JSON and a separate ARM deployment template, clearer count and size units, consistent USD cost formatting and headings, explicit trial statuses, and the PowerShell estimator workflow. Corrected the matrix-producing read-operation formulas and explained calculation errors, incomplete totals, and zero-display caveats. |
