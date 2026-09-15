#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'powershell' 'ActionRuntime.psm1')

function Get-CanonicalPath([string] $Path) {
    (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
}

function Assert-Contained([string] $Parent, [string] $Child, [string] $Label) {
    $relative = [IO.Path]::GetRelativePath($Parent, $Child)
    if ($relative -eq '..' -or $relative.StartsWith("..$([IO.Path]::DirectorySeparatorChar)")) {
        throw "$Label escapes the checkout"
    }
}

function Get-RequiredProperty([object] $Object, [string] $Name, [string] $Label) {
    if ($null -eq $Object) {
        throw "GitHub GraphQL response omitted $Label"
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        throw "GitHub GraphQL response omitted $Label"
    }

    $property.Value
}

function Invoke-GitHubCommit(
    [string] $Repository,
    [string] $Branch,
    [string] $ExpectedHeadOid,
    [string] $Message,
    [string[]] $Paths,
    [string] $Workspace,
    [string] $Token
) {
    $additions = @(
        foreach ($path in $Paths) {
            $absolutePath = Join-Path $Workspace $path
            [ordered]@{
                path     = $path
                contents = [Convert]::ToBase64String([IO.File]::ReadAllBytes($absolutePath))
            }
        }
    )
    $query = @'
mutation CreateVerifiedCommit($input: CreateCommitOnBranchInput!) {
  createCommitOnBranch(input: $input) {
    commit {
      oid
      signature {
        isValid
        state
        wasSignedByGitHub
      }
    }
    ref {
      target {
        oid
      }
    }
  }
}
'@
    $requestBody = [ordered]@{
        query     = $query
        variables = [ordered]@{
            input = [ordered]@{
                branch          = [ordered]@{
                    repositoryNameWithOwner = $Repository
                    branchName              = $Branch
                }
                expectedHeadOid = $ExpectedHeadOid
                fileChanges     = [ordered]@{
                    additions = $additions
                }
                message         = [ordered]@{
                    headline = $Message
                }
            }
        }
    } | ConvertTo-Json -Depth 10 -Compress
    $headers = @{
        Accept        = 'application/vnd.github+json'
        Authorization = "Bearer $Token"
        'User-Agent'  = 'SayakMukhopadhyay-bump-version-action'
    }

    $response = Invoke-RestMethod `
        -Method Post `
        -Uri 'https://api.github.com/graphql' `
        -Headers $headers `
        -ContentType 'application/json' `
        -Body $requestBody

    $errorsProperty = $response.PSObject.Properties['errors']
    $errors = @(
        if ($null -ne $errorsProperty) {
            $errorsProperty.Value
        }
    )
    if ($errors.Count) {
        $messages = @(
            $errors | ForEach-Object {
                $messageProperty = $_.PSObject.Properties['message']
                if ($null -eq $messageProperty -or -not $messageProperty.Value) {
                    'unknown GraphQL error'
                } else {
                    [string] $messageProperty.Value
                }
            }
        )
        throw "GitHub rejected the version commit: $($messages -join '; ')"
    }

    $data = Get-RequiredProperty $response 'data' 'data'
    $result = Get-RequiredProperty $data 'createCommitOnBranch' 'createCommitOnBranch result'
    $commit = Get-RequiredProperty $result 'commit' 'created commit'
    $commitOid = [string] (Get-RequiredProperty $commit 'oid' 'created commit OID')
    if ($commitOid -notmatch '^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$') {
        throw 'GitHub GraphQL response returned an invalid commit OID'
    }

    $signature = Get-RequiredProperty $commit 'signature' 'created commit signature'
    $isValid = Get-RequiredProperty $signature 'isValid' 'signature validity'
    $state = [string] (Get-RequiredProperty $signature 'state' 'signature state')
    $wasSignedByGitHub = Get-RequiredProperty $signature 'wasSignedByGitHub' 'GitHub signature provenance'
    if ($isValid -ne $true -or $state -ne 'VALID' -or $wasSignedByGitHub -ne $true) {
        throw "GitHub did not return a valid GitHub-signed commit (state: $state)"
    }

    $ref = Get-RequiredProperty $result 'ref' 'updated branch ref'
    $target = Get-RequiredProperty $ref 'target' 'updated branch target'
    $branchOid = [string] (Get-RequiredProperty $target 'oid' 'updated branch OID')
    if ($branchOid -ne $commitOid) {
        throw 'GitHub returned a branch OID that does not match the created commit'
    }

    Write-Output "Published GitHub-verified commit $commitOid to $Repository@$Branch"
}

function Invoke-GitTransaction([ValidateSet('check-clean', 'commit')] [string] $Mode) {
    $workspaceValue = if ($env:GITHUB_WORKSPACE) {
        $env:GITHUB_WORKSPACE
    } else {
        (Get-Location).Path
    }

    $workspace = Get-CanonicalPath $workspaceValue
    Push-Location $workspace
    try {
        if ($Mode -eq 'check-clean') {
            if (Invoke-NativeProcess git @('status', '--porcelain')) {
                throw 'checkout is not clean before version mutation'
            }
            return
        }

        $helm = $env:INPUT_HELM -eq 'true'
        $go = $env:INPUT_GO -eq 'true'

        if (-not $helm -and -not $go) {
            Write-Output 'No version target was selected; nothing to do'
            return
        }

        $workingDirectory = if ($env:INPUT_WORKING_DIRECTORY) {
            $env:INPUT_WORKING_DIRECTORY
        } else {
            '.'
        }
        $project = Get-CanonicalPath (Join-Path $workspace $workingDirectory)
        Assert-Contained $workspace $project 'working-directory'
        $expected = [Collections.Generic.List[string]]::new()
        $versionPattern = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

        if ($go) {
            if ($env:NEW_APPLICATION_VERSION -notmatch $versionPattern) {
                throw 'mutation did not produce a canonical application version'
            }
            $expected.Add([IO.Path]::GetRelativePath($workspace, (Join-Path $project 'VERSION')).Replace('\', '/'))
        }

        if ($helm) {
            if ($env:NEW_CHART_VERSION -notmatch $versionPattern) {
                throw 'mutation did not produce a canonical chart version'
            }
            $chartVersionPath = [IO.Path]::GetRelativePath(
                $workspace,
                (Join-Path $project 'charts/VERSION')
            ).Replace('\', '/')
            $chartMetadataPath = [IO.Path]::GetRelativePath(
                $workspace,
                (Join-Path $project 'charts/Chart.yaml')
            ).Replace('\', '/')

            $expected.Add($chartVersionPath)
            $expected.Add($chartMetadataPath)
        }

        foreach ($path in $expected) {
            $diff = Invoke-NativeProcess git @('diff', '--quiet', '--', $path) -RawOutput -AllowFailure
            if ($diff.ExitCode -eq 0) {
                throw "expected version file was not changed: $path"
            }
        }
        if (Invoke-NativeProcess git @('ls-files', '--others', '--exclude-standard')) {
            throw 'unexpected untracked files appeared during version mutation'
        }

        Invoke-NativeProcess git (@('add', '--') + $expected) | Out-Null
        if ((Invoke-NativeProcess git @('diff', '--quiet') -RawOutput -AllowFailure).ExitCode -ne 0) {
            throw 'unexpected unstaged changes appeared during version mutation'
        }

        $stagedResult = Invoke-NativeProcess git @('diff', '--cached', '--name-only', '-z') -RawOutput
        $staged = @($stagedResult.StandardOutput.Split([char] 0, [StringSplitOptions]::RemoveEmptyEntries))
        if ($staged.Count -ne $expected.Count -or @($staged | Where-Object { $_ -notin $expected }).Count) {
            throw 'version mutation staged unexpected files'
        }

        $message = if ($helm -and $go) {
            "feat: bump chart version to $env:NEW_CHART_VERSION and app version to $env:NEW_APPLICATION_VERSION"
        } elseif ($helm) {
            "feat: bump chart version to $env:NEW_CHART_VERSION"
        } else {
            "feat: bump app version to $env:NEW_APPLICATION_VERSION"
        }

        Assert-SingleLine $env:TARGET_REF 'current branch' | Out-Null
        $branchArguments = @('check-ref-format', '--branch', $env:TARGET_REF)
        $validBranch = Invoke-NativeProcess git $branchArguments -RawOutput -AllowFailure
        if ($validBranch.ExitCode) {
            throw 'current branch is not a valid branch name'
        }

        $repository = Assert-SingleLine $env:TARGET_REPOSITORY 'target repository'
        if ($repository -notmatch '^[^/\s]+/[^/\s]+$') {
            throw 'target repository must use owner/name format'
        }
        $token = Assert-SingleLine $env:INPUT_TOKEN 'token'
        $expectedHeadOid = Invoke-NativeProcess git @('rev-parse', '--verify', 'HEAD')
        if ($expectedHeadOid -notmatch '^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$') {
            throw 'checked-out HEAD is not a valid commit OID'
        }

        Invoke-GitHubCommit `
            -Repository $repository `
            -Branch $env:TARGET_REF `
            -ExpectedHeadOid $expectedHeadOid `
            -Message $message `
            -Paths $expected `
            -Workspace $workspace `
            -Token $token
    } finally {
        Pop-Location
    }
}

Export-ModuleMember -Function Invoke-GitTransaction
