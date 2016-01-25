[cmdletbinding()]
param(
    [string] $Comment = "",
    [string] $IncludeNoCIComment = $true,
    [string] $Itemspec = "$/*",
    [string] $Recursion = "Full",
    [string] $ConfirmUnderstand = $false,
    [string] $OverridePolicy = $false,
    [string] $OverridePolicyReason = ""
)

if (-not ($ConfirmUnderstand -eq $true))
{
    Write-Error "Checking in sources during build can cause delays in your builds, recursive builds, mismatches between sources and symbols and other issues."
}

Write-Verbose "Importing modules"
import-module "Microsoft.TeamFoundation.DistributedTask.Task.Internal"
import-module "Microsoft.TeamFoundation.DistributedTask.Task.Common"

[System.Reflection.Assembly]::LoadFrom("$env:AGENT_HOMEDIRECTORY\Agent\Worker\Microsoft.TeamFoundation.Client.dll") | Out-Null
[System.Reflection.Assembly]::LoadFrom("$env:AGENT_HOMEDIRECTORY\Agent\Worker\Microsoft.TeamFoundation.Common.dll") | Out-Null
[System.Reflection.Assembly]::LoadFrom("$env:AGENT_HOMEDIRECTORY\Agent\Worker\Microsoft.TeamFoundation.VersionControl.Client.dll") | Out-Null


$OnAssemblyResolve = [System.ResolveEventHandler] {
    param($sender, $e)
    foreach($a in [System.AppDomain]::CurrentDomain.GetAssemblies())
    {
        if ($a.FullName -eq $e.Name)
        {
            return $a
        }
    }

    if ($path = (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0" -Name 'ShellFolder' -ErrorAction Ignore).ShellFolder) {
         $path = $path.TrimEnd('\'[0]) + "\Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\" + $e.Name + ".dll"
        if (Test-Path -PathType Leaf -LiteralPath $path)
        {
            return [System.Reflection.Assembly]::LoadFrom($path)
        }
    }

    return $null
}
[System.AppDomain]::CurrentDomain.add_AssemblyResolve($OnAssemblyResolve)

[System.Reflection.Assembly]::Load("Microsoft.TeamFoundation.WorkItemTracking.Client") | Out-Null

function Get-SourceProvider {
    [cmdletbinding()]
    param()

    $provider = @{
        Name = $env:BUILD_REPOSITORY_PROVIDER
        SourcesRootPath = $env:BUILD_SOURCESDIRECTORY
        TeamProjectId = $env:SYSTEM_TEAMPROJECTID
    }
    $success = $false
    try {
        if ($provider.Name -eq 'TfsGit') {
            $provider.CollectionUrl = "$env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI".TrimEnd('/')
            $provider.RepoId = $env:BUILD_REPOSITORY_ID
            $provider.CommitId = $env:BUILD_SOURCEVERSION
            $success = $true
            return New-Object psobject -Property $provider
        }
        
        if ($provider.Name -eq 'TfsVersionControl') {
            $serviceEndpoint = Get-ServiceEndpoint -Context $distributedTaskContext -Name $env:BUILD_REPOSITORY_NAME
            $tfsClientCredentials = Get-TfsClientCredentials -ServiceEndpoint $serviceEndpoint
            
            $provider.TfsTeamProjectCollection = New-Object Microsoft.TeamFoundation.Client.TfsTeamProjectCollection(
                $serviceEndpoint.Url,
                $tfsClientCredentials)
            $versionControlServer = $provider.TfsTeamProjectCollection.GetService([Microsoft.TeamFoundation.VersionControl.Client.VersionControlServer])
            $provider.Workspace = $versionControlServer.TryGetWorkspace($provider.SourcesRootPath)
            if (!$provider.Workspace) {
                Write-Verbose "Unable to determine workspace from source folder: $($provider.SourcesRootPath)"
                Write-Verbose "Attempting to resolve workspace recursively from locally cached info."
                $workspaceInfos = [Microsoft.TeamFoundation.VersionControl.Client.Workstation]::Current.GetLocalWorkspaceInfoRecursively($provider.SourcesRootPath);
                if ($workspaceInfos) {
                    foreach ($workspaceInfo in $workspaceInfos) {
                        Write-Verbose "Cached workspace info discovered. Server URI: $($workspaceInfo.ServerUri) ; Name: $($workspaceInfo.Name) ; Owner Name: $($workspaceInfo.OwnerName)"
                        try {
                            $provider.Workspace = $versionControlServer.GetWorkspace($workspaceInfo)
                            break
                        } catch {
                            Write-Verbose "Determination failed. Exception: $_"
                        }
                    }
                }
            }

            if ((!$provider.Workspace) -and $env:BUILD_REPOSITORY_TFVC_WORKSPACE) {
                Write-Verbose "Attempting to resolve workspace by name: $env:BUILD_REPOSITORY_TFVC_WORKSPACE"
                try {
                    $provider.Workspace = $versionControlServer.GetWorkspace($env:BUILD_REPOSITORY_TFVC_WORKSPACE, '.')
                } catch [Microsoft.TeamFoundation.VersionControl.Client.WorkspaceNotFoundException] {
                    Write-Verbose "Workspace not found."
                } catch {
                    Write-Verbose "Determination failed. Exception: $_"
                }
            }

            if (!$provider.Workspace) {
                Write-Warning (Get-LocalizedString -Key 'Unable to determine workspace from source folder ''{0}''.' -ArgumentList $provider.SourcesRootPath)
                return
            }

            $success = $true
            return New-Object psobject -Property $provider
        }

        Write-Warning (Get-LocalizedString -Key 'Only TfsGit and TfsVersionControl source providers are supported for source indexing. Repository type: {0}' -ArgumentList $provider)
        Write-Warning (Get-LocalizedString -Key 'Unable to index sources.')
        return
    } finally {
        if (!$success) {
            Invoke-DisposeSourceProvider -Provider $provider
        }
    }
}

function Invoke-DisposeSourceProvider {
    [cmdletbinding()]
    param($Provider)

    if ($Provider.TfsTeamProjectCollection) {
        Write-Verbose 'Disposing tfsTeamProjectCollection'
        $Provider.TfsTeamProjectCollection.Dispose()
        $Provider.TfsTeamProjectCollection = $null
    }
}

Function Evaluate-Checkin {
    [cmdletbinding()]
    param(
        $checkinWorkspace, 
        $checkinEvaluationOptions, 
        $allChanges, 
        $checkinChanges, 
        $comment, 
        $note, 
        $checkedWorkitems,
        [ref] $passed
    )

    Write-Verbose "Entering Evaluate-Checkin"
    Try
    {
        $passed = $true
        $result = $checkinWorkspace.EvaluateCheckin2($checkinEvaluationOptions, $allChanges, $checkinChanges, $comment, $checkinNotes, $checkedWorkItems);
        if (-not $result.Conflicts.Length -eq 0)
        {
            $passed = $false
            foreach ($conflict in $result.Conflicts)
            {
                if ($conflict.Resolvable)
                {
                    Write-Warning $conflict.Message
                }
                else
                {
                    Write-Error $conflict.Message
                }
            }
        }
        if (-not $result.NoteFailures.Count -eq 0)
        {
            foreach ($noteFailure in $result.NoteFailures)
            {
                Write-Warning "$($noteFailure.Definition.Name): $($noteFailure.Message)"
            }
            $passed = $false;
        }
        if (-not $result.PolicyEvaluationException -eq $null)
        {
            Write-Error($result.PolicyEvaluationException.Message);
            $passed = $false;
        }
        return $result
    }
    Finally
    {
        Write-Verbose "Leaving Evaluate-Checkin"
    }
}

 
Function Handle-PolicyOverride {
    [cmdletbinding()]
    param(
        [Microsoft.TeamFoundation.VersionControl.Client.PolicyFailure[]] $policyFailures, 
        [string] $overrideComment,
        [ref] $passed
    )

    Write-Verbose "Entering Handle-PolicyOverride"

    Try
    {
        $passed = $true

        if (-not $policyFailures.Length -eq 0)
        {
            foreach ($failure in $policyFailures)
            {
                Write-Warning "$($failure.Message)"
            }
            if (-not $overrideComment -eq "")
            {
                return new-object Microsoft.TeamFoundation.VersionControl.Client.PolicyOverrideInfo( $overrideComment, $policyFailures )
            }
            $passed = $false
        }
        return $null
    }
    Finally
    {
        Write-Verbose "Leaving Handle-PolicyOverride"
    }
}

Try
{
    $noCiComment = "**NO_CI**"
    if ($IncludeNoCIComment -eq $true)
    {
        if ($Comment -eq "")
        {
            $Comment = $noCiComment
        }
        else
        {
            $Comment = "$Comment $noCiComment"
        }
    }
       


    $provider = Get-SourceProvider

    if (-not $Recursion -eq "")
    {
        $RecursionType = [Microsoft.TeamFoundation.VersionControl.Client.RecursionType]$Recursion
    }
    else
    {
        $RecursionType = [Microsoft.TeamFoundation.VersionControl.Client.RecursionType]"None"
    }

    if (-not $Itemspec -eq "")
    {
        [string[]] $FilesToCheckin = $ItemSpec -split "(;|\r?\n)"
        Write-Output $FilesToCheckin
        $pendingChanges = $provider.Workspace.GetPendingChanges( [string[]]@($FilesToCheckin), $RecursionType )
    }
    else
    {
        $pendingChanges = $provider.Workspace.GetPendingChanges($RecursionType)
    }

    $passed = [ref] $true

    $evaluationOptions = [Microsoft.TeamFoundation.VersionControl.Client.CheckinEvaluationOptions]"AddMissingFieldValues" -bor [Microsoft.TeamFoundation.VersionControl.Client.CheckinEvaluationOptions]"Notes" -bor [Microsoft.TeamFoundation.VersionControl.Client.CheckinEvaluationOptions]"Policies"
    $result = Evaluate-Checkin $provider.Workspace $evaluationOptions $pendingChanges $pendingChanges $comment @() $null $passed
 
    if (($passed -eq $false) -and $OverridePolicy)
    {   
        $override = Handle-PolicyOverride $result.PolicyFailures $OverridePolicyReason $passed
    }

    if ($override -eq $null -or $OverridePolicy)
    {
        Write-Verbose "Entering Workspace-Checkin"
        $provider.Workspace.CheckIn($pendingChanges, $Comment, [Microsoft.TeamFoundation.VersionControl.Client.CheckinNote]$null, [Microsoft.TeamFoundation.VersionControl.Client.WorkItemCheckinInfo[]]$null, [Microsoft.TeamFoundation.VersionControl.Client.PolicyOverrideInfo]$override)
        Write-Verbose "Leaving Workspace-Checkin"
    }
    else
    {
        Write-Error "Checkin policy failed"
    }
}
Finally
{
    Invoke-DisposeSourceProvider -Provider $provider
    [System.AppDomain]::CurrentDomain.remove_AssemblyResolve($OnAssemblyResolve)
}


