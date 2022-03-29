#####################################################
# HelloID-Conn-Prov-Target-Speakap-Create
#
# Version: 1.0.0
#####################################################
# Initialize default value's
$config = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
$success = $false
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

$account = [ordered]@{
    schemas  = @("urn:ietf:params:scim:schemas:core:2.0:User")
    userName = $p.ExternalId
    externalId = $p.externalId
    active   = $true
    name = @{
        givenName  = $p.Name.GivenName
        familyName = $p.Name.FamilyName
    }
    emails = @(@{
        value   = $p.Contact.Business.Email
        primary = $true
        type    = "Work"
    })
    title = 'Developer Account'
    "urn:speakap:params:scim:bag" = @{
        login = $p.externalId
    }
    "urn:scim:schemas:extension:enterprise:2.0" = @{
        employeeNumber = $p.ExternalId
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
function Invoke-PagedRestMethod {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Method,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Uri,

        [string]
        $ContentType = 'application/json',

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]
        $Headers,

        [string]
        $TotalResults
    )

    try {
        $splatParams = @{
            Uri         = $Uri
            Headers     = $Headers
            Method      = $Method
            ContentType = $ContentType
        }

        # Fixed value since each page contains 20 items max
        $count = 20
        $startIndex = 1
        [System.Collections.Generic.List[object]]$dataList = @()
        do {
            $splatParams['Uri'] = "$Uri?startIndex=$startIndex&count=$count"
            $result = Invoke-RestMethod @splatParams
            foreach ($resource in $result.Resources){
                $dataList.Add($resource)
            }
            $startIndex = $dataList.count
        } until ($dataList.Count -eq $TotalResults)
        Write-Output $dataList
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}

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

# Begin
try {
    Write-Verbose "Creating Speakap account for: '[$($p.DisplayName)]'"
    Write-Verbose 'Adding token to authorization headers'
    $headers = [System.Collections.Generic.Dictionary[string, string]]::new()
    $headers.Add("Authorization", "Bearer $($config.ApiToken)")

    Write-Verbose 'Getting total number of users'
    $splatTotalUsersParams = @{
        Uri     = "$($config.BaseUrl)/Users"
        Method  = 'GET'
        Headers = $headers
    }
    $responseTotal = Invoke-RestMethod @splatTotalUsersParams
    $totalResults = $responseTotal.totalResults

    Write-Verbose "Retrieving ['$totalResults'] users"
    $splatGetUserParams = @{
        Uri     = "$($config.BaseUrl)/Users"
        Method  = 'GET'
        Headers = $headers
    }
    if ($totalResults -gt 20){
        $splatTotalUsersParams['TotalResults'] = $totalResults
        $responseAllUsers = Invoke-PagedRestMethod @splatGetUserParams -Verbose:$false
    } else {
        $responseAllUsers = Invoke-RestMethod @splatGetUserParams -Verbose:$false
    }

    Write-Verbose "Verifying if account for '$($p.DisplayName)' must be created or correlated"
    $lookup = $responseAllUsers.Resources | Group-Object -Property 'externalId' -AsHashTable
    $userObject = $lookup[$account.externalId]
    if ($userObject){
        Write-Verbose "Account for '$($p.DisplayName)' found with id '$($userObject.id)', switching to 'correlate'"
        $action = 'Correlate'
    } else {
        Write-Verbose "No account for '$($p.DisplayName)' has been found, switching to 'create'"
        $action = 'Create'
    }

    # Add an auditMessage showing what will happen during enforcement
    if ($dryRun -eq $true){
        $auditLogs.Add([PSCustomObject]@{
            Message = "$action Speakap account for: [$($p.DisplayName)], will be executed during enforcement"
        })
    }

    # Process
    if (-not($dryRun -eq $true)){
        switch ($action) {
            'Create' {
                Write-Verbose "Creating Speakap account for: [$($p.DisplayName)]"
                $splatCreateUserParams = @{
                    Uri         = "$($config.BaseUrl)/Users"
                    Headers     = $headers
                    Method      = 'POST'
                    Body        = $account | ConvertTo-Json -Depth 20
                    ContentType = 'application/scim+json'
                }
                $response = Invoke-RestMethod @splatCreateUserParams -Verbose:$false
                $accountReference = $response.id
                break
            }

            'Correlate'{
                Write-Verbose "Correlating Speakap account for: [$($p.DisplayName)]"
                $accountReference = $userObject.id
                break
            }
        }

        $success = $true
        $auditLogs.Add([PSCustomObject]@{
            Message = "$action account for: [$($p.DisplayName)] was successful. accountReference is: [$accountReference]"
            IsError = $false
        })
    }
} catch {
    $success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-HTTPError -ErrorObject $ex
        $errorMessage = "Could not $action Speakap account for: [$($p.DisplayName)]. Error: $($errorObj.ErrorMessage)"
    } else {
        $errorMessage = "Could not $action Speakap account for: [$($p.DisplayName)]. Error: $($ex.Exception.Message)"
    }
    Write-Verbose $errorMessage
    $auditLogs.Add([PSCustomObject]@{
        Message = $errorMessage
        IsError = $true
    })
# End
} finally {
   $result = [PSCustomObject]@{
        Success          = $success
        AccountReference = $accountReference
        Auditlogs        = $auditLogs
        Account          = $account
    }
    Write-Output $result | ConvertTo-Json -Depth 10
}
