# Consolidation ZIP selection tests
#
# Offline, self-contained tests for the helpers that decide which
# per-subscription report ZIPs belong to one logical run:
#
#   - Get-ConsolidationZipSet: unions the ZIPs written by the current
#     invocation (LastWriteTime >= SinceTime) with those recorded in the
#     resume state by earlier invocations of the same run. Selecting on
#     timestamp alone truncated the consolidated bundle on every -Resume:
#     subscriptions skipped as already-complete keep their original
#     LastWriteTime and fell outside the window, so the outer zip held only
#     the subs the resuming run happened to process.
#   - Add-CompletedSubscription: records (and refreshes) one sub's report
#     path so the above has something to work from.
#   - Save-CompletedSubscriptionIds / Get-CompletedSubscriptions: the
#     round-trip through the on-disk resume-state file, including the
#     backward-compatible read of a file written before the key existed.
#
# No live Azure: the fixtures are empty files and hand-written state JSON in
# a temp directory. No customer data.
#
# Run with: Invoke-Pester ./Tests/ConsolidationZipSet.Tests.ps1 -Output Detailed

BeforeAll {
    $script:FunctionsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/RunAllSubscriptions.Functions.ps1'
    if (-not (Test-Path $script:FunctionsPath))
    {
        throw "Could not find shared functions file at $script:FunctionsPath"
    }
    . $script:FunctionsPath

    $TargetFunctions = @('Get-ConsolidationZipSet', 'Add-CompletedSubscription', 'Get-CompletedSubscriptions', 'Save-CompletedSubscriptionIds')
    foreach ($Fn in $TargetFunctions)
    {
        if (-not (Get-Command $Fn -CommandType Function -ErrorAction SilentlyContinue))
        {
            throw "Expected function '$Fn' to be defined by $script:FunctionsPath, but it was not. Has it been renamed or removed?"
        }
    }

    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestRoot = Join-Path $TmpBase ("ConsolidationZipTest_" + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null

    # Create a per-sub report folder holding one ZIP, backdating both so the
    # fixture models output from an earlier run.
    function New-SubReport
    {
        param([string]$Root, [string]$Stamp, [datetime]$Written)

        $Dir = Join-Path $Root ("ResourcesReport" + $Stamp)
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $Zip = Join-Path $Dir ("ResourcesReport_" + $Stamp + ".zip")
        Set-Content -Path $Zip -Value 'stub' -Encoding utf8
        (Get-Item -LiteralPath $Zip).LastWriteTime = $Written
        (Get-Item -LiteralPath $Dir).LastWriteTime = $Written
        return $Zip
    }
}

AfterAll {
    if ($script:TestRoot -and (Test-Path $script:TestRoot))
    {
        Remove-Item -Path $script:TestRoot -Recurse -Force
    }
}

Describe 'Get-ConsolidationZipSet' {
    BeforeEach {
        $script:CaseDir = Join-Path $script:TestRoot ([guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:CaseDir -Force | Out-Null
        $script:Now = Get-Date
        $script:Old = $script:Now.AddHours(-3)
    }

    AfterEach {
        if (Test-Path $script:CaseDir) { Remove-Item -Path $script:CaseDir -Recurse -Force }
    }

    It 'includes a prior-run zip recorded in the resume state' {
        $PriorZip = New-SubReport -Root $script:CaseDir -Stamp '001' -Written $script:Old
        $ThisRunZip = New-SubReport -Root $script:CaseDir -Stamp '002' -Written $script:Now
        $Recorded = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A'; ZipPath = $PriorZip })

        $Set = @(Get-ConsolidationZipSet -InventoryRoot $script:CaseDir -SinceTime $script:Now.AddMinutes(-1) -RecordedCompleted $Recorded)

        $Set.Count | Should -Be 2 -Because 'the bundle spans the whole logical run, not just this invocation'
        $Set | Should -Contain $PriorZip
        $Set | Should -Contain $ThisRunZip
    }

    It 'reproduces timestamp-only selection when nothing is recorded' {
        $null = New-SubReport -Root $script:CaseDir -Stamp '001' -Written $script:Old
        $ThisRunZip = New-SubReport -Root $script:CaseDir -Stamp '002' -Written $script:Now

        $Set = @(Get-ConsolidationZipSet -InventoryRoot $script:CaseDir -SinceTime $script:Now.AddMinutes(-1) -RecordedCompleted @())

        $Set.Count | Should -Be 1 -Because 'a fresh run must behave exactly as before'
        $Set | Should -Contain $ThisRunZip
    }

    It 'lists a re-run subscription only once' {
        $Zip = New-SubReport -Root $script:CaseDir -Stamp '001' -Written $script:Now
        $Recorded = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A'; ZipPath = $Zip })

        $Set = @(Get-ConsolidationZipSet -InventoryRoot $script:CaseDir -SinceTime $script:Now.AddMinutes(-1) -RecordedCompleted $Recorded)

        $Set.Count | Should -Be 1 -Because 'a sub both recorded and re-run this invocation is still one report'
    }

    It 'warns and continues when a recorded zip has been deleted' {
        $ThisRunZip = New-SubReport -Root $script:CaseDir -Stamp '002' -Written $script:Now
        $Missing = Join-Path $script:CaseDir 'ResourcesReport999/ResourcesReport_999.zip'
        $Recorded = @([pscustomobject]@{ Id = 'sub-gone'; Name = 'Gone'; ZipPath = $Missing })

        $Set = @(Get-ConsolidationZipSet -InventoryRoot $script:CaseDir -SinceTime $script:Now.AddMinutes(-1) -RecordedCompleted $Recorded 3>$null)

        $Set.Count | Should -Be 1 -Because 'a missing prior report must not abort the bundle'
        $Set | Should -Contain $ThisRunZip
        $Set | Should -Not -Contain $Missing
    }

    It 'excludes an unrelated older zip that was never recorded' {
        $Unrelated = New-SubReport -Root $script:CaseDir -Stamp '001' -Written $script:Old
        $ThisRunZip = New-SubReport -Root $script:CaseDir -Stamp '002' -Written $script:Now

        $Set = @(Get-ConsolidationZipSet -InventoryRoot $script:CaseDir -SinceTime $script:Now.AddMinutes(-1) -RecordedCompleted @())

        $Set | Should -Not -Contain $Unrelated -Because 'output from a different inventory must not be swept in'
        $Set | Should -Contain $ThisRunZip
    }

    It 'returns empty for an inventory root that does not exist' {
        $Set = @(Get-ConsolidationZipSet -InventoryRoot (Join-Path $script:CaseDir 'nope') -SinceTime $script:Now -RecordedCompleted @())
        $Set.Count | Should -Be 0
    }
}

Describe 'Add-CompletedSubscription' {
    It 'records a subscription with its report path' {
        $Result = @(Add-CompletedSubscription -Existing @() -Id 'sub-a' -Name 'Sub A' -ZipPath '/tmp/a.zip')

        $Result.Count | Should -Be 1
        $Result[0].Id | Should -Be 'sub-a'
        $Result[0].ZipPath | Should -Be '/tmp/a.zip'
        $Result[0].CompletedAt | Should -Not -BeNullOrEmpty
    }

    It 'replaces the entry for a re-run subscription rather than duplicating it' {
        $First = @(Add-CompletedSubscription -Existing @() -Id 'sub-a' -Name 'Sub A' -ZipPath '/tmp/old.zip')
        $Second = @(Add-CompletedSubscription -Existing $First -Id 'sub-a' -Name 'Sub A' -ZipPath '/tmp/new.zip')

        $Second.Count | Should -Be 1 -Because 'a stale path would point the bundle at the wrong report'
        $Second[0].ZipPath | Should -Be '/tmp/new.zip'
    }

    It 'preserves entries for other subscriptions' {
        $Existing = @(Add-CompletedSubscription -Existing @() -Id 'sub-a' -Name 'Sub A' -ZipPath '/tmp/a.zip')
        $Result = @(Add-CompletedSubscription -Existing $Existing -Id 'sub-b' -Name 'Sub B' -ZipPath '/tmp/b.zip')

        $Result.Count | Should -Be 2
        @($Result | Where-Object { $_.Id -eq 'sub-a' }).Count | Should -Be 1
    }
}

Describe 'Resume-state round-trip' {
    BeforeEach {
        $script:StateFile = Join-Path $script:TestRoot ([guid]::NewGuid().ToString().Substring(0, 8) + '.json')
    }

    AfterEach {
        if (Test-Path $script:StateFile) { Remove-Item -Path $script:StateFile -Force }
    }

    It 'persists and reads back recorded report paths' {
        $Completed = @(Add-CompletedSubscription -Existing @() -Id 'sub-a' -Name 'Sub A' -ZipPath '/tmp/a.zip')
        Save-CompletedSubscriptionIds -Path $script:StateFile -Tenant 'tenant-1' -Ids @('sub-a') -Completed $Completed

        $Read = @(Get-CompletedSubscriptions -Path $script:StateFile -Tenant 'tenant-1')

        $Read.Count | Should -Be 1
        $Read[0].ZipPath | Should -Be '/tmp/a.zip'
    }

    It 'does not return records belonging to a different tenant' {
        $Completed = @(Add-CompletedSubscription -Existing @() -Id 'sub-a' -Name 'Sub A' -ZipPath '/tmp/a.zip')
        Save-CompletedSubscriptionIds -Path $script:StateFile -Tenant 'tenant-1' -Ids @('sub-a') -Completed $Completed

        $Read = @(Get-CompletedSubscriptions -Path $script:StateFile -Tenant 'tenant-2')

        $Read.Count | Should -Be 0
    }

    It 'reads a state file written before CompletedSubscriptions existed as empty' {
        $Legacy = [pscustomobject]@{
            TenantID                 = 'tenant-1'
            CompletedSubscriptionIds = @('sub-a')
            FailedAttempts           = @()
            LastUpdated              = (Get-Date).ToString('o')
        }
        $Legacy | ConvertTo-Json -Depth 4 | Set-Content -Path $script:StateFile -Encoding utf8

        $Read = @(Get-CompletedSubscriptions -Path $script:StateFile -Tenant 'tenant-1')

        $Read.Count | Should -Be 0 -Because 'an older state file must degrade to timestamp-only selection, not throw'
        @(Get-CompletedSubscriptionIds -Path $script:StateFile -Tenant 'tenant-1').Count | Should -Be 1
    }

    It 'returns empty for a missing state file' {
        @(Get-CompletedSubscriptions -Path (Join-Path $script:TestRoot 'absent.json') -Tenant 'tenant-1').Count | Should -Be 0
    }
}
