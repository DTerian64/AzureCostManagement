# Azure Cost Report - All Resource Groups
# This script queries costs for all resource groups and consolidates into one report

# Ensure you're logged in
$context = Get-AzContext
if (-not $context) {
    Write-Host "Not logged in. Running Connect-AzAccount..." -ForegroundColor Yellow
    Connect-AzAccount
}

$subscriptionId = (Get-AzContext).Subscription.Id
Write-Host "Analyzing costs for subscription: $subscriptionId" -ForegroundColor Cyan
Write-Host "Timeframe: Month to Date`n" -ForegroundColor Cyan

# Get all resource groups
$resourceGroups = Get-AzResourceGroup
Write-Host "Found $($resourceGroups.Count) resource groups`n" -ForegroundColor Green

# Create aggregation and grouping objects (reusable)
$aggregation = @{
    totalCost = @{
        name = "Cost"
        function = "Sum"
    }
}

$grouping = @{
    Name = "ResourceId"
    Type = "Dimension"
}

# Collection for all results
$allCosts = @()
$rgSummary = @()

# Loop through each resource group
foreach ($rg in $resourceGroups) {
    Write-Host "Querying: $($rg.ResourceGroupName)..." -NoNewline
    
    $scope = "/subscriptions/$subscriptionId/resourceGroups/$($rg.ResourceGroupName)"
    
    try {
        # Query costs for this resource group
        $result = Invoke-AzCostManagementQuery `
            -Scope $scope `
            -Timeframe MonthToDate `
            -Type Usage `
            -DatasetGranularity None `
            -DatasetAggregation $aggregation `
            -DatasetGrouping $grouping `
            -ErrorAction Stop
        
        # Process results
        if ($result.Row.Count -gt 0) {
            $rgTotal = 0
            
            foreach ($row in $result.Row) {
                try {
                    # Determine which column is which based on content
                    $cost = 0
                    $currency = "USD"
                    $resourcePath = ""
                    
                    # Try to parse each field intelligently
                    foreach ($field in $row) {
                        $fieldStr = [string]$field
                        if ($fieldStr -match '^[\d\.]+$') {
                            # This is a number (cost)
                            $cost = [decimal]$fieldStr
                        }
                        elseif ($fieldStr -eq "USD" -or $fieldStr -eq "EUR" -or $fieldStr -eq "GBP" -or $fieldStr -match '^[A-Z]{3}$') {
                            # This is currency
                            $currency = $fieldStr
                        }
                        elseif ($fieldStr -match '^/subscriptions/') {
                            # This is a resource path
                            $resourcePath = $fieldStr
                        }
                    }
                    
                    if ($resourcePath) {
                        $resourceName = $resourcePath.Split('/')[-1]
                        $resourceType = $resourcePath.Split('/')[-3] + '/' + $resourcePath.Split('/')[-2]
                        
                        $rgTotal += $cost
                        
                        # Add to detailed collection
                        $allCosts += [PSCustomObject]@{
                            ResourceGroup = $rg.ResourceGroupName
                            Resource = $resourceName
                            ResourceType = $resourceType
                            Cost = $cost
                            Currency = $currency
                        }
                    }
                }
                catch {
                    Write-Host "`n  Warning: Could not parse row - $($_.Exception.Message)" -ForegroundColor Yellow
                    continue
                }
            }
            
            # Add to summary
            $rgSummary += [PSCustomObject]@{
                ResourceGroup = $rg.ResourceGroupName
                ResourceCount = $result.Row.Count
                TotalCost = $rgTotal
                Currency = "USD"
            }
            
            Write-Host " $rgTotal USD ($($result.Row.Count) resources)" -ForegroundColor Green
        }
        else {
            Write-Host " No costs" -ForegroundColor Gray
        }
    }
    catch {
        Write-Host " Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Display Results
Write-Host "`n" + "="*80 -ForegroundColor Cyan
Write-Host "RESOURCE GROUP SUMMARY" -ForegroundColor Cyan
Write-Host "="*80 -ForegroundColor Cyan
$rgSummary | Sort-Object TotalCost -Descending | Format-Table -AutoSize

$totalCost = ($rgSummary | Measure-Object -Property TotalCost -Sum).Sum
Write-Host "TOTAL SUBSCRIPTION COST: `$$totalCost USD" -ForegroundColor Yellow -BackgroundColor DarkGreen

Write-Host "`n" + "="*80 -ForegroundColor Cyan
Write-Host "TOP 10 MOST EXPENSIVE RESOURCES" -ForegroundColor Cyan
Write-Host "="*80 -ForegroundColor Cyan
$allCosts | Sort-Object Cost -Descending | Select-Object -First 10 | Format-Table -AutoSize

Write-Host "`n" + "="*80 -ForegroundColor Cyan
Write-Host "COSTS BY RESOURCE TYPE" -ForegroundColor Cyan
Write-Host "="*80 -ForegroundColor Cyan
$allCosts | Group-Object ResourceType | ForEach-Object {
    [PSCustomObject]@{
        ResourceType = $_.Name
        TotalCost = ($_.Group | Measure-Object -Property Cost -Sum).Sum
        ResourceCount = $_.Count
    }
} | Sort-Object TotalCost -Descending | Format-Table -AutoSize

# Export options
Write-Host "`nExport Options:" -ForegroundColor Yellow
Write-Host "1. Export detailed costs to CSV"
Write-Host "2. Export summary to CSV"
Write-Host "3. Export both"
Write-Host "4. Skip export"

$choice = Read-Host "`nEnter choice (1-4)"

switch ($choice) {
    "1" {
        $allCosts | Export-Csv -Path "azure_detailed_costs.csv" -NoTypeInformation
        Write-Host "Detailed costs exported to: azure_detailed_costs.csv" -ForegroundColor Green
    }
    "2" {
        $rgSummary | Export-Csv -Path "azure_rg_summary.csv" -NoTypeInformation
        Write-Host "Summary exported to: azure_rg_summary.csv" -ForegroundColor Green
    }
    "3" {
        $allCosts | Export-Csv -Path "azure_detailed_costs.csv" -NoTypeInformation
        $rgSummary | Export-Csv -Path "azure_rg_summary.csv" -NoTypeInformation
        Write-Host "Exported both files" -ForegroundColor Green
    }
    default {
        Write-Host "Skipping export" -ForegroundColor Gray
    }
}

Write-Host "`nAnalysis complete!" -ForegroundColor Green