BeforeAll {
    $script:directory = Split-Path -Parent $PSScriptRoot
    $script:estimatorPath = Join-Path $script:directory 'DefenderForStorage-CostEstimation-ResourceLevelVisibility.ps1'
    $script:templatePath = Join-Path $script:directory 'D4StorageARMTemplate.json'
    . $script:estimatorPath

    function New-TestContext {
        param([string]$SubscriptionId = '00000000-0000-0000-0000-000000000001')
        $context = [Microsoft.Azure.Commands.Profile.Models.Core.PSAzureContext]::new()
        $context.Tenant = [Microsoft.Azure.Commands.Profile.Models.PSAzureTenant]::new()
        $context.Tenant.Id = '00000000-0000-0000-0000-000000000010'
        $context.Subscription = [Microsoft.Azure.Commands.Profile.Models.PSAzureSubscription]::new()
        $context.Subscription.Id = $SubscriptionId
        $context.Environment = Get-AzEnvironment -Name AzureCloud
        $context
    }

    function New-TestAccount {
        param(
            [string]$Name = 'fixtureaccount',
            [string]$SubscriptionId = '00000000-0000-0000-0000-000000000001',
            [bool]$Blob = $true,
            [bool]$File = $true
        )
        [pscustomobject]@{
            id = "/subscriptions/$SubscriptionId/resourceGroups/fixture/providers/Microsoft.Storage/storageAccounts/$Name"
            name = $Name
            properties = [pscustomobject]@{
                primaryEndpoints = [pscustomobject]@{
                    blob = $(if ($Blob) { 'https://fixture.invalid/blob' } else { '' })
                    file = $(if ($File) { 'https://fixture.invalid/file' } else { '' })
                }
            }
        }
    }

    function New-TestConfiguration {
        param([int]$Days = 30)
        $end = [datetime]'2026-01-31T00:00:00Z'
        [pscustomobject]@{
            StartTimeUtc = $end.AddDays(-$Days)
            EndTimeUtc = $end
            SampleDays = $Days
            CostPerStorageAccount = [decimal]10
            PricePer1MOverageTransactions = [decimal]0.1492
            MalwareScanningPricePerGB = [decimal]0.15
            MalwareScanningCapGB = -1
        }
    }

    function New-TestMetric {
        param([string]$Name, $Total)
        [pscustomobject]@{
            value = @([pscustomobject]@{
                name = [pscustomobject]@{ value = $Name }
                timeseries = @([pscustomobject]@{
                    data = @([pscustomobject]@{ total = $Total })
                })
            })
        }
    }
}

Describe 'Single-source workbook release' {
    BeforeAll {
        $script:template = Get-Content -LiteralPath $script:templatePath -Raw | ConvertFrom-Json
        $script:workbookJson = $script:template.resources[0].properties.serializedData
        $script:workbook = $script:workbookJson | ConvertFrom-Json
        $script:readme = Get-Content -LiteralPath (Join-Path $script:directory 'ReadMe.md') -Raw
        $script:schema = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Uri (
            'https://raw.githubusercontent.com/microsoft/Application-Insights-Workbooks/master/schema/workbook.json'
        )).Content
    }

    It 'keeps one ARM JSON and consistent release metadata' {
        @(Get-ChildItem -LiteralPath $script:directory -Filter '*.json' -Recurse).Count | Should -Be 1
        $script:template.contentVersion | Should -Be '4.2.0.0'
        $script:template.parameters.workbookDisplayName.defaultValue | Should -Be 'StorageCostV4.2'
        $script:template.'$schema' | Should -Be 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
        $script:template.resources[0].apiVersion | Should -Be '2023-06-01'
        $script:workbook.version | Should -Be 'Notebook/1.0'
        $script:workbook.items[0].content.json | Should -Match '\bv4\.2$'
        $script:workbook.items.Count | Should -Be 10
        $script:readme | Should -Not -Match 'next couple of weeks|does not include the Malware Scanning'
    }

    It 'validates the decoded content against the complete published workbook schema' {
        Test-Json -Json $script:workbookJson -Schema $script:schema | Should -BeTrue
    }

    It 'rejects the ARM wrapper as Workbook Template content' {
        $valid = Test-Json -Json ($script:template | ConvertTo-Json -Depth 100) -Schema $script:schema `
            -ErrorAction SilentlyContinue
        $valid | Should -BeFalse
    }

    It 'executes the documented extraction without changing the user clipboard' {
        Mock Set-Clipboard { param($Value) $script:copied = $Value -join [Environment]::NewLine }
        $block = [regex]::Match($script:readme, '(?s)```powershell\s*\r?\n(.*?)\r?\n\s*```').Groups[1].Value
        $block | Should -Not -BeNullOrEmpty
        Push-Location $script:directory
        try {
            & ([scriptblock]::Create($block))
        } finally {
            Pop-Location
        }
        ($script:copied | ConvertFrom-Json).version | Should -Be 'Notebook/1.0'
        ($script:copied | ConvertFrom-Json | ConvertTo-Json -Depth 100 -Compress) |
            Should -Be ($script:workbook | ConvertTo-Json -Depth 100 -Compress)
        Should -Invoke Set-Clipboard -Times 1 -Exactly
    }

    It 'points Deploy to Azure at the canonical ARM file' {
        $button = [regex]::Match($script:readme, '<a href="([^"]+)" target="_blank"><img src="https://aka.ms/deploytoazurebutton"')
        $prefix = 'https://portal.azure.com/#create/Microsoft.Template/uri/'
        $button.Groups[1].Value | Should -BeLike "$prefix*"
        $raw = [uri]::UnescapeDataString($button.Groups[1].Value.Substring($prefix.Length))
        $raw | Should -Be (
            'https://raw.githubusercontent.com/Azure/Microsoft-Defender-for-Cloud/main/Workbooks/' +
            'Microsoft Defender for Storage Price Estimation/D4StorageARMTemplate.json'
        )
        $script:template.resources.Count | Should -Be 1
        $script:template.resources[0].type | Should -Be 'Microsoft.Insights/workbooks'
    }
}

Describe 'Storage and malware-scanning cost model' {
    BeforeEach {
        $script:configuration = New-TestConfiguration
        $script:account = New-TestAccount
        $script:context = New-TestContext
        Mock Write-Warning {}
        Mock Invoke-StorageEstimationGet {
            param($Path)
            if ($Path -match 'metricnames=Ingress') {
                New-TestMetric -Name Ingress -Total 1073741824
            } elseif ($Path -match '/blobServices/') {
                New-TestMetric -Name Transactions -Total 70000000
            } else {
                New-TestMetric -Name Transactions -Total 3000000
            }
        }
    }

    It 'includes malware scanning and does not charge overage at exactly 73 million transactions' {
        $row = Get-StorageAccountCostEstimate $script:account $script:context $script:configuration
        $row.StorageAccountTransactions | Should -Be 73000000
        $row.OverageCost | Should -Be 0
        $row.MalwareScanningCost | Should -Be 0.15
        $row.EstimatedMonthlyCost | Should -Be 10.15
        $row.MetricsStatus | Should -Be 'Complete'
    }

    It 'handles transaction totals larger than a signed 32-bit integer' {
        Mock Invoke-StorageEstimationGet {
            param($Path)
            if ($Path -match 'metricnames=Ingress') {
                New-TestMetric Ingress 1073741824
            } elseif ($Path -match '/blobServices/') {
                New-TestMetric Transactions 5000000000
            } else {
                New-TestMetric Transactions 0
            }
        }
        $row = Get-StorageAccountCostEstimate $script:account $script:context $script:configuration
        $row.StorageAccountTransactions | Should -Be 5000000000
        $row.OverageTransactions | Should -Be 4927000000
        $row.OverageCost | Should -Be 735.11
        $row.EstimatedMonthlyCost | Should -Be 745.26
    }

    It 'projects a seven-day sample to 30 days using the workbook GB conversion' {
        $script:configuration = New-TestConfiguration -Days 7
        Mock Invoke-StorageEstimationGet {
            param($Path)
            if ($Path -match 'metricnames=Ingress') {
                New-TestMetric Ingress (7 * [decimal]1073741824)
            } elseif ($Path -match '/blobServices/') {
                New-TestMetric Transactions 7000000
            } else {
                New-TestMetric Transactions 0
            }
        }
        $row = Get-StorageAccountCostEstimate $script:account $script:context $script:configuration
        $row.StorageAccountTransactions | Should -Be 30000000
        $row.EstimatedMonthlyIngressGB | Should -Be 30
        $row.MalwareScanningCost | Should -Be 4.50
        $row.EstimatedMonthlyCost | Should -Be 14.50
    }

    It 'applies explicit monthly scanning caps including zero' {
        $script:configuration.MalwareScanningCapGB = 0
        $row = Get-StorageAccountCostEstimate $script:account $script:context $script:configuration
        $row.MalwareScanningBillableGB | Should -Be 0
        $row.EstimatedMonthlyCost | Should -Be 10
        $script:configuration.MalwareScanningCapGB = 2
        Mock Invoke-StorageEstimationGet {
            param($Path)
            if ($Path -match 'metricnames=Ingress') {
                New-TestMetric Ingress (10 * [decimal]1073741824)
            } else {
                New-TestMetric Transactions 0
            }
        }
        $row = Get-StorageAccountCostEstimate $script:account $script:context $script:configuration
        $row.EstimatedMonthlyIngressGB | Should -Be 10
        $row.MalwareScanningBillableGB | Should -Be 2
        $row.MalwareScanningCost | Should -Be 0.30
    }

    It 'supports agreement-specific prices' {
        $script:configuration.CostPerStorageAccount = [decimal]7
        $script:configuration.MalwareScanningPricePerGB = [decimal]0.30
        $row = Get-StorageAccountCostEstimate $script:account $script:context $script:configuration
        $row.EstimatedMonthlyCost | Should -Be 7.30
    }

    It 'does not query Blob metrics or charge scanning for a File-only account' {
        $script:account = New-TestAccount -Blob:$false
        $row = Get-StorageAccountCostEstimate $script:account $script:context $script:configuration
        $row.MalwareScanningCost | Should -Be 0
        $row.EstimatedMonthlyCost | Should -Be 10
        Should -Invoke Invoke-StorageEstimationGet -Times 0 -Exactly -ParameterFilter {
            $Path -match '/blobServices/'
        }
    }

    It 'treats explicit zero observations as valid data' {
        Mock Invoke-StorageEstimationGet {
            param($Path)
            if ($Path -match 'metricnames=Ingress') { New-TestMetric Ingress 0 }
            else { New-TestMetric Transactions 0 }
        }
        $row = Get-StorageAccountCostEstimate $script:account $script:context $script:configuration
        $row.EstimatedMonthlyCost | Should -Be 10
        $row.MetricsStatus | Should -Be 'Complete'
        Should -Invoke Write-Warning -Times 0 -Exactly
    }

    It 'warns and leaves the scanning charge unknown when ingress observations are missing' {
        Mock Invoke-StorageEstimationGet {
            param($Path)
            if ($Path -match 'metricnames=Ingress') { New-TestMetric Ingress $null }
            else { New-TestMetric Transactions 0 }
        }
        $row = Get-StorageAccountCostEstimate $script:account $script:context $script:configuration
        $row.StorageAccountCost | Should -Be 10
        $row.MalwareScanningCost | Should -BeNullOrEmpty
        $row.EstimatedMonthlyCost | Should -BeNullOrEmpty
        $row.MetricsStatus | Should -Be 'Incomplete'
        Should -Invoke Write-Warning -Times 1 -Exactly
    }

    It 'does not turn missing transaction observations into a base-only complete estimate' {
        Mock Invoke-StorageEstimationGet {
            param($Path)
            if ($Path -match 'metricnames=Ingress') { New-TestMetric Ingress 1073741824 }
            else { New-TestMetric Transactions $null }
        }
        $row = Get-StorageAccountCostEstimate $script:account $script:context $script:configuration
        $row.StorageAccountTransactions | Should -BeNullOrEmpty
        $row.StorageAccountCost | Should -BeNullOrEmpty
        $row.MalwareScanningCost | Should -Be 0.15
        $row.MetricsStatus | Should -Be 'Incomplete'
    }

    It 'rejects malformed or negative metric responses' {
        Mock Invoke-StorageEstimationGet { [pscustomobject]@{ value = @() } }
        { Get-StorageAccountCostEstimate $script:account $script:context $script:configuration } |
            Should -Throw '*Expected one Transactions metric*'
        Mock Invoke-StorageEstimationGet { New-TestMetric Transactions -1 }
        { Get-StorageAccountCostEstimate $script:account $script:context $script:configuration } |
            Should -Throw '*negative total*'
    }

    It 'filters ingress to the upload APIs instead of counting File ingress' {
        $null = Get-StorageAccountCostEstimate $script:account $script:context $script:configuration
        Should -Invoke Invoke-StorageEstimationGet -Times 1 -Exactly -ParameterFilter {
            $Path -match '/blobServices/' -and $Path -match 'metricnames=Ingress' -and
            [uri]::UnescapeDataString($Path) -match "ApiName eq 'PutBlob'.*ApiName eq 'CreatePathFile'"
        }
    }

    It 'surfaces an embedded metric error even when the HTTP response succeeded' {
        Mock Invoke-StorageEstimationGet {
            $response = New-TestMetric Transactions 0
            $response.value[0] | Add-Member -NotePropertyName errorCode -NotePropertyValue InvalidSampling
            $response
        }
        { Get-StorageAccountCostEstimate $script:account $script:context $script:configuration } |
            Should -Throw '*InvalidSampling*'
    }
}

Describe 'Read-only ARM request handling' {
    BeforeEach {
        $script:context = New-TestContext
        Mock Start-Sleep {}
    }

    It 'stops on an HTTP error rather than accepting an empty zero-cost response' {
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 403; Content = '{}' } }
        { Invoke-StorageEstimationGet -Path '/fixture' -Context $script:context } |
            Should -Throw '*HTTP 403*'
    }

    It 'retries transient returned HTTP responses with a bounded delay' {
        $script:attempts = 0
        Mock Invoke-AzRestMethod {
            $script:attempts++
            if ($script:attempts -lt 3) {
                [pscustomobject]@{ StatusCode = 429; Content = '{}' }
            } else {
                [pscustomobject]@{ StatusCode = 200; Content = '{"value":[]}' }
            }
        }
        $null = Invoke-StorageEstimationGet -Path '/fixture' -Context $script:context
        Should -Invoke Invoke-AzRestMethod -Times 3 -Exactly
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }

    It 'stops after three unsuccessful attempts' {
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 503; Content = '{}' } }
        { Invoke-StorageEstimationGet -Path '/fixture' -Context $script:context } |
            Should -Throw '*HTTP 503*'
        Should -Invoke Invoke-AzRestMethod -Times 3 -Exactly
    }

    It 'refuses a pagination link outside the signed-in ARM environment' {
        Mock Invoke-AzRestMethod {}
        { Invoke-StorageEstimationGet -Path 'https://fixture.invalid/next' -Context $script:context } |
            Should -Throw '*outside the current Azure Resource Manager endpoint*'
        Should -Invoke Invoke-AzRestMethod -Times 0 -Exactly
    }
}

Describe 'Script entry point, tenant scope, and CSV output' {
    BeforeEach {
        $script:firstSub = '00000000-0000-0000-0000-000000000001'
        $script:secondSub = '00000000-0000-0000-0000-000000000002'
        Mock Write-Host {}
        Mock Get-AzContext { New-TestContext }
        Mock Get-AzSubscription {
            @(
                [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000001'; State = 'Enabled' },
                [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000002'; State = 'Enabled' },
                [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000003'; State = 'Disabled' }
            )
        }
        Mock Set-AzContext {
            param($Subscription, $Context)
            if ($null -ne $Context) { $Context }
            else { New-TestContext -SubscriptionId $Subscription }
        }
        Mock Invoke-AzRestMethod {
            param($Method, $Path)
            if ($Method -ne 'GET') { throw 'The estimator attempted a non-read-only request.' }
            if ($Path -match '/providers/Microsoft.Storage/storageAccounts\?') {
                $id = ($Path -split '/')[2]
                $accounts = if ($id -eq '00000000-0000-0000-0000-000000000001') {
                    @(1..251 | ForEach-Object { New-TestAccount -Name "first$_" })
                } else {
                    @(1..2 | ForEach-Object { New-TestAccount -Name "second$_" -SubscriptionId $id })
                }
                $body = @{ value = @($accounts | Select-Object -First 200) }
                if ($Path -match 'skiptoken=second') {
                    $body.value = @($accounts | Select-Object -Skip 200)
                } elseif ($accounts.Count -gt 200) {
                    $body.nextLink = "https://management.azure.com/subscriptions/$id/providers/Microsoft.Storage/storageAccounts?api-version=2023-05-01&`$skiptoken=second"
                }
            } else {
                if ($Path -match 'metricnames=Ingress') {
                    $body = New-TestMetric Ingress 1073741824
                } else {
                    $body = New-TestMetric Transactions 0
                }
            }
            [pscustomobject]@{
                StatusCode = 200
                Content = ($body | ConvertTo-Json -Depth 20 -Compress)
            }
        }
    }

    It 'runs beyond 250 accounts, follows nextLink, and includes every enabled subscription' {
        $csv = Join-Path $TestDrive 'tenant.csv'
        $rows = @(& $script:estimatorPath -SampleDays 30 -ThrottleLimit 1 -OutputPath $csv)
        $rows.Count | Should -Be 253
        @($rows.SubscriptionId | Select-Object -Unique).Count | Should -Be 2
        @($rows | Where-Object { $_.MetricsStatus -eq 'Complete' }).Count | Should -Be 253
        $total = [decimal]0
        foreach ($row in $rows) { $total += $row.EstimatedMonthlyCost }
        $total | Should -Be 2567.95
        $imported = @(Import-Csv -LiteralPath $csv)
        $imported.Count | Should -Be 253
        $imported[0].MalwareScanningCost | Should -Be '0.15'
        (Get-Content -LiteralPath $csv -TotalCount 1) | Should -BeLike '"SubscriptionId","StorageAccountName",*'
        Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter {
            $PesterBoundParameters.ContainsKey('Context')
        }
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
            $Object -like 'Estimated monthly cost: 2567.95.*'
        }
    }

    It 'accepts arrays, whitespace and comma-separated IDs without duplicate billing' {
        $csv = Join-Path $TestDrive 'selected.csv'
        $rows = @(& $script:estimatorPath -SubscriptionIds @(
            " $($script:secondSub),$($script:secondSub) ", $script:secondSub
        ) -SampleDays 30 -ThrottleLimit 1 -OutputPath $csv)
        $rows.Count | Should -Be 2
        $rows[0].SubscriptionId | Should -Be $script:secondSub
    }

    It 'does not export a successful report after an HTTP failure and restores context' {
        Mock Invoke-AzRestMethod {
            [pscustomobject]@{ StatusCode = 403; Content = '{}' }
        } -ParameterFilter { $Path -match '/providers/Microsoft.Insights/metrics' }
        $csv = Join-Path $TestDrive 'failed.csv'
        { & $script:estimatorPath -SubscriptionIds $script:secondSub -ThrottleLimit 1 -OutputPath $csv } |
            Should -Throw '*HTTP 403*'
        Test-Path -LiteralPath $csv | Should -BeFalse
        Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter {
            $PesterBoundParameters.ContainsKey('Context')
        }
    }

    It 'exports incomplete rows explicitly rather than inserting zero scan charges' {
        Mock Invoke-AzRestMethod {
            [pscustomobject]@{
                StatusCode = 200
                Content = (New-TestMetric Ingress $null | ConvertTo-Json -Depth 20 -Compress)
            }
        } -ParameterFilter { $Path -match 'metricnames=Ingress' }
        $csv = Join-Path $TestDrive 'incomplete.csv'
        $warnings = @()
        $rows = @(& $script:estimatorPath -SubscriptionIds $script:secondSub -ThrottleLimit 1 `
            -OutputPath $csv -WarningVariable warnings -WarningAction SilentlyContinue)
        $rows.Count | Should -Be 2
        $rows[0].MetricsStatus | Should -Be 'Incomplete'
        $rows[0].EstimatedMonthlyCost | Should -BeNullOrEmpty
        (Import-Csv -LiteralPath $csv)[0].MalwareScanningCost | Should -BeNullOrEmpty
        ($warnings -join ' ') | Should -Match 'complete scoped total is unavailable'
    }

    It 'rejects malformed or inaccessible subscription IDs' {
        { & $script:estimatorPath -SubscriptionIds 'not-a-guid' -ThrottleLimit 1 } |
            Should -Throw '*Invalid subscription ID*'
        { & $script:estimatorPath -SubscriptionIds '00000000-0000-0000-0000-000000000099' -ThrottleLimit 1 } |
            Should -Throw '*not enabled or accessible*'
    }

    It 'does not export an empty zero-cost report when no storage accounts exist' {
        Mock Invoke-AzRestMethod {
            [pscustomobject]@{ StatusCode = 200; Content = '{"value":[]}' }
        }
        $csv = Join-Path $TestDrive 'empty.csv'
        { & $script:estimatorPath -ThrottleLimit 1 -OutputPath $csv } |
            Should -Throw '*No storage accounts were found*'
        Test-Path -LiteralPath $csv | Should -BeFalse
    }

    It 'rejects a malformed storage-account list rather than silently dropping the scope' {
        Mock Invoke-AzRestMethod {
            [pscustomobject]@{ StatusCode = 200; Content = '{"unexpected":[]}' }
        }
        { & $script:estimatorPath -ThrottleLimit 1 -OutputPath (Join-Path $TestDrive 'invalid.csv') } |
            Should -Throw '*no value array*'
    }

    It 'stops a repeated pagination link instead of looping indefinitely' {
        Mock Invoke-AzRestMethod {
            param($Path)
            [pscustomobject]@{
                StatusCode = 200
                Content = (@{ value = @(); nextLink = $Path } | ConvertTo-Json -Compress)
            }
        }
        { & $script:estimatorPath -ThrottleLimit 1 -OutputPath (Join-Path $TestDrive 'loop.csv') } |
            Should -Throw '*Repeated storage-account pagination URL*'
    }

    It 'fails explicitly when no Azure context is available instead of opening an interactive login' {
        Mock Get-AzContext { $null }
        { & $script:estimatorPath -ThrottleLimit 1 } | Should -Throw '*Connect-AzAccount*'
    }
}

Describe 'Parallel script entry point with an isolated Azure-response module' {
    It 'executes actual parallel workers and refuses to export a failed parallel run' {
        $moduleDirectory = Join-Path $TestDrive 'modules\Az.Accounts'
        $null = New-Item -ItemType Directory -Path $moduleDirectory -Force
        $module = @'
function Get-AzContext {
    [pscustomobject]@{
        Tenant = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000010' }
        Subscription = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000001' }
        Environment = [pscustomobject]@{ ResourceManagerUrl = 'https://management.azure.com/' }
    }
}
function Get-AzSubscription {
    param($TenantId)
    [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000001'; State = 'Enabled' }
}
function Set-AzContext {
    param($SubscriptionId, $Context, $Scope)
    Get-AzContext
}
function Invoke-AzRestMethod {
    param($Method, $Path, $DefaultProfile)
    if ($Method -ne 'GET') { throw 'Only read-only requests are allowed in this fixture.' }
    if ($env:STORAGE_ESTIMATION_FIXTURE_FAILURE -eq '1' -and $Path -match '/parallel12/blobServices/') {
        return [pscustomobject]@{ StatusCode = 403; Content = '{}' }
    }
    if ($Path -match '/providers/Microsoft.Storage/storageAccounts\?') {
        $body = @{ value = @(1..12 | ForEach-Object {
            @{
                id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/fixture/providers/Microsoft.Storage/storageAccounts/parallel$_"
                name = "parallel$_"
                properties = @{ primaryEndpoints = @{ blob = 'https://fixture.invalid/blob'; file = '' } }
            }
        }) }
    } else {
        $name = $(if ($Path -match 'metricnames=Ingress') { 'Ingress' } else { 'Transactions' })
        $total = $(if ($name -eq 'Ingress') { 1073741824 } else { 0 })
        $body = @{ value = @(@{ name = @{ value = $name }; timeseries = @(@{ data = @(@{ total = $total }) }) }) }
    }
    [pscustomobject]@{ StatusCode = 200; Content = ($body | ConvertTo-Json -Depth 20 -Compress) }
}
'@
        Set-Content -LiteralPath (Join-Path $moduleDirectory 'Az.Accounts.psm1') -Value $module -Encoding utf8
        New-ModuleManifest -Path (Join-Path $moduleDirectory 'Az.Accounts.psd1') `
            -RootModule 'Az.Accounts.psm1' -ModuleVersion '99.0.0' `
            -FunctionsToExport @('Get-AzContext', 'Get-AzSubscription', 'Set-AzContext', 'Invoke-AzRestMethod')
        $csv = Join-Path $TestDrive 'parallel.csv'
        $failedCsv = Join-Path $TestDrive 'parallel-failed.csv'
        $savedModulePath = $env:PSModulePath
        $savedFailure = $env:STORAGE_ESTIMATION_FIXTURE_FAILURE
        try {
            $env:PSModulePath = "$(Join-Path $TestDrive 'modules')$([System.IO.Path]::PathSeparator)$savedModulePath"
            $env:STORAGE_ESTIMATION_FIXTURE_FAILURE = '0'
            $pwsh = (Get-Process -Id $PID).Path
            $output = & $pwsh -NoLogo -NoProfile -File $script:estimatorPath `
                -SampleDays 30 -ThrottleLimit 4 -OutputPath $csv 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Parallel fixture execution failed: $($output -join [Environment]::NewLine)"
            }
            $env:STORAGE_ESTIMATION_FIXTURE_FAILURE = '1'
            $failedOutput = & $pwsh -NoLogo -NoProfile -File $script:estimatorPath `
                -SampleDays 30 -ThrottleLimit 4 -OutputPath $failedCsv 2>&1
            $LASTEXITCODE | Should -Not -Be 0
            ($failedOutput -join [Environment]::NewLine) | Should -Match 'HTTP 403'
            Test-Path -LiteralPath $failedCsv | Should -BeFalse
        } finally {
            $env:PSModulePath = $savedModulePath
            $env:STORAGE_ESTIMATION_FIXTURE_FAILURE = $savedFailure
        }
        $rows = @(Import-Csv -LiteralPath $csv)
        $rows.Count | Should -Be 12
        @($rows | Where-Object { $_.MetricsStatus -eq 'Complete' }).Count | Should -Be 12
        @($rows | Where-Object { $_.EstimatedMonthlyCost -eq '10.15' }).Count | Should -Be 12
    }
}
