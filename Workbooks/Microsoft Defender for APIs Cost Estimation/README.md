# Microsoft Defender for APIs - Price Estimation

**Version 1.5**

A self-contained, live workbook following the
[Defender for Storage Price Estimation](../Microsoft%20Defender%20for%20Storage%20Price%20Estimation/README.md)
scope selectors and native data sources, with subscription coverage, API details
and cost estimation together on **one continuous page**. There are no separate
coverage or cost tabs; scroll down to see the available sections.

All queries and calculations are **embedded in the workbook JSON**. No PowerShell,
build step, uploaded snapshot or custom ingestion is required. Creating or
importing this workbook does not enable a paid plan or onboard APIs.

## Single-page layout

| Section | Contents |
| --- | --- |
| Defender for APIs coverage | All, several or one subscription: enablement, configured P1-P5 plan, trial status and reported onboarding assessments. All/several APIM services show a live service overview; a single matching service also enables full API inventory. |
| APIM service overview | Services matching the All/several/one service scope, with tiers, regions and reported API assessments. |
| API coverage details | Full child-API inventory and eligibility/protection totals when exactly one APIM service is resolved. |
| Cost estimation | Native Azure Monitor request totals, five-plan costs including overages, rollout/current-coverage recommendations and modeled savings, on the same page as coverage. |
| Optional log comparison and data quality | Existing subscription-wide log model, scope assumptions and evidence behind calculated or withheld recommendations. |

Sections requiring a single service or an optional workspace remain conditional
on those selections. Removing tabs does not bypass scope or data-quality guards.

**Enabled** is the subscription setting, not proof that every API is onboarded.
**In trial** is Yes when reported trial time remains, No for `PT0S`, and Unknown
when trial data is unavailable.

Costs display as **USD with two decimal places**. Request counts and costs remain
numeric for sorting and export. Empty cost cells mean **not calculated**, not zero.
The native metric grid hides the raw **Requests Timeline** array and keeps the
numeric **Requests (Sum)** total. This display change does not change call counts
or cost calculations.

## Workbook files

| File | Use |
| --- | --- |
| [D4ApisDeployment.json](./D4ApisDeployment.json) | Paste-ready workbook JSON with all live queries built in. |
| [armTemplate.json](./armTemplate.json) | ARM template deploying the same saved workbook. |

This directory contains only those two JSON files and this README.

## Manual import with the Advanced Editor

1. Open [D4ApisDeployment.json](./D4ApisDeployment.json), select **Raw**, and copy
   the entire JSON.
2. Open **Microsoft Defender for Cloud > Workbooks > New > Advanced Editor (</>)**,
   or **Edit > Advanced Editor** on an existing workbook.
3. Choose **Workbook Template** (**Gallery Template** in some portal versions),
   replace the contents, then select **Apply > Done Editing > Save**.
4. Choose **All subscriptions**, several subscriptions, or one subscription.
   The coverage table works without an APIM selection.
5. Choose **All APIM services** (the default), several services, or one service.
   The overview lists matching services and their reported API assessments.
6. For full API inventory and metric-based recommendations, clear All and select
   **one service**. Its subscription is derived automatically. Coverage, API
   inventory and cost sections appear together below; no tab switching is needed.

**No conversion or extraction is required.** Paste the standalone workbook JSON,
not [armTemplate.json](./armTemplate.json). Use **Refresh** to rerun live queries.
Importing JSON does not rename an existing saved workbook; update its name
separately.

## Deploy to Azure

1. Open **Deploy a custom template > Build your own template in the editor**.
2. Load [armTemplate.json](./armTemplate.json) and select **Save**.
3. Choose a subscription, resource group and region.
4. Keep `workbookSourceId` as `azure security center`, then select
   **Review + create > Create**.
5. Open the saved workbook under **Microsoft Defender for Cloud > Workbooks**.

Only a `Microsoft.Insights/workbooks` resource is deployed. Reuse an existing
workbook's GUID as `workbookId` when updating; the default `newGuid()` otherwise
creates another workbook.

**Permissions:** read access to selected subscriptions, APIM services/APIs,
metrics, Defender pricing and API collections. Optional log queries require
Log Analytics query access. Saving/deploying also requires workbook-write
permission on the destination resource group. No plan-write or API-onboarding
permission is needed.

## Live querying and scope

Like the Storage workbook, this workbook uses **Azure Resource Graph** for
coverage and a native **Azure Monitor Metrics** control for request usage.
**All subscriptions** is the default coverage scope and includes only subscriptions
you can access. You can also select a subset. Resource Graph's indexed pricing,
trial and assessment data can lag direct ARM configuration.
**All APIM services** is also a default option. It applies within the selected
subscriptions, not outside that scope. A live service overview shows the matching
services, tiers, regions and reported API onboarding assessments. It is not a
complete child-API inventory.
The embedded queries also use:

- **ARM GET/GETARRAY** for the actual API inventory, APIM tier/regions, configured
  subscription plan and onboarded collections. `GETARRAY` follows list pagination.
- **Azure Monitor Metrics REST** for per-API `Requests`, `Total`, `interval=FULL`
  over the same last-30-day window. These feed eligibility-aware calculations;
  the native metric grid shows whole-service requests, not protected traffic.
- **Optional existing Log Analytics gateway logs** for a subscription-wide model
  across multiple APIM services.

APIM differs from Storage: its API child inventory is not indexed in Resource
Graph, and APIM metrics cannot use Storage's multi-resource selection pattern.
The coverage table evaluates all selected subscriptions. The service overview
follows the APIM selection; subscription coverage still describes entire
subscriptions rather than a selected APIM subset.

API details and cost models evaluate **one APIM service and its subscription at a
time**. A hidden resource picker resolves only an exactly-one-service scope;
All/several selections with multiple matching services leave detail queries
deferred. An All scope containing only one service can safely resolve that service.
An independent readiness check also verifies that the resolved resource matches
that sole service, so a stale picker value cannot start detail requests.
The detail subscription is derived from the selected APIM resource, not from the All marker
or a list of subscriptions. No All marker, unresolved first-resource marker or
resource list is passed to the per-service ARM/Metrics calls.
Its API counts are selected-service counts, not a multi-service fleet total.
Reported assessment counts are labeled separately because they can lag or omit
APIs; they are not a replacement for full inventory.

### Cost recommendations

Selecting All APIM services provides the service overview; it does **not**
enumerate every child API, sum per-service traffic, or generate a fleet-wide
recommendation. Select one service for the detail view. Selecting All
subscriptions does **not** aggregate cost estimates across subscriptions. The
optional log comparison also stays within the selected APIM's subscription.

The metric-based comparison is a subscription recommendation only when the
selected APIM is the subscription's **sole APIM service**. It compares:

1. **All eligible APIs**: least-cost plan for a prospective full rollout.
2. **Currently onboarded APIs**: configured plan versus least-cost plan for today's
   onboarded set, modeled over the full 30 days, including potential monthly savings.

All P1-P5 fees **plus overages** are compared. An existing plan tied for minimum
modeled cost is retained. For example, two million calls favor P1 at USD 400,
even though they exceed its one-million-call allowance; P2 would cost USD 700.

For subscriptions with multiple APIM services, these metric-based recommendations
are withheld rather than treating one instance as the subscription total.
In the **Cost estimation** section, select one service to identify the subscription, then
optionally select an existing Log Analytics workspace for the full subscription:

- Requires **Analytics-plan** `ApiManagementGatewayLogs` or legacy
  `AzureDiagnostics` `GatewayLogs`, not Basic/Auxiliary tables.
- Confirm complete, unsampled, managed-gateway-only logging with no relevant
  exclusions or transformations for the full 30 days. This is a declared
  assumption, not an automatic logging audit.
- Missing onboarded API records withhold current-scope guidance. Overlapping
  legacy/resource-specific schemas are blocked; select one schema if necessary.
- Full-rollout log modeling also requires confirmation that **every API** across
  the subscription is eligible and every service is represented. Otherwise that
  rollout estimate remains withheld.

The workbook does not enable diagnostic settings, change retention or ingest logs.

## Pricing and limitations

- Embedded **USD public reference pricing**, verified **2026-10-29**: P1-P5
  monthly fees are 200, 700, 5,000, 7,000 and 50,000; included calls are 1M, 5M,
  50M, 100M and 1B. Overage rates per call are 0.00020, 0.00014, 0.00010,
  0.00007 and 0.00005. Verify [current pricing](https://azure.microsoft.com/pricing/details/defender-for-cloud/)
  and your agreement before acting.
- The supported scope is managed-gateway REST API collections on documented
  classic Developer, Basic, Standard and Premium tiers in supported commercial
  regions. Consumption and unsupported API types are excluded. Unverified
  tiers/regions require review. Workspace APIs and self-hosted traffic are outside
  this scope. Revisions share one logical API collection.
- Grids display at most **1,000 rows**. Resource Graph calculations expand at most
  **2,000 raw rows per array**; exceeding the required API, collection or metric
  limit withholds recommendations. Partial counts are labeled as lower bounds.
  At large subscription scopes, a truncated coverage grid is not a tenant-wide
  total; narrow the subscription selection.
- Split API traffic must reconcile to whole-service totals. Missing/null samples,
  read failures, unknown plans, pending onboarding and incomplete required scope
  mean **not calculated**, never zero. Explicit numeric zero samples are valid.
- This is a current-configuration planning model, not an invoice or a detection
  health attestation. Historical onboarding/deletions, recent APIs, calendar-month
  entitlements, hourly fees, trials, agreements, credits and seasonality can differ.
  Recent traffic is not extrapolated to invent a month.

## Maintaining the workbook JSON

Edit queries and formatting **directly in the standalone workbook JSON** or the
portal Advanced Editor. Keep it identical to the JSON parsed from
`resources[0].properties.serializedData` in [armTemplate.json](./armTemplate.json).
Update both files together; no separate query folder, build script or runtime
dependency is needed.

Local schema, KQL-parser and calculation checks do not replace a live Azure
portal import or verification of actual telemetry in an approved environment.

## Troubleshooting

If **Requests Timeline** displays an array such as `[8,30,17,...]`, the timeline
column is using a plain-cell renderer instead of being hidden. This is a grid
formatting issue, not a Defender finding or a request-total error.
The workbook hides the native metric-ID timeline column and its display-name
alias with formatter `5`, matching the Storage workbook's existing pattern.
Reimport the updated [workbook JSON](./D4ApisDeployment.json), or redeploy
[armTemplate.json](./armTemplate.json), to update an older saved copy.

## Optional PowerShell estimation at scale

The [PowerShell estimator](../../Powershell%20scripts/Defender%20APIs%20Cost%20Estimator/d4apis_cost_estimator_v1.ps1)
and its [README](../../Powershell%20scripts/Defender%20APIs%20Cost%20Estimator/readme.md)
are independent CSV/JSON reporting tools. The workbook never calls the script,
ingests its output or requires it for refresh.

## Version history

- **1.5** - Combined coverage, API inventory and cost sections onto one page;
  removed tab dependencies and hid the raw Requests Timeline array without
  changing usage or pricing queries.
- **1.4** - All/multi-APIM selection and live service overview, with full
  inventory/metrics deferred unless the scope resolves to exactly one service.
- **1.3** - All/multi-subscription coverage and APIM discovery; derive the detail
  subscription from the selected service and defer its ARM queries until selected.
- **1.2** - Storage-style coverage/cost layout, native metric grid, API coverage
  totals, embedded queries and two-file JSON delivery with README.
- **1.1** - Native live Azure queries, eligibility-aware plan comparison and optional
  multi-APIM log model.

## References

- [Workbook native data sources and pagination](https://learn.microsoft.com/azure/azure-monitor/visualize/workbooks-data-sources)
- [Defender for APIs support](https://learn.microsoft.com/azure/defender-for-cloud/defender-for-apis-prepare)
- [Thirty-day sizing and billing guidance](https://learn.microsoft.com/azure/defender-for-cloud/defender-for-apis-deploy)
- [APIM metric reference](https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-apimanagement-service-metrics)
