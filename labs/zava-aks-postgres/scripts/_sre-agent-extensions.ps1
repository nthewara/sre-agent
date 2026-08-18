#Requires -Version 7.4

function Get-ZavaAgentExtensionDefinitions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroup,
        [string]$ConfigRoot = (Join-Path $PSScriptRoot '..\sre-config')
    )

    $configPath = Join-Path $ConfigRoot 'agent-extensions.psd1'
    if (-not (Test-Path $configPath -PathType Leaf)) {
        throw "Required agent extension configuration is missing: $configPath"
    }

    $config = Import-PowerShellDataFile -Path $configPath
    $sharedContextPath = Join-Path $ConfigRoot 'skills\shared-context.md'
    if (-not (Test-Path $sharedContextPath -PathType Leaf)) {
        throw "Required shared skill context is missing: $sharedContextPath"
    }
    $sharedContext = ([System.IO.File]::ReadAllText($sharedContextPath)).Replace('@@RG@@', $ResourceGroup)

    $definitions = [System.Collections.Generic.List[object]]::new()
    foreach ($skill in $config.Skills) {
        $contentPath = Join-Path $ConfigRoot $skill.ContentFile
        if (-not (Test-Path $contentPath -PathType Leaf)) {
            throw "Required skill content is missing: $contentPath"
        }
        $skillContent = [System.IO.File]::ReadAllText($contentPath)
        $skillContent = $skillContent.Replace('@@SHARED@@', $sharedContext).Replace('@@RG@@', $ResourceGroup)
        $definitions.Add([pscustomobject]@{
            Kind = 'skills'
            Name = $skill.Name
            Type = 'Skill'
            Properties = [ordered]@{
                name = $skill.Name
                description = $skill.Description
                tools = @($skill.Tools)
                skillContent = $skillContent
                additionalFiles = @()
            }
        })
    }

    foreach ($filter in $config.IncidentFilters) {
        $definitions.Add([pscustomobject]@{
            Kind = 'incidentFilters'
            Name = $filter.Name
            Type = 'IncidentFilter'
            Properties = $filter.Properties
        })
    }

    return @($definitions)
}

function ConvertTo-ZavaAgentExtensionPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object]$Definition
    )

    process {
        [ordered]@{
            name = $Definition.Name
            type = $Definition.Type
            tags = @()
            properties = $Definition.Properties
        } | ConvertTo-Json -Depth 20 -Compress
    }
}

function Compare-ZavaAgentExtensionNameSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Expected,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Actual
    )

    $expectedNames = @($Expected | Sort-Object -Unique)
    $actualNames = @($Actual | Sort-Object -Unique)
    $duplicates = @($Actual | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
    $missing = @($expectedNames | Where-Object { $_ -notin $actualNames })
    $unexpected = @($actualNames | Where-Object { $_ -notin $expectedNames })

    [pscustomobject]@{
        IsExact = ($missing.Count -eq 0 -and $unexpected.Count -eq 0 -and $duplicates.Count -eq 0)
        Missing = $missing
        Unexpected = $unexpected
        Duplicates = $duplicates
    }
}

function Sync-ZavaAgentExtensions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Net.Http.HttpClient]$Client,
        [Parameter(Mandatory)]
        [uri]$AgentEndpoint,
        [Parameter(Mandatory)]
        [object[]]$Definitions,
        [ValidateRange(0, 120)]
        [int]$RetryDelaySeconds = 15,
        [ValidateRange(120, 600)]
        [int]$ReadinessBudgetSeconds = 120
    )

    foreach ($definition in $Definitions) {
        $encodedName = [uri]::EscapeDataString($definition.Name)
        $url = "$($AgentEndpoint.AbsoluteUri.TrimEnd('/'))/api/v2/extendedAgent/$($definition.Kind)/$encodedName"
        $payload = ConvertTo-ZavaAgentExtensionPayload -Definition $definition
        $lastFailure = $null
        $attempt = 0
        $deadline = (Get-Date).AddSeconds($ReadinessBudgetSeconds)

        while ((Get-Date) -lt $deadline) {
            $attempt++
            $response = $null
            $requestCancellation = $null
            $content = [System.Net.Http.StringContent]::new(
                $payload,
                [System.Text.Encoding]::UTF8,
                'application/json'
            )
            try {
                $remaining = $deadline - (Get-Date)
                $requestCancellation = [System.Threading.CancellationTokenSource]::new()
                $requestCancellation.CancelAfter([Math]::Max(1, [int][Math]::Floor($remaining.TotalMilliseconds)))
                $response = $Client.PutAsync($url, $content, $requestCancellation.Token).GetAwaiter().GetResult()
                $responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                if ($response.IsSuccessStatusCode) {
                    Write-Host "  [ok] $($definition.Kind)/$($definition.Name)" -ForegroundColor Green
                    $lastFailure = $null
                    break
                }
                $lastFailure = "HTTP $([int]$response.StatusCode) $($response.ReasonPhrase): $responseBody"
            } catch {
                $lastFailure = $_.Exception.Message
            } finally {
                if ($response) { $response.Dispose() }
                $content.Dispose()
                if ($requestCancellation) { $requestCancellation.Dispose() }
            }

            $remaining = $deadline - (Get-Date)
            if ($lastFailure -and $remaining.TotalMilliseconds -gt 0) {
                $sleepSeconds = [Math]::Min($RetryDelaySeconds, [Math]::Ceiling($remaining.TotalSeconds))
                Write-Host "  [retry] $($definition.Kind)/$($definition.Name) attempt $attempt failed; waiting ${sleepSeconds}s (bounded ${ReadinessBudgetSeconds}s readiness budget)" -ForegroundColor Yellow
                if ($sleepSeconds -gt 0) { Start-Sleep -Seconds $sleepSeconds }
            }
        }

        if ($lastFailure) {
            throw "Required data-plane sync failed for $($definition.Kind)/$($definition.Name) within the ${ReadinessBudgetSeconds}-second readiness budget after $attempt attempts. $lastFailure"
        }
    }
}
