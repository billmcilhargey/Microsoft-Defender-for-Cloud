# Microsoft Defender for Servers - Arc deployment on AWS/GCP machines

**Author: Inbal Silis**

Microsoft Defender for Servers plans require Azure Arc deployment on AWS/GCP machines. This interactive workbook provides an overview of machines in your environment showing their Azure Arc Connected Machine agent deployment status.

There are 2 tabs:

- AWS Account
- GCP Project

Both of them will present lists:

- first list - shows machines with Azure Arc Connected Machine agent and the status of the Agent
- second list - shows machines without Azure Arc Connected Machine agent

Workbook overview:

![Overview](./overview.png)

## Workbook files

| File | Use |
| --- | --- |
| [ArcDepolyment.json](./ArcDepolyment.json) | Paste-ready workbook JSON for the Advanced Editor. |
| [armTemplate.json](./armTemplate.json) | ARM template for deploying a saved workbook. |

The legacy folder and workbook filename are retained for existing links. The [storage price-estimation workbook](../Microsoft%20Defender%20for%20Storage%20Price%20Estimation/README.md) follows the same two-file layout.

## Manual import with the Advanced Editor

1. Open [ArcDepolyment.json](./ArcDepolyment.json), select **Raw**, and copy the entire JSON.
2. Open **Microsoft Defender for Cloud > Workbooks > New > Advanced Editor (</>)**, or **Edit > Advanced Editor** on an existing workbook.
3. Choose **Workbook Template** (**Gallery Template** in some portal versions), replace the editor contents, and select **Apply > Done Editing > Save**.

**No conversion or extraction is required.** Paste the standalone `Notebook/1.0` JSON, not [armTemplate.json](./armTemplate.json). **ARM Template** mode is for deployment export, not applying workbook content.

## Deploy to Azure

<a href="https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FMicrosoft-Defender-for-Cloud%2Frefs%2Fheads%2Fmain%2FWorkbooks%2FARC%2520deployment%2520for%2520multicloud%2FarmTemplate.json" target="_blank"><img src="https://aka.ms/deploytoazurebutton" alt="Deploy to Azure"/></a>
<a href="https://portal.azure.us/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FMicrosoft-Defender-for-Cloud%2Frefs%2Fheads%2Fmain%2FWorkbooks%2FARC%2520deployment%2520for%2520multicloud%2FarmTemplate.json" target="_blank"><img src="https://aka.ms/deploytoazuregovbutton" alt="Deploy to Azure Government"/></a>

1. Select the appropriate button, sign in, and choose a subscription and resource group.
2. Keep `workbookSourceId` as `Azure Security Center`, then select **Review + create > Create**.
3. Open the saved workbook under **Microsoft Defender for Cloud > Workbooks** and select your scope.

**Permissions:** workbook deployment/write access to the resource group, plus read access to the selected subscriptions and resources.

The buttons use upstream `main`. To test an unmerged change, upload that branch's [armTemplate.json](./armTemplate.json) through **Deploy a custom template > Build your own template in the editor**.

## Maintaining the workbook JSON

Keep [ArcDepolyment.json](./ArcDepolyment.json) and the workbook embedded in `resources[0].properties.serializedData` in [armTemplate.json](./armTemplate.json) identical when changing workbook content. The ARM wrapper supplies deployment parameters; it must not change the workbook's queries or layout.
