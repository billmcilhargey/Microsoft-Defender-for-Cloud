BeforeAll {
    $script:estimatorDirectory = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:estimatorDirectory 'DefenderForApisCostEstimator.psm1') -Force
    $script:pricing = Get-D4ApiPricing
    $script:createdRestStub = -not (Get-Command Invoke-AzRestMethod -ErrorAction SilentlyContinue)
    if ($script:createdRestStub) {
        function global:Invoke-AzRestMethod {
            [CmdletBinding()]
            param([string]$Method, [string]$Path, [string]$Uri)
            throw "These tests must mock ARM; no Azure request is permitted: $Method $Path$Uri"
        }
    }

    function Get-TestApi {
        param(
            [long]$Calls = 1000000,
            [string]$Usage = 'Observed',
            [string]$Eligibility = 'Eligible',
            [string]$Onboarding = 'Onboarded'
        )
        [pscustomobject]@{
            SubscriptionID = '00000000-0000-0000-0000-000000000001'; SubscriptionName = 'Test subscription'
            Eligibility = $Eligibility; OnboardingStatus = $Onboarding; Requests30Days = $Calls; UsageStatus = $Usage
            ProtectionStatus = $(if ($Onboarding -eq 'Onboarded') { 'Onboarded - plan enabled' } else { 'Not onboarded' })
        }
    }
    function Get-TestEstimate {
        param(
            [object[]]$Apis = @((Get-TestApi)),
            [bool]$InventoryComplete = $true,
            [bool]$OnboardingComplete = $true,
            [string]$Status = 'Enabled',
            [string]$Plan = 'P2'
        )
        Get-D4ApiSubscriptionEstimate -SubscriptionID '00000000-0000-0000-0000-000000000001' `
            -SubscriptionName 'Test subscription' -Apis $Apis -Services @() -Plans $script:pricing.plans `
            -InventoryComplete $InventoryComplete -OnboardingComplete $OnboardingComplete `
            -DefenderStatus $Status -CurrentPlan $Plan
    }
    function Get-TestMetric {
        param([object[]]$Series = @(), [string]$ErrorCode = 'Success')
        @{
            timespan = '2026-09-29T12:00:00Z/2026-10-29T12:00:00Z'
            value = @(@{ name = @{ value = 'Requests' }; errorCode = $ErrorCode; timeseries = $Series })
        }
    }
    function Get-TestSeries {
        param([AllowNull()][object]$Total = 1, [string]$ApiId = 'orders')
        @{
            metadatavalues = @(@{ name = @{ value = 'ApiId' }; value = $ApiId })
            data = @(@{ total = $Total })
        }
    }
    function Get-TestService {
        param([string]$Sku = 'Standard', [string]$Location = 'eastus')
        @{
            id = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.ApiManagement/service/test-apim'
            name = 'test-apim'; sku = @{ name = $Sku }; location = $Location; properties = @{}
        }
    }
}

Describe 'Pricing and overage calculations' {
    It 'validates the reference pricing and preserves decimal overage rates' {
        $script:pricing.plans.Count | Should -Be 5
        $script:pricing.plans[0].overagePerCall | Should -Be 0.0002
        $script:pricing.plans[4].includedCalls | Should -Be 1000000000
    }

    It 'charges the fixed fee through each entitlement limit and overage only above it' {
        foreach ($plan in $script:pricing.plans) {
            foreach ($calls in @(
                ([long]$plan.includedCalls - 1), [long]$plan.includedCalls,
                ([long]$plan.includedCalls + 1), ([long]$plan.includedCalls + 1000000)
            )) {
                $cost = Get-D4ApiPlanCost -Calls $calls -Plans @($plan)
                $expectedOverage = [Math]::Max(0, $calls - [long]$plan.includedCalls)
                $cost.OverageCalls | Should -Be $expectedOverage
                $cost.EstimatedMonthlyCost | Should -Be (
                    [Math]::Round([decimal]$plan.monthlyFee + [decimal]$expectedOverage * [decimal]$plan.overagePerCall, 2))
            }
        }
    }

    It 'selects minimum total cost rather than the first plan with a sufficient allowance' -ForEach @(
        @{ Calls = 0; Plan = 'P1' },
        @{ Calls = 2000000; Plan = 'P1' },
        @{ Calls = 3600000; Plan = 'P2' },
        @{ Calls = 36000000; Plan = 'P3' },
        @{ Calls = 71000000; Plan = 'P4' },
        @{ Calls = 715000000; Plan = 'P5' },
        @{ Calls = 2000000000; Plan = 'P5' }
    ) {
        $best = Get-D4ApiPlanCost -Calls $Calls -Plans $script:pricing.plans |
            Sort-Object EstimatedMonthlyCost, Plan | Select-Object -First 1
        $best.Plan | Should -Be $Plan
    }

    It 'retains a configured plan when its rounded cost ties the minimum' {
        $result = Get-TestEstimate -Apis @((Get-TestApi -Calls 3500000)) -Plan P2
        $result.Summary.CurrentScopeRecommendedPlan | Should -Be P2
        $result.Summary.EstimatedMonthlySavings | Should -Be 0
        $result.Summary.OptimizationStatus | Should -Be 'Best fit for modeled traffic'
    }

    It 'rejects invalid overrides instead of falling back to default prices' {
        $path = Join-Path $TestDrive 'invalid-pricing.json'
        $modified = Get-Content -LiteralPath (Join-Path $script:estimatorDirectory 'pricing.json') -Raw | ConvertFrom-Json
        $modified.plans[0].monthlyFee = -1
        $modified | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path
        { Get-D4ApiPricing -Path $path } | Should -Throw "*Invalid 'monthlyFee'*"
    }

    It 'rejects negative traffic' {
        { Get-D4ApiPlanCost -Calls -1 -Plans $script:pricing.plans } | Should -Throw
    }
}

Describe 'Coverage and scenario separation' {
    It 'models all eligible APIs separately from the current onboarded set' {
        $result = Get-TestEstimate -Apis @(
            (Get-TestApi -Calls 1000000),
            (Get-TestApi -Calls 50000000 -Onboarding 'Not onboarded')
        )
        $result.Summary.TotalRequests | Should -Be 51000000
        $result.Summary.RecommendedPlan | Should -Be P3
        $result.Summary.OnboardedRequests | Should -Be 1000000
        $result.Summary.CurrentScopeRecommendedPlan | Should -Be P1
        $result.Summary.CurrentPlanEstimatedCost | Should -Be 700
        $result.Summary.EstimatedMonthlySavings | Should -Be 500
        $result.Summary.UnprotectedEligibleApis | Should -Be 1
        $result.PlanCosts.Count | Should -Be 10
    }

    It 'does not block a complete current-scope model for missing usage on an unprotected API' {
        $result = Get-TestEstimate -Apis @(
            (Get-TestApi),
            (Get-TestApi -Usage 'No data' -Onboarding 'Not onboarded')
        )
        $result.Summary.RecommendedPlan | Should -BeNullOrEmpty
        $result.Summary.TotalRequests | Should -BeNullOrEmpty
        $result.Summary.CurrentScopeRecommendedPlan | Should -Be P1
        $result.Summary.EstimateStatus | Should -Be 'Incomplete telemetry'
    }

    It 'withholds both scenarios for an incomplete API inventory' {
        $result = Get-TestEstimate -InventoryComplete $false
        $result.Summary.RecommendedPlan | Should -BeNullOrEmpty
        $result.Summary.CurrentScopeRecommendedPlan | Should -BeNullOrEmpty
        $result.PlanCosts.Count | Should -Be 0
        $result.Summary.InventoryStatus | Should -Be Incomplete
    }

    It 'withholds current plan fit when the onboarding list cannot be read' {
        $result = Get-TestEstimate -OnboardingComplete $false
        $result.Summary.RecommendedPlan | Should -Be P1
        $result.Summary.OnboardedApis | Should -BeNullOrEmpty
        $result.Summary.EstimatedMonthlySavings | Should -BeNullOrEmpty
    }

    It 'does not assume that a missing pricing resource means Disabled' {
        $result = Get-TestEstimate -Status Unknown -Plan ''
        $result.Summary.DefenderForApisStatus | Should -Be Unknown
        $result.Summary.UnprotectedEligibleApis | Should -BeNullOrEmpty
        $result.Summary.CurrentPlanEstimatedCost | Should -BeNullOrEmpty
    }

    It 'reports disabled subscription coverage without inventing current-plan savings' {
        $api = Get-TestApi
        $api.ProtectionStatus = 'Subscription plan disabled'
        $result = Get-TestEstimate -Apis @($api) -Status Disabled
        $result.Summary.UnprotectedEligibleApis | Should -Be 1
        $result.Summary.RecommendedPlan | Should -Be P1
        $result.Summary.EstimatedMonthlySavings | Should -BeNullOrEmpty
    }

    It 'distinguishes no eligible APIs from missing traffic' {
        $result = Get-TestEstimate -Apis @()
        $result.Summary.EstimateStatus | Should -Be 'No eligible APIs'
        $result.Summary.RecommendedPlan | Should -BeNullOrEmpty
        $result.Summary.CurrentPlanEstimatedCost | Should -Be 700
        $result.Summary.OptimizationStatus | Should -Be 'Enabled with no onboarded APIs - review coverage'
    }

    It 'does not describe incomplete onboarded telemetry or an unknown subplan as optimized' {
        (Get-TestEstimate -Apis @((Get-TestApi -Usage 'No data'))).Summary.OptimizationStatus |
            Should -Be 'Incomplete onboarded-API telemetry'
        (Get-TestEstimate -Plan 'FuturePlan').Summary.CurrentPlanEstimatedCost | Should -BeNullOrEmpty
    }

    It 'requires verification of pending onboarding and uncertain support' {
        (Get-TestEstimate -Apis @((Get-TestApi -Onboarding 'Review provisioning: Creating'))).Summary.OptimizationStatus |
            Should -Be 'Incomplete onboarding inventory'
        (Get-TestEstimate -Apis @((Get-TestApi -Eligibility Review))).Summary.RecommendedPlan | Should -BeNullOrEmpty
    }
}

Describe 'Documented eligibility' {
    It 'recognizes classic managed REST APIs, including the omitted HTTP type' {
        $result = Get-D4ApiEligibility -Service (Get-TestService) -Api @{ properties = @{} }
        $result.Status | Should -Be Eligible
        $result.ApiType | Should -Be http
    }

    It 'excludes unsupported API types and Consumption' {
        foreach ($type in @('soap', 'graphql', 'websocket', 'odata', 'mcp')) {
            (Get-D4ApiEligibility -Service (Get-TestService) -Api @{ properties = @{ type = $type } }).Status |
                Should -Be 'Not eligible'
        }
        (Get-D4ApiEligibility -Service (Get-TestService -Sku Consumption) -Api @{ properties = @{} }).Status |
            Should -Be 'Not eligible'
    }

    It 'does not assume v2 tiers or unverified regions are supported' {
        (Get-D4ApiEligibility -Service (Get-TestService -Sku PremiumV2) -Api @{ properties = @{} }).Status |
            Should -Be Review
        (Get-D4ApiEligibility -Service (Get-TestService -Location unknownregion) -Api @{ properties = @{} }).Status |
            Should -Be Review
    }

    It 'checks secondary regions and offline state' {
        $service = Get-TestService
        $service.properties.additionalLocations = @(@{ location = 'unknownregion' })
        (Get-D4ApiEligibility -Service $service -Api @{ properties = @{} }).Status | Should -Be Review
        (Get-D4ApiEligibility -Service (Get-TestService) -Api @{ properties = @{ isOnline = $false } }).Status |
            Should -Be 'Not eligible'
    }
}

Describe 'Metric completeness and revision normalization' {
    It 'keeps explicit zero traffic valid' {
        $result = ConvertFrom-D4ApiMetric -Response (Get-TestMetric -Series @((Get-TestSeries -Total 0))) -SplitByApi
        $result.Status | Should -Be Observed
        $result.Requests | Should -Be 0
        $result.ByApi.orders.Known | Should -BeTrue
    }

    It 'does not turn empty or null samples into zero' {
        $empty = ConvertFrom-D4ApiMetric -Response (Get-TestMetric)
        $missing = ConvertFrom-D4ApiMetric -Response (Get-TestMetric -Series @((Get-TestSeries -Total $null))) -SplitByApi
        $empty.Status | Should -Be 'No data'
        $empty.Requests | Should -BeNullOrEmpty
        $missing.Status | Should -Not -Be Observed
        $missing.ByApi.orders.Known | Should -BeFalse
    }

    It 'combines revision dimensions into one logical API without double-counting rows' {
        $result = ConvertFrom-D4ApiMetric -Response (Get-TestMetric -Series @(
            (Get-TestSeries -Total 12 -ApiId '/apis/Orders;rev=1'),
            (Get-TestSeries -Total 23 -ApiId 'Orders%3Brev%3D2')
        )) -SplitByApi
        $result.ByApi.Count | Should -Be 1
        $result.ByApi.orders.Requests | Should -Be 35
        $result.Requests | Should -Be 35
    }

    It 'flags the series ceiling instead of treating a top-N split as complete' {
        $result = ConvertFrom-D4ApiMetric -Response (Get-TestMetric -Series @(
            (Get-TestSeries -ApiId a), (Get-TestSeries -ApiId b)
        )) -SplitByApi -SeriesLimit 2
        $result.Status | Should -Be Truncated
    }

    It 'rejects metric errors, missing dimensions and invalid call counts' {
        { ConvertFrom-D4ApiMetric -Response (Get-TestMetric -ErrorCode InvalidSamplingType) } | Should -Throw '*InvalidSamplingType*'
        $series = Get-TestSeries
        $series.metadatavalues = @()
        { ConvertFrom-D4ApiMetric -Response (Get-TestMetric -Series @($series)) -SplitByApi } |
            Should -Throw '*ApiId*'
        { ConvertFrom-D4ApiMetric -Response (Get-TestMetric -Series @((Get-TestSeries -Total -1))) } |
            Should -Throw '*nonnegative*'
    }

    It 'reconciles API splits with the service aggregate and requests a fixed full window' {
        Mock Invoke-D4ApiGet -ModuleName DefenderForApisCostEstimator {
            if ($Path -match 'top=10000') {
                @{ timespan = '2026-09-29T12:00:00Z/2026-10-29T12:00:00Z'; value = @(@{
                    name = @{ value = 'Requests' }; timeseries = @(@{
                        metadatavalues = @(@{ name = @{ value = 'ApiId' }; value = 'orders' })
                        data = @(@{ total = 10 })
                    })
                }) }
            } else {
                @{ timespan = '2026-09-29T12:00:00Z/2026-10-29T12:00:00Z'; value = @(@{
                    name = @{ value = 'Requests' }; timeseries = @(@{ data = @(@{ total = 20 }) })
                }) }
            }
        }
        {
            Get-D4ApiUsage -ServiceId '/subscriptions/test/service/apim' `
                -StartTime ([datetime]'2026-09-29T12:00:00Z') -EndTime ([datetime]'2026-10-29T12:00:00Z')
        } | Should -Throw '*reconcile*'
        Should -Invoke Invoke-D4ApiGet -ModuleName DefenderForApisCostEstimator -Times 2 -Exactly `
            -ParameterFilter { $Path -match 'interval=FULL' -and $Path -match 'aggregation=Total' }
    }

    It 'rejects a shortened response time range' {
        Mock Invoke-D4ApiGet -ModuleName DefenderForApisCostEstimator {
            @{ timespan = '2026-10-28T12:00:00Z/2026-10-29T12:00:00Z'; value = @() }
        }
        {
            Get-D4ApiUsage -ServiceId '/subscriptions/test/service/apim' `
                -StartTime ([datetime]'2026-09-29T12:00:00Z') -EndTime ([datetime]'2026-10-29T12:00:00Z')
        } | Should -Throw '*30-day window*'
    }
}

Describe 'Paginated read-only collection' {
    It 'follows nextLink and publishes inventory only after every page succeeds' {
        Mock Invoke-D4ApiGet -ModuleName DefenderForApisCostEstimator {
            if ($Path -like '*page2*') { @{ value = @(@{ id = 'b' }); nextLink = '' } }
            else { @{ value = @(@{ id = 'a' }); nextLink = 'https://management.azure.com/subscriptions/test/page2' } }
        }
        $items = @(Get-D4ApiPagedResource -Path '/subscriptions/test/apis')
        $items.Count | Should -Be 2
        $items[1].id | Should -Be b
    }

    It 'does not expose a successful-looking first page when a later page fails' {
        Mock Invoke-D4ApiGet -ModuleName DefenderForApisCostEstimator {
            if ($Path -like '*page2*') { throw 'Forbidden on next page' }
            @{ value = @(@{ id = 'a' }); nextLink = 'https://management.azure.com/subscriptions/test/page2' }
        }
        $captured = [Collections.Generic.List[object]]::new()
        {
            Get-D4ApiPagedResource -Path '/subscriptions/test/apis' | ForEach-Object { $captured.Add($_) }
        } | Should -Throw '*Forbidden*'
        $captured.Count | Should -Be 0
    }

    It 'rejects pagination cycles and malformed list responses' {
        Mock Invoke-D4ApiGet -ModuleName DefenderForApisCostEstimator {
            @{ value = @(); nextLink = '/subscriptions/test/apis' }
        }
        { Get-D4ApiPagedResource -Path '/subscriptions/test/apis' } | Should -Throw '*repeated nextLink*'
        Mock Invoke-D4ApiGet -ModuleName DefenderForApisCostEstimator { @{ value = $null } }
        { Get-D4ApiPagedResource -Path '/subscriptions/test/apis' } | Should -Throw '*value array*'
    }
}

Describe 'ARM read and retry behavior' {
    It 'only performs authenticated GET requests and accepts a successful JSON response' {
        Mock Invoke-AzRestMethod -ModuleName DefenderForApisCostEstimator {
            [pscustomobject]@{ StatusCode = 200; Content = '{"value":[]}' }
        }
        $response = Invoke-D4ApiGet -Path '/subscriptions/test/apis'
        $response.value.Count | Should -Be 0
        Should -Invoke Invoke-AzRestMethod -ModuleName DefenderForApisCostEstimator -Times 1 -Exactly `
            -ParameterFilter { $Method -eq 'GET' -and $Path -eq '/subscriptions/test/apis' }
    }

    It 'does not forward authentication to a different host or cloud' {
        Mock Invoke-AzRestMethod -ModuleName DefenderForApisCostEstimator { throw 'Must not run' }
        { Invoke-D4ApiGet -Path 'https://other.example/subscriptions/test' } | Should -Throw '*commercial*'
        { Invoke-D4ApiGet -Path 'https://management.usgovcloudapi.net/subscriptions/test' } | Should -Throw '*commercial*'
        Should -Invoke Invoke-AzRestMethod -ModuleName DefenderForApisCostEstimator -Times 0 -Exactly
    }

    It 'bounds transient retries and does not retry authorization failures' {
        Mock Start-Sleep -ModuleName DefenderForApisCostEstimator {}
        Mock Invoke-AzRestMethod -ModuleName DefenderForApisCostEstimator {
            [pscustomobject]@{ StatusCode = 429; Content = '{}' }
        }
        { Invoke-D4ApiGet -Path '/subscriptions/test/apis' } | Should -Throw '*HTTP 429*'
        Should -Invoke Invoke-AzRestMethod -ModuleName DefenderForApisCostEstimator -Times 4 -Exactly
        Should -Invoke Start-Sleep -ModuleName DefenderForApisCostEstimator -Times 3 -Exactly
    }

    It 'surfaces HTTP 403 rather than returning an empty successful list' {
        Mock Invoke-AzRestMethod -ModuleName DefenderForApisCostEstimator {
            [pscustomobject]@{ StatusCode = 403; Content = '{}' }
        }
        { Invoke-D4ApiGet -Path '/subscriptions/test/apis' } | Should -Throw '*HTTP 403*'
        Should -Invoke Invoke-AzRestMethod -ModuleName DefenderForApisCostEstimator -Times 1 -Exactly
    }
}

Describe 'Subscription collection with synthetic ARM fixtures' {
    BeforeEach {
        Mock Invoke-D4ApiGet -ModuleName DefenderForApisCostEstimator {
            @{ properties = @{ pricingTier = 'Standard'; subPlan = 'P2' } }
        }
        Mock Get-D4ApiPagedResource -ModuleName DefenderForApisCostEstimator {
            if ($Path -match '/Microsoft.Security/apiCollections\?api-version=') {
                @{
                    id = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.ApiManagement/service/test-apim/providers/Microsoft.Security/apiCollections/orders'
                    name = 'orders'
                    properties = @{
                        discoveredVia = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.ApiManagement/service/test-apim'
                        provisioningState = 'Succeeded'
                    }
                }
            } elseif ($Path -match '/Microsoft.ApiManagement/service\?api-version=') {
                @{
                    id = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.ApiManagement/service/test-apim'
                    name = 'test-apim'; sku = @{ name = 'Standard' }; location = 'eastus'; properties = @{}
                }
            } elseif ($Path -match '/apis\?api-version=') {
                @(
                    @{ name = 'orders'; properties = @{ displayName = 'Orders'; isCurrent = $true } },
                    @{ name = 'orders;rev=2'; properties = @{ displayName = 'Orders revision'; isCurrent = $false } },
                    @{ name = 'catalog'; properties = @{ displayName = 'Catalog'; type = 'http'; isCurrent = $true } }
                )
            } else { throw "Unexpected test path: $Path" }
        }
        Mock Get-D4ApiUsage -ModuleName DefenderForApisCostEstimator {
            [pscustomobject]@{
                Status = 'Observed'; Requests = 51000000
                ByApi = @{
                    orders = @{ Known = $true; Requests = 1000000 }
                    catalog = @{ Known = $true; Requests = 50000000 }
                }
            }
        }
    }

    It 'collects logical APIs once, joins onboarding and produces different rollout/current recommendations' {
        $result = Get-D4ApiSubscriptionReport -SubscriptionID '00000000-0000-0000-0000-000000000001' `
            -SubscriptionName 'Test subscription' -Plans $script:pricing.plans `
            -StartTime ([datetime]'2026-09-29T12:00:00Z') -EndTime ([datetime]'2026-10-29T12:00:00Z')
        $result.Apis.Count | Should -Be 2
        $result.Summary.EligibleApis | Should -Be 2
        $result.Summary.OnboardedApis | Should -Be 1
        $result.Summary.RecommendedPlan | Should -Be P3
        $result.Summary.CurrentScopeRecommendedPlan | Should -Be P1
        $result.Issues.Count | Should -Be 0
        ($result.Apis | Where-Object ApiName -EQ orders).DisplayName | Should -Be Orders
    }

    It 'preserves API evidence but withholds estimates when metrics fail' {
        Mock Get-D4ApiUsage -ModuleName DefenderForApisCostEstimator { throw 'Metrics permission denied' }
        $result = Get-D4ApiSubscriptionReport -SubscriptionID '00000000-0000-0000-0000-000000000001' `
            -SubscriptionName 'Test subscription' -Plans $script:pricing.plans `
            -StartTime ([datetime]'2026-09-29T12:00:00Z') -EndTime ([datetime]'2026-10-29T12:00:00Z')
        $result.Apis.Count | Should -Be 2
        $result.Summary.RecommendedPlan | Should -BeNullOrEmpty
        $result.Summary.CurrentPlanEstimatedCost | Should -BeNullOrEmpty
        @($result.Issues | Where-Object Severity -EQ Error).Count | Should -Be 1
    }

    It 'does not describe unreadable API inventory as zero eligible APIs' {
        Mock Get-D4ApiPagedResource -ModuleName DefenderForApisCostEstimator {
            throw 'API inventory permission denied'
        } -ParameterFilter { $Path -match '/apis\?api-version=' }
        $result = Get-D4ApiSubscriptionReport -SubscriptionID '00000000-0000-0000-0000-000000000001' `
            -SubscriptionName 'Test subscription' -Plans $script:pricing.plans `
            -StartTime ([datetime]'2026-09-29T12:00:00Z') -EndTime ([datetime]'2026-10-29T12:00:00Z')
        $result.Summary.EstimateStatus | Should -Be 'Incomplete inventory'
        $result.Summary.OptimizationStatus | Should -Be 'Incomplete inventory'
        $result.PlanCosts.Count | Should -Be 0
        $result.Services[0].InventoryStatus | Should -Be Incomplete
    }

    It 'distinguishes a subscription pricing failure from Free' {
        Mock Invoke-D4ApiGet -ModuleName DefenderForApisCostEstimator { throw 'Pricing read forbidden' }
        $result = Get-D4ApiSubscriptionReport -SubscriptionID '00000000-0000-0000-0000-000000000001' `
            -SubscriptionName 'Test subscription' -Plans $script:pricing.plans `
            -StartTime ([datetime]'2026-09-29T12:00:00Z') -EndTime ([datetime]'2026-10-29T12:00:00Z')
        $result.Summary.DefenderForApisStatus | Should -Be Unknown
        $result.Summary.RecommendedPlan | Should -Be P3
        $result.Summary.CurrentPlanEstimatedCost | Should -BeNullOrEmpty
    }

    It 'withholds current plan fit when onboarding cannot be read, without blocking a complete rollout model' {
        Mock Get-D4ApiPagedResource -ModuleName DefenderForApisCostEstimator {
            throw 'Onboarding inventory read forbidden'
        } -ParameterFilter { $Path -match '/Microsoft.Security/apiCollections\?api-version=' }
        $result = Get-D4ApiSubscriptionReport -SubscriptionID '00000000-0000-0000-0000-000000000001' `
            -SubscriptionName 'Test subscription' -Plans $script:pricing.plans `
            -StartTime ([datetime]'2026-09-29T12:00:00Z') -EndTime ([datetime]'2026-10-29T12:00:00Z')
        $result.Summary.RecommendedPlan | Should -Be P3
        $result.Summary.CurrentScopeRecommendedPlan | Should -BeNullOrEmpty
        $result.Apis[0].OnboardingStatus | Should -Be Unknown
    }

    It 'surfaces an unrecognized configured subplan in data quality, not just an empty cost cell' {
        Mock Invoke-D4ApiGet -ModuleName DefenderForApisCostEstimator {
            @{ properties = @{ pricingTier = 'Standard'; subPlan = 'FuturePlan' } }
        }
        $result = Get-D4ApiSubscriptionReport -SubscriptionID '00000000-0000-0000-0000-000000000001' `
            -SubscriptionName 'Test subscription' -Plans $script:pricing.plans `
            -StartTime ([datetime]'2026-09-29T12:00:00Z') -EndTime ([datetime]'2026-10-29T12:00:00Z')
        $result.Summary.DefenderForApisStatus | Should -Be Enabled
        $result.Summary.CurrentPlanEstimatedCost | Should -BeNullOrEmpty
        @($result.Issues | Where-Object { $_.Stage -eq 'Subscription plan' -and $_.Severity -eq 'Warning' }).Count |
            Should -Be 1
    }

    It 'surfaces pending provisioning in data quality and withholds current-scope estimates' {
        Mock Get-D4ApiPagedResource -ModuleName DefenderForApisCostEstimator {
            @{
                name = 'orders'
                properties = @{
                    discoveredVia = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.ApiManagement/service/test-apim'
                    provisioningState = 'Creating'
                }
            }
        } -ParameterFilter { $Path -match '/Microsoft.Security/apiCollections\?api-version=' }
        $result = Get-D4ApiSubscriptionReport -SubscriptionID '00000000-0000-0000-0000-000000000001' `
            -SubscriptionName 'Test subscription' -Plans $script:pricing.plans `
            -StartTime ([datetime]'2026-09-29T12:00:00Z') -EndTime ([datetime]'2026-10-29T12:00:00Z')
        $result.Summary.OptimizationStatus | Should -Be 'Incomplete onboarding inventory'
        $result.Summary.RecommendedPlan | Should -Be P3
        @($result.Issues | Where-Object { $_.Stage -eq 'API data quality' -and $_.Message -like '*Creating*' }).Count |
            Should -Be 1
    }
}

Describe 'Command-line exports with an isolated fake Az module' {
    BeforeAll {
        $script:fakeModuleRoot = Join-Path $TestDrive 'modules'
        $moduleDirectory = Join-Path $script:fakeModuleRoot 'Az.Accounts'
        $null = New-Item -ItemType Directory -Path $moduleDirectory -Force
        $source = @'
function Get-AzContext {
    [pscustomobject]@{ Environment = [pscustomobject]@{ Name = 'AzureCloud' }; Name = 'Original test context' }
}
function Connect-AzAccount { throw 'The test must reuse its synthetic signed-in context.' }
function Get-AzSubscription {
    [CmdletBinding()]
    param([string]$SubscriptionId)
    if ($SubscriptionId -and $SubscriptionId -ne '00000000-0000-0000-0000-000000000001') {
        throw 'Unexpected synthetic subscription.'
    }
    [pscustomobject]@{
        Id = '00000000-0000-0000-0000-000000000001'
        Name = 'Synthetic subscription'; TenantId = '00000000-0000-0000-0000-000000000002'; State = 'Enabled'
    }
}
function Set-AzContext {
    [CmdletBinding()]
    param([string]$SubscriptionId, [string]$TenantId, [string]$Scope, [object]$Context)
    if ($Scope -ne 'Process') { throw 'Context changes must be process-scoped.' }
    if ($Context) {
        Set-Content -LiteralPath $env:D4ApiTestContextPath -Value $Context.Name
    } elseif ($SubscriptionId -ne '00000000-0000-0000-0000-000000000001' -or
        $TenantId -ne '00000000-0000-0000-0000-000000000002') {
        throw 'Unexpected synthetic subscription context.'
    } elseif ($env:D4ApiTestMode -eq 'context') {
        throw 'Synthetic context selection failure.'
    }
    Get-AzContext
}
function Invoke-AzRestMethod {
    [CmdletBinding()]
    param([string]$Method, [string]$Path, [string]$Uri)
    if ($Method -ne 'GET' -or $Uri) { throw 'Only the expected relative ARM GET is allowed in this fixture.' }
    $serviceId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.ApiManagement/service/test-apim'
    if ($Path -match '/Microsoft.Security/pricings/Api\?') {
        $body = @{ properties = @{ pricingTier = 'Standard'; subPlan = 'P2' } }
    } elseif ($Path -match '/Microsoft.Security/apiCollections\?') {
        $body = @{ value = @(@{
            name = 'orders'; id = "$serviceId/providers/Microsoft.Security/apiCollections/orders"
            properties = @{ discoveredVia = $serviceId; provisioningState = 'Succeeded' }
        }) }
    } elseif ($Path -match '/Microsoft.ApiManagement/service\?') {
        $body = @{ value = @(@{
            id = $serviceId; name = 'test-apim'; sku = @{ name = 'Standard' }; location = 'eastus'; properties = @{}
        }) }
    } elseif ($Path -match '/apis\?') {
        $body = @{ value = @(@{ name = 'orders'; properties = @{ displayName = 'Orders'; isCurrent = $true } }) }
    } elseif ($Path -match '/Microsoft.Insights/metrics\?') {
        if ($env:D4ApiTestMode -eq 'metrics') {
            return [pscustomobject]@{ StatusCode = 403; Content = '{}' }
        }
        $window = [Uri]::UnescapeDataString([regex]::Match($Path, '[?&]timespan=([^&]+)').Groups[1].Value)
        $series = @{ data = @(@{ total = 1000000 }) }
        if ($Path -match 'top=10000') {
            $series.metadatavalues = @(@{ name = @{ value = 'ApiId' }; value = 'orders' })
        }
        $body = @{ timespan = $window; value = @(@{ name = @{ value = 'Requests' }; timeseries = @($series) }) }
    } else { throw "Unexpected synthetic ARM request: $Path" }
    [pscustomobject]@{ StatusCode = 200; Content = (ConvertTo-Json -InputObject $body -Depth 20 -Compress) }
}
Export-ModuleMember -Function Get-AzContext, Connect-AzAccount, Get-AzSubscription, Set-AzContext, Invoke-AzRestMethod
'@
        Set-Content -LiteralPath (Join-Path $moduleDirectory 'Az.Accounts.psm1') -Value $source
        New-ModuleManifest -Path (Join-Path $moduleDirectory 'Az.Accounts.psd1') `
            -RootModule 'Az.Accounts.psm1' -ModuleVersion '1.0.0' -FunctionsToExport '*'

        function Invoke-TestCollector {
            param([string]$Mode = 'success')
            $outputDirectory = Join-Path $TestDrive $Mode
            $contextPath = Join-Path $TestDrive "$Mode-context.txt"
            $oldPath = $env:PSModulePath
            $oldMode = $env:D4ApiTestMode
            $oldContextPath = $env:D4ApiTestContextPath
            try {
                $env:PSModulePath = "$script:fakeModuleRoot;$PSHOME\Modules"
                $env:D4ApiTestMode = $Mode
                $env:D4ApiTestContextPath = $contextPath
                $output = @(& (Get-Process -Id $PID).Path -NoProfile -File (
                    Join-Path $script:estimatorDirectory 'd4apis_cost_estimator_v1.ps1'
                ) -SubscriptionId '00000000-0000-0000-0000-000000000001' -OutputDirectory $outputDirectory 2>&1)
                $exitCode = $LASTEXITCODE
            } finally {
                $env:PSModulePath = $oldPath
                $env:D4ApiTestMode = $oldMode
                $env:D4ApiTestContextPath = $oldContextPath
            }
            [pscustomobject]@{ OutputDirectory = $outputDirectory; ExitCode = $exitCode; Output = $output; ContextPath = $contextPath }
        }
    }

    It 'executes the historical entry point, writes populated artifacts and restores the original context' {
        $run = Invoke-TestCollector
        $run.ExitCode | Should -Be 0 -Because ($run.Output -join "`n")
        $report = Get-Content -LiteralPath (Join-Path $run.OutputDirectory 'DefenderForApisReport.json') -Raw | ConvertFrom-Json
        $report.Subscriptions.Count | Should -Be 1
        $report.Subscriptions[0].CurrentPlan | Should -Be P2
        $report.Subscriptions[0].CurrentScopeRecommendedPlan | Should -Be P1
        $report.Subscriptions[0].EstimatedMonthlySavings | Should -Be 500
        $report.PlanCosts.Count | Should -Be 10
        ([datetimeoffset]$report.WindowEndUtc - [datetimeoffset]$report.WindowStartUtc).TotalDays | Should -Be 30
        ([datetimeoffset]$report.WindowEndUtc).Second | Should -Be 0
        @((Import-Csv -LiteralPath (Join-Path $run.OutputDirectory 'AllSubscriptionsPlanRecommendation.csv'))).Count |
            Should -Be 1
        Test-Path -LiteralPath (Join-Path $run.OutputDirectory 'D4ApisCostEstimation.workbook') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $run.OutputDirectory 'DefenderForApis.armTemplate.json') | Should -BeFalse
        (Get-Content -LiteralPath $run.ContextPath -Raw).Trim() | Should -Be 'Original test context'
    }

    It 'exports partial evidence and returns failure without a fabricated recommendation for <Mode> errors' -ForEach @(
        @{ Mode = 'metrics' }, @{ Mode = 'context' }
    ) {
        $run = Invoke-TestCollector -Mode $Mode
        $run.ExitCode | Should -Not -Be 0
        $report = Get-Content -LiteralPath (Join-Path $run.OutputDirectory 'DefenderForApisReport.json') -Raw | ConvertFrom-Json
        $report.Subscriptions[0].RecommendedPlan | Should -BeNullOrEmpty
        $report.Subscriptions[0].CurrentPlanEstimatedCost | Should -BeNullOrEmpty
        @($report.Issues | Where-Object Severity -EQ Error).Count | Should -BeGreaterThan 0
        Test-Path -LiteralPath (Join-Path $run.OutputDirectory 'DefenderForApisReport.json') | Should -BeTrue
        (Get-Content -LiteralPath $run.ContextPath -Raw).Trim() | Should -Be 'Original test context'
    }
}

AfterAll {
    if ($script:createdRestStub) { Remove-Item -LiteralPath Function:\Invoke-AzRestMethod }
}
