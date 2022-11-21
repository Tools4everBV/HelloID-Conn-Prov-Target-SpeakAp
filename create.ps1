#####################################################
# HelloID-Conn-Prov-Target-Speakap-Create
#
# Version: 1.0.1
#####################################################
# Initialize default value's
$config = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
$success = $false
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

$accountCreate = [ordered]@{
    schemas    = @("urn:ietf:params:scim:schemas:core:2.0:User")
    userName   = $p.ExternalId
    Sleutel    = $p.ExternalId
    upn        = $p.Accounts.MicrosoftActiveDirectory.userPrincipalName
    externalId = $p.externalId
    active     = $true
    name = @{
        givenName  = $p.Name.NickName
        familyName = $p.Name.FamilyName
    }
    emails = @(@{
        value   = $p.Contact.Business.Email
        primary = $true
        type    = "Work"
    })
    title = $p.PrimaryContract.Title.Name
    "urn:speakap:params:scim:bag" = @{
        login = $p.externalId
    }
    "urn:scim:schemas:extension:enterprise:2.0" = @{
        employeeNumber = $p.ExternalId
        department = $p.PrimaryContract.Department
    }
}

$accountCorrelate = [ordered]@{
    schemas  = @("urn:ietf:params:scim:schemas:core:2.0:User")
    userName = $p.ExternalId
    active   = $true
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

# Begin
try {
    Write-Verbose "Creating Speakap account for: '[$($p.DisplayName)]'"
    Write-Verbose 'Adding token to authorization headers'
    $headers = [System.Collections.Generic.Dictionary[string, string]]::new()
    $headers.Add("Authorization", "Bearer $($config.ApiToken)")

    Write-Verbose "Verifying if Speakap account for [$($p.DisplayName)] exists"
    $splatTotalUsersParams = @{
        Uri     = "$($config.BaseUrl)/Users?filter=userName eq `"$($p.ExternalId)`""
        Method  = 'GET'
        Headers = $headers
    }
    $responseUser = Invoke-RestMethod @splatTotalUsersParams

    if ($responseUser.Resources){
        Write-Verbose "Account for '$($p.DisplayName)' found with id '$($responseUser.id)', switching to 'correlate'"
        $action = 'Correlate'
    } else {
        Write-Verbose "No account for '$($p.DisplayName)' has been found, switching to 'create'"
        $action = 'Create'
    }

    # Add an auditMessage showing what will happen during enforcement
    if ($dryRun -eq $True){
        $auditLogs.Add([PSCustomObject]@{
            Message = "$action Speakap account for: [$($p.DisplayName)], will be executed during enforcement"
        })
    }

    # Process
    if (-not($dryRun -eq $True)){
        switch ($action) {
            'Create' {
                Write-Verbose "Creating Speakap account for: [$($p.DisplayName)]"
                $splatCreateUserParams = @{
                    Uri         = "$($config.BaseUrl)/Users"
                    Headers     = $headers
                    Method      = 'POST'
                    Body        = $accountCreate | ConvertTo-Json -Depth 20
                    ContentType = 'application/scim+json'
                }
                $response = Invoke-RestMethod @splatCreateUserParams -Verbose:$false
                $accountReference = $response.id
                break
            }

            'Correlate'{
                $aRefCorr = $responseUser.Resources[0].id
                Write-Verbose "Correlating Speakap account for: [$($p.DisplayName)]"
                $splatParams = @{
                    Uri         = "$($config.BaseUrl)/Users/$aRefCorr"
                    Headers     = $headers
                    Body        = $accountCorrelate | ConvertTo-Json -Depth 20
                    Method      = 'PUT'
                    ContentType = 'application/scim+json'
                }
                $results = Invoke-RestMethod @splatParams -Verbose:$false
                if ($results.id){
                    $success = $true
                    $auditLogs.Add([PSCustomObject]@{
                        Message = "Correlation for account: $($p.DisplayName) was successful."
                        IsError = $False
                    })
                }
                $accountReference = $results.id
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
        Account          = $accountCreate
    }
    Write-Output $result | ConvertTo-Json -Depth 10
}
