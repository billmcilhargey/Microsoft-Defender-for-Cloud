import { expect } from "chai";
import fs from "fs";
import path from "path";

interface Parameter {
  name: string;
  type: number;
  value: string | string[];
  quote?: string;
  query?: string;
  crossComponentResources?: string[];
  typeSettings?: { selectAllValue?: string };
}

interface WorkbookItem {
  name: string;
  type: number;
  content: {
    json?: string;
    query?: string;
    items?: WorkbookItem[];
    parameters?: Parameter[];
    links?: { subTarget: string }[];
    crossComponentResources?: string[];
    noDataMessage?: string;
    noDataMessageStyle?: number;
    showExportToExcel?: boolean;
  };
  conditionalVisibility?: { parameterName: string; value: string };
}

interface Workbook {
  items: WorkbookItem[];
  fallbackResourceIds: string[];
}

const directory = path.resolve("Workbooks", "ARC deployment for multicloud");
const workbook: Workbook = JSON.parse(fs.readFileSync(path.join(directory, "ArcDepolyment.json"), "utf8"));
const template = JSON.parse(fs.readFileSync(path.join(directory, "armTemplate.json"), "utf8"));
const groups = workbook.items.filter(item => item.type === 12);
const queries = groups.reduce<WorkbookItem[]>((items, group) => items.concat(group.content.items || []), [])
  .filter(item => item.type === 3);
const parameters = workbook.items.filter(item => item.type === 9)[0].content.parameters || [];
const inventory = queries.filter(item => item.name.endsWith("ArcServers"));
const discovery = queries.filter(item => item.name.endsWith("DiscoveredInstances"));

describe("Azure Arc server inventory workbook", () => {
  it("keeps the deployed workbook and saved name synchronized", () => {
    expect(JSON.parse(template.resources[0].properties.serializedData)).to.deep.equal(workbook);
    expect(template.parameters.workbookDisplayName.defaultValue)
      .to.equal("Azure Arc Connected Servers - Multicloud and Hybrid Inventory");
    expect(workbook.fallbackResourceIds).to.deep.equal([]);
  });

  it("opens on the complete inventory and provides AWS, GCP, and other-environment tabs", () => {
    const tabs = workbook.items.filter(item => item.type === 11)[0].content.links || [];
    expect(tabs.map(tab => tab.subTarget)).to.deep.equal(["All", "AWS", "GCP", "Other"]);
    expect(parameters.filter(parameter => parameter.name === "SelectedTab")[0].value).to.equal("All");
    expect(groups.map(group => group.conditionalVisibility && group.conditionalVisibility.value))
      .to.deep.equal(["All", "AWS", "GCP", "Other"]);
  });

  it("queries Arc resources directly without requiring assessments, connectors, or a connected agent", () => {
    expect(inventory).to.have.lengthOf(4);
    for (const item of inventory) {
      expect(item.content.query).to.match(/^Resources\r?\n/);
      expect(item.content.query).to.include("type =~ 'microsoft.hybridcompute/machines'");
      expect(item.content.query).not.to.include("SecurityResources");
      expect(item.content.query).not.to.include("join ");
      expect(item.content.query).not.to.match(/\{(?:AWS|GCP).*Connectors\}/);
      expect(item.content.query).to.include("ConnectionStatus = coalesce(tostring(properties.status), 'Unknown')");
      expect(item.content.query).not.to.match(/where .*status/i);
    }
  });

  it("uses provider metadata rather than names or Azure locations, retaining unknown providers", () => {
    for (const item of inventory) {
      expect(item.content.query).to.include("provider = tolower(trim(' ', tostring(properties.cloudMetadata.provider)))");
      expect(item.content.query).not.to.match(/where .*location|where .*name/i);
    }
    const all = inventory.filter(item => item.name === "queryAllArcServers")[0];
    const other = inventory.filter(item => item.name === "queryOtherArcServers")[0];
    expect(all.content.query).not.to.include("| where provider");
    expect(all.content.query).to.include("provider == 'aws', 'AWS', provider == 'gcp', 'GCP', 'Other cloud / on-premises'");
    expect(other.content.query).to.include("provider !in ('aws', 'gcp')");
    expect(other.content.query).to.include("iff(isempty(provider), 'Unknown'");
  });

  it("scopes every table and connector lookup to the selected subscriptions", () => {
    expect(queries).to.have.lengthOf(6);
    for (const item of queries) {
      expect(item.content.crossComponentResources).to.deep.equal(["{Subscriptions}"]);
      expect(item.content.showExportToExcel).to.equal(true);
    }
    for (const parameter of parameters.filter(parameter => parameter.query)) {
      expect(parameter.crossComponentResources).to.deep.equal(["{Subscriptions}"]);
    }
  });

  it("provides an explicit empty-state message on every table without masking query errors", () => {
    for (const item of queries) {
      expect(item.content.noDataMessage).to.be.a("string").and.to.match(/^No .+selected subscriptions/);
      expect(item.content.noDataMessageStyle).to.equal(0);
      expect(item.content.query).not.to.match(/\bisfuzzy\b|\bdatatable\b|\bunion\b/);
    }
  });

  it("supports All and exact multi-select connector filtering instead of substring matching", () => {
    expect(discovery).to.have.lengthOf(2);
    for (const name of ["AWSSecurityConnectors", "GCPSecuityConnectors"]) {
      const parameter = parameters.filter(item => item.name === name)[0];
      expect(parameter.quote).to.equal("'");
      expect(parameter.typeSettings && parameter.typeSettings.selectAllValue).to.equal("*");
      const query = discovery.filter(item => (item.content.query || "").includes("{" + name + "}"))[0];
      expect(query.content.query).to.include("'*' in ({" + name + "}) or securityConnectorId in~ ({" + name + "})");
      expect(query.content.query).not.to.include("has securityConnectorId");
    }
  });

  it("preserves unnamed and single-assessment discovery records and treats name matches only as hints", () => {
    for (const item of discovery) {
      expect(item.content.query).to.include("resourceName = coalesce(tostring(additionalData.ResourceName), tostring(resourceDetails.ResourceName)");
      expect(item.content.query).to.include("extract('([^/]+)$', 1, nativeResourceId)");
      expect(item.content.query).to.include("extract('([^/]+)$', 1, resourceId)");
      expect(item.content.query).not.to.include("assessmentsCount");
      expect(item.content.query).to.include("pack_array(tolower(name), tolower(tostring(properties.osProfile.computerName)), tolower(tostring(properties.machineFqdn)))");
      expect(item.content.query).to.include(") on matchName, subscriptionKey");
      expect(item.content.query).to.include("join kind=leftouter");
      expect(item.content.query).to.include("Not verified - no name match in scope");
      expect(item.content.query).to.include("Possible name match only - verify resource identity");
      expect(item.content.query).not.to.match(/where .*possibleArcResources/i);
    }
  });
});
