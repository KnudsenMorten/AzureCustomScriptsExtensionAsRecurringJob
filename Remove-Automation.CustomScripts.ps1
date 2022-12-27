#Requires -Version 5.0
<#
    .SYNOPSIS
    Remove failed Azure Custom Scripts
    In case your custom script fails on a server, it should automatically go into a failed state.
    Then you are able to remove the extension by using Remove-AzConnectedMachineExtension (Azure Arc) or Remove-AzVMExtension (native VM)
    (you can see an example of this at the last section of this script)
    
    In some cases, I have also seen the powershell script to fail, caused by a misconfiguration in the powershell script, and when this
    happens, Azure will stay in a "waiting-mode", as it is looking for the powershell process to terminate.
    It is easy to reproduce this failure by running the script manually on the server, where it will go into a wait.
    The main purpose of this script is to handle this situation and terminate ANY running powershell sessions and cleaning up of the failed Azure Custom Extensions

    If you want to finetune this script in more details, then look for any powershell sessions with open handles in c:\packages\plugins

    .NOTES
    VERSION: 2212

    .COPYRIGHT
    @mortenknudsendk on Twitter (new followers appreciated)
    Blog: https://mortenknudsen.net
    
    .LICENSE
    Licensed under the MIT license.
    Please credit me if you fint this script useful and do some cool things with it.

    .WARRANTY
    Use at your own risk, no warranty given!
#>

#------------------------------------------------------------------------------------------------------------
# Functions
#------------------------------------------------------------------------------------------------------------
Function AZ_Find_Subscriptions_in_Tenant_With_Subscription_Exclusions
{
    Write-Output ""
    Write-Output "Finding all subscriptions in scope .... please Wait !"

    $global:Query_Exclude = @()
    $Subscriptions_in_Scope = @()
    $pageSize = 1000
    $iteration = 0

    ForEach ($Sub in $global:Exclude_Subscriptions)
        {
            $global:Query_Exclude    += "| where (subscriptionId !~ `"$Sub`")"
        }

    $searchParams = @{
                        Query = "ResourceContainers `
                                | where type =~ 'microsoft.resources/subscriptions' `
                                | extend status = properties.state `
                                $global:Query_Exclude
                                | project id, subscriptionId, name, status | order by id, subscriptionId desc" 
                        First = $pageSize
                        }

    $results = do {
        $iteration += 1
        $pageResults = Search-AzGraph -ManagementGroup $Global:ManagementGroupScope @searchParams
        $searchParams.Skip += $pageResults.Count
        $Subscriptions_in_Scope += $pageResults
    } while ($pageResults.Count -eq $pageSize)

    $Global:Subscriptions_in_Scope = $Subscriptions_in_Scope

    # Output
    $Global:Subscriptions_in_Scope
}

Function AZ_Find_All_Hybrid_VM_Resources
{
    # Build Exclude string
    AZ_Graph_Query_Build_Exclude_String

    Write-Output ""
    # Find all Azure ARC (Hybrid) VM Resources 
    Write-Output "Finding all Azure ARC (hybrid) VM Resources .... please Wait !"
    $QueryString = @()

    # Query string (begin)
        $QueryString = 
            "Resources `
            | where type == `"microsoft.hybridcompute/machines`" `
            "
    # Add Exlusions to Query string
        ForEach ($Line in $global:Query_Exclude)
            {
                $QueryString += $Line + " `n "
            }

    # Query string (end)
        $QueryString += 
            "| extend ostype = properties.osType `
            | extend provisioningState = properties.provisioningState `
            | extend licensetype = properties.licensetype `
            | extend displayname = properties.displayName `
            | extend status = properties.status `
            | extend computerName = properties.osprofile.computerName `
            | extend osVersion = properties.osVersion `
            | extend osName = properties.osName `
            | extend manufacturer = properties.detectedProperties.manufacturer `
            | extend model = properties.detectedProperties.model `
            | extend lastStatusChange = properties.lastStatusChange `
            | extend agentVersion = properties.agentVersion `
            | extend machineFqdn = properties.machineFqdn `
            | extend domainName = properties.domainName `
            | extend dnsFqdn = properties.dnsFqdn `
            | extend adFqdn = properties.adFqdn `
            | extend osSku = properties.osSku `
            | order by id, resourceGroup desc"

    $VMsInScope_All = @()
    $pageSize = 1000
    $iteration = 0
    $searchParams = @{
                        Query = $QueryString
                        First = $pageSize
                        }

    $results = do {
        $iteration += 1
        $pageResults = Search-AzGraph -ManagementGroup $Global:ManagementGroupScope @searchParams
        $searchParams.Skip += $pageResults.Count
        $VMsInScope_All += $pageResults
    } while ($pageResults.Count -eq $pageSize)

    # Results
        $Global:HybridVMsInScope_All = $VMsInScope_All
}

Function AZ_Find_All_Native_VM_Resources
{
    # Build Exclude string
    AZ_Graph_Query_Build_Exclude_String
    
    Write-Output ""
    # Find all Azure (native) VM Resources 
    Write-Output "Finding all Azure (native) VM Resources .... please Wait !"

    $QueryString = @()

    # Query string (begin)
        $QueryString = 
            "Resources `
            | where type == `"microsoft.compute/virtualmachines`" `
            "
    # Add Exlusions to Query string
        ForEach ($Line in $global:Query_Exclude)
            {
                $QueryString += $Line + " `n "
            }

    # Query string (end)
        $QueryString += 
            "| extend osType = properties.storageProfile.osDisk.osType `
            | extend osVersion = properties.extended.instanceView.osVersion `
            | extend osName = properties.extended.instanceView.osName `
            | extend vmName = properties.osProfile.computerName `
            | extend licenseType = properties.licenseType `
            | extend PowerState = properties.extended.instanceView.powerState.displayStatus `
            | order by id, resourceGroup desc"

    $VMsInScope_All = @()
    $pageSize = 1000
    $iteration = 0
    $searchParams = @{
                        Query = $QueryString
                        First = $pageSize
                        }

    $results = do {
        $iteration += 1
        $pageResults = Search-AzGraph -ManagementGroup $Global:ManagementGroupScope @searchParams
        $searchParams.Skip += $pageResults.Count
        $VMsInScope_All += $pageResults
    } while ($pageResults.Count -eq $pageSize)

    # Results
        $Global:NativeVMsInScope_All = $VMsInScope_All
}

Function AZ_Graph_Query_Build_Exclude_String
{
    $global:Query_Exclude = @()

    # Subscription
    ForEach ($Sub in $global:Exclude_Subscriptions)
        {
            $global:Query_Exclude    += "| where (subscriptionId !~ `"$Sub`")"
        }
    # ResourceGroup
    ForEach ($RessGrp in $global:Exclude_ResourceGroups)
        {
            $global:Query_Exclude    += "| where (resourceGroup !~ `"$RessGrp`")"
        }
    # Resource
    ForEach ($RessourceName in $global:Exclude_Resource)
        {
            $global:Query_Exclude    += "| where (name !~ `"$RessourceName`")"
        }
    # Resource_contains
    ForEach ($RessourceName in $global:Exclude_Resource_contains)
        {
            $global:Query_Exclude    += "| where (name !contains `"$RessourceName`")"
        }

    # Resource_startwith
    ForEach ($RessourceName in $global:Exclude_Resource_startswith)
        {
            $global:Query_Exclude    += "| where (name !startswith `"$RessourceName`")"
        }
    # Resource_endwith
    ForEach ($RessourceName in $global:Exclude_Resource_endswith)
        {
            $global:Query_Exclude    += "| where (name !endswith `"$RessourceName`")"
        }
}


Function Build_Extension_Status
{
    Write-Output ""
    Write-Output "Building status of all extensions .... please Wait !"

    # Query string (begin)
        $QueryString = 
"Resources `
| where (type == `"microsoft.compute/virtualmachines`") or (type == `"microsoft.hybridcompute/machines`") `
| extend JoinID = toupper(id) `
| join kind=leftouter( `
	Resources `
	    | where (type == `"microsoft.compute/virtualmachines/extensions`") or (type == `"microsoft.hybridcompute/machines/extensions`") `
	    | extend VMId = toupper(substring(id, 0, indexof(id, '/extensions')))
        | extend ExtName = name
        | extend ExtprovisioningState = properties.provisioningState
        | extend ExtType = properties.type
        | extend ExtAutoUpgradeMinorVersion = properties.autoUpgradeMinorVersion
        | extend ExtTypeHandlerVersion = properties.typeHandlerVersion
        | extend ExtPublisher = properties.publisher
        | extend ExtSettings = properties.settings
        | extend ExtStatus = properties.instanceView
        | extend ExtStatusMessage = properties.instanceView.status.message
        ) on `$left.JoinID == `$right.VMId"

    $Extensions_Graph = @()
    $pageSize = 1000
    $iteration = 0
    $searchParams = @{
                        Query = $QueryString
                        First = $pageSize
                        }

    $results = do {
        $iteration += 1
        $pageResults = Search-AzGraph -ManagementGroup $Global:ManagementGroupScope @searchParams
        $searchParams.Skip += $pageResults.Count
        $Extensions_Graph += $pageResults
    } while ($pageResults.Count -eq $pageSize)

    # Results
    $Global:Extension_Status_All_Computers_Array = $Extensions_Graph
}


####################################################
# CONNECT TO AZURE
####################################################

# Below is just a sample connect for demonstration purpose. Typically, I use modern authentication using e.g. Azure app and certificates
Connect-AzAccount


###################################
# Variables (scope)
###################################

# Scope (MG) | You can define the scope for the targetting, supporting management groups or tenant root id (all subs)
$Global:ManagementGroupScope                                    = "xxxxx" # can mg e.g. mg-company or AAD Id (=Tenant Root Id)

# Exclude list | You can exclude certain subs, resource groups, resources, if you don't want to have them as part of the scope
$global:Exclude_Subscriptions                                   = @("xxxxxxxxxxxxxxxxxxxxxx") # for example platform-connectivity
$global:Exclude_ResourceGroups                                  = @()
$global:Exclude_Resource                                        = @()
$global:Exclude_Resource_Contains                               = @()
$global:Exclude_Resource_Startswith                             = @("PCTXRDS","RCTXRDS")
$global:Exclude_Resource_Endswith                               = @()


###################################
# Variables (custom script)
###################################

# Custom Script Name
$global:CustomScript_RunScriptName                              = "Automation.CustomScripts"



######################################################################################
# Scope
######################################################################################

# Enum all subscriptions
    AZ_Find_Subscriptions_in_Tenant

# Collection of information about hybrid computers in Azure (Azure Arc enabled)
    AZ_Find_All_Hybrid_VM_Resources    # $global:HybridVMsInScope_All

# Collection of information about native VM in Azure
    AZ_Find_All_Native_VM_Resources    # $Global:NativeVMsInScope_All


######################################################################
# Build extension status - to detect any failed extensions
######################################################################

# Build complete list of extension status
Build_Extension_Status
# $Global:Extension_Status_All_Computers_Array

# Detect succeeded extensions
$Ext_Status_Succeeded =  $Global:Extension_Status_All_Computers_Array | where-Object {($_.ExtprovisioningState -eq "Succeeded") -and ($_.Extname -eq $global:CustomScript_RunScriptName)}

# Detect failed extensions
$Ext_Status_Failed_CustomScripts =  $Global:Extension_Status_All_Computers_Array | where-Object {($_.ExtprovisioningState -eq "Failed") -and ($_.Extname -eq $global:CustomScript_RunScriptName)}

# Detect incomplete extensions in 'creating' status (must timeout, will fail)
$Ext_Status_Creating_CustomScripts =  $Global:Extension_Status_All_Computers_Array | where-Object {($_.ExtprovisioningState -eq "Creating") -and ($_.Extname -eq $global:CustomScript_RunScriptName)}

# Detect deleting extensions
$Ext_Status_Deleting_CustomScripts =  $Global:Extension_Status_All_Computers_Array | where-Object {($_.ExtprovisioningState -eq "Deleting") -and ($_.Extname -eq $global:CustomScript_RunScriptName)}

# Detect Transitioning extensions
$Ext_Status_Transitioning_CustomScripts =  $Global:Extension_Status_All_Computers_Array | where-Object {($_.ExtprovisioningState -eq "Transitioning") -and ($_.Extname -eq $global:CustomScript_RunScriptName)}

# Build extension issue list
    
$Issues_CustomScripts = @()
$Issues_CustomScripts += $Ext_Status_Failed_CustomScripts
$Issues_CustomScripts += $Ext_Status_Creating_CustomScripts
$Issues_CustomScripts += $Ext_Status_Deleting_CustomScripts
$Issues_CustomScripts += $Ext_Status_Transitioning_CustomScripts
$Issues_CustomScripts_List = $Issues_CustomScripts.name | Sort-Object -Unique

Write-Output "Servers with CustomScripts extension issues -> $($Issues_CustomScripts_List.count)"
Write-Output ""
Write-Output "Servers with CustomScripts extension issues:"
Write-Output $Issues_CustomScripts_List
Write-Output ""


################################################################################
# Remove 'Automation.CustomScripts in any issue state - local server clean-up
################################################################################

    $RemoveExtensions =  $Global:Extension_Status_All_Computers_Array | where-Object { ($_.Extname -eq $global:CustomScript_RunScriptName) -and ($_.ExtprovisioningState -ne 'Succeeded') }

    $RemoveExtensions.count
    $RemoveExtensions.name

    ForEach ($Srv in $RemoveExtensions)
        {
            Write-Output ""
            Write-Output "Processing $($Srv.name)"

            # Step 1 - Stopping Azure Arc extension service
            Write-Output ""
            Write-Output "  Stopping Azure Arc services on server $($Srv.name) ... Please Wait !"
            
            Try
                {
                    $Result = (Get-WmiObject Win32_Process -ComputerName $Srv.name -ErrorAction SilentlyContinue| ?{ $_.ProcessName -match "gc_service" }).Terminate()
                }
            Catch
                {
                }

            Start-Sleep -s 5

            $Result = Get-Service -ComputerName $Srv.name -Name GCArcService | Stop-Service -NoWait
            $Result = Get-Service -ComputerName $Srv.name -Name ExtensionService | Stop-Service -NoWait

            # Step 2 - Try to remove the CustomScriptExtension plug-in
            Write-Output ""
            Write-Output "  Deleting CustomScriptExtension folder on server $($Srv.name) ... Please Wait !"
            $Result = Remove-Item "\\$($Srv.Name)\C$\Packages\Plugins\Microsoft.Compute.CustomScriptExtension" -Recurse -force -Confirm:$false -ErrorAction SilentlyContinue

            # Step 3 - Verification folder is gone
            Try
                {
                    Write-Output ""
                    Write-Output "  Verifying removal of CustomScriptExtension folder on server $($Srv.name) ... Please Wait !"
                    $ChkFolder = Get-ChildItem "\\$($Srv.Name)\C$\Packages\Plugins\Microsoft.Compute.CustomScriptExtension" -ErrorAction SilentlyContinue
                }
            Catch
                {
                }

            If ($ChkFolder)
                {
                    # Terminating any running powershell sessions
                    Write-Output ""
                    Write-Output "  Terminating Powershell processes keeping open handles on server $($Srv.name) ... Please Wait !"
                    $Result = (Get-WmiObject Win32_Process -ComputerName $Srv.name -ErrorAction SilentlyContinue| ?{ $_.ProcessName -match "Powershell" }).Terminate()
                    
                    # Try to remove the CustomScriptExtension plug-in
                    Write-Output ""
                    Write-Output "  Deleting CustomScriptExtension folder on server $($Srv.name) ... Please Wait !"
                    $Result = Remove-Item "\\$($Srv.Name)\C$\Packages\Plugins\Microsoft.Compute.CustomScriptExtension" -Recurse -force -Confirm:$false -ErrorAction SilentlyContinue

                    Write-Output ""
                    Write-Output "Verifying removal of CustomScriptExtension folder on server $($Srv.name) ... Please Wait !"
                    $ChkFolder = Get-ChildItem "\\$($Srv.Name)\C$\Packages\Plugins\Microsoft.Compute.CustomScriptExtension" -ErrorAction SilentlyContinue
                }


            # Restarting service again
            If ($ChkFolder -eq $null) # not exist
                {
                    Write-Output ""
                    Write-Output "  Starting Azure Arc services on server $($Srv.name) ... Please Wait !"

                    $Result = Get-Service -ComputerName $Srv.name -Name GCArcService | Start-Service
                    $Result = Get-Service -ComputerName $Srv.name -Name ExtensionService | Start-Service
                }
        }


################################################################################
# Remove 'Automation.CustomScripts in any issue state - Azure removal
################################################################################

    ForEach ($Server in $RemoveExtensions)
        {
            If ($server.type -eq "microsoft.hybridcompute/machines")
                {
                    $Context = Get-AzContext
                    If ($Context.subscriptionId -ne $Server.subscriptionId)
                        {
                            $SetContext = Set-AzContext -Subscription $Server.subscriptionId
                        }

                    Write-Output "Removing extension $($Server.ExtName) from VMName -> $($Server.Name)"
                    $Result = Remove-AzConnectedMachineExtension -ResourceGroupName $Server.resourceGroup`
                        -MachineName $Server.name `
                        -Name $Server.ExtName `
                        -Confirm:$false `
                        -AsJob
                }
            Else
                {
                    $Context = Get-AzContext
                    If ($Context.subscriptionId -ne $Server.subscriptionId)
                        {
                            $SetContext = Set-AzContext -Subscription $Server.subscriptionId
                        }

                    Write-Output "Removing extension $($Server.ExtName) from VMName -> $($Server.Name)"
                    $Result = Remove-AzVMExtension -ResourceGroupName $Server.resourceGroup `
                        -VMName $Server.name `
                        -Name $Server.ExtName `
                        -Force `
                        -AsJob
                }
        }

