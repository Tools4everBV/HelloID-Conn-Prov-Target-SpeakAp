#####################################################
# HelloID-Conn-Prov-Target-Speakap-Update
#
# Version: 1.0.0
#####################################################
# Initialize default value's
$config = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
$aRef = $AccountReference | ConvertFrom-Json
$pd = $personDifferences | ConvertFrom-Json
$success = $false
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

# Account mapping
$account = [ordered]@{
    schemas  = @("urn:ietf:params:scim:schemas:core:2.0:User")
    userName = $p.ExternalId
    active   = $true
    name = @{
        givenName  = $pd.Name.GivenName.New
        familyName = $pd.Name.FamilyName.New
    }
    emails = @(@{
        value   = $pd.Contact.Business.Email.New
        primary = $true
        type    = "Work"
    })
    title = 'Developer Account'
    "urn:speakap:params:scim:bag" = @{
        login = $p.externalId
    }
    "urn:scim:schemas:extension:enterprise:2.0" = @{
        department = $p.PrimaryContract.Department
    }
}

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Set debug logging
switch ($($config.IsDebug)) {
    $true { $VerbosePreference = 'Continue' }
    $false { $VerbosePreference = 'SilentlyContinue' }
}

#region functions
function Resolve-HTTPError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory,
            ValueFromPipeline
        )]
        [object]$ErrorObject
    )
    process {
        $httpErrorObj = [PSCustomObject]@{
            FullyQualifiedErrorId = $ErrorObject.FullyQualifiedErrorId
            MyCommand             = $ErrorObject.InvocationInfo.MyCommand
            RequestUri            = $ErrorObject.TargetObject.RequestUri
            ScriptStackTrace      = $ErrorObject.ScriptStackTrace
            ErrorMessage          = ''
        }
        if ($ErrorObject.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') {
            $httpErrorObj.ErrorMessage = $ErrorObject.ErrorDetails.Message
        } elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException') {
            $httpErrorObj.ErrorMessage = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
        }
        Write-Output $httpErrorObj
    }
}
#endregion

try {
    Write-Verbose "Updating Speakap account for: '[$($p.DisplayName)]'"
    Write-Verbose 'Adding token to authorization headers'
    $headers = [System.Collections.Generic.Dictionary[string, string]]::new()
    $headers.Add("Authorization", "Bearer $($config.ApiToken)")

    # Add an auditMessage showing what will happen during enforcement
    if ($dryRun -eq $true){
        $auditLogs.Add([PSCustomObject]@{
            Message = "Update Speakap account for: [$($p.DisplayName)], will be executed during enforcement"
        })
    }

    if (-not($dryRun -eq $true)) {
        Write-Verbose "Updating Speakap account: [$aRef] for: [$($p.DisplayName)]"

        $splatParams = @{
            Uri     = "$($config.BaseUrl)/Users/$aRef"
            Headers = $headers
            Body    = $account | ConvertTo-Json -Depth 20
            Method  = 'PUT'
            ContentType = 'application/scim+json'
        }
        $results = Invoke-RestMethod @splatParams -Verbose:$false
        if ($results.id){
            $success = $true
            $auditLogs.Add([PSCustomObject]@{
                Message = "Update account for: [$($p.DisplayName)] was successful."
                IsError = $false
            })
        }
    }
} catch {
    $success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-HTTPError -ErrorObject $ex
        $errorMessage = "Could not update Speakap account for: [$($p.DisplayName)]. Error: $($errorObj.ErrorMessage)"
    } else {
        $errorMessage = "Could not update Speakap account for: [$($p.DisplayName)]. Error: $($ex.Exception.Message)"
    }
    Write-Verbose $errorMessage
    $auditLogs.Add([PSCustomObject]@{
        Message = $errorMessage
        IsError = $true
    })
} finally {
    $result = [PSCustomObject]@{
        Success   = $success
        Account   = $account
        Auditlogs = $auditLogs
    }
    Write-Output $result | ConvertTo-Json -Depth 10
}
