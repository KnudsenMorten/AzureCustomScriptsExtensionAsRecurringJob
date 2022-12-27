#Requires -Version 5.0
<#
    .SYNOPSIS
    This script will export existing Data Collection Rules (DCR) from existing DCR in Azure Monitor
    This script will also update / upload file with changes (TransformKql added)

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

<#
    For demonstration purpose information, access key is provided in script, but please remember to store in Keyvault for production
    Storage account name + Storage Access key will be encrypted by Azure, when custom script is run on the VMs
#>
# Script Repository
$global:CustomScript_StorageAcctName                            = "xxxxx"
$global:CustomScript_StorageKey                                 = "xxxxxxx"
$global:CustomScript_StorageConnectString                       = "DefaultEndpointsProtocol=https;AccountName=xxxxxx;AccountKey=xxxxxx;EndpointSuffix=core.windows.net"
$global:CustomScript_StorageContainer                           = "azcustomscriptsextension"
$global:CustomScript_RunScriptName                              = "Automation.CustomScripts"
$global:CustomScript_SourcePathRepo                             = "\\xxxxx\scripts\AzCustomScriptsExtensionRepo"

# Custom Script: ServerInspector
$global:CustomScript_ServerInspector_ScriptFileName             = "ServerInspector.ps1"

# Automation
$global:CustomScript_FileUri                                    = @("https://$($global:CustomScript_StorageAcctName).blob.core.windows.net/$($global:CustomScript_StorageContainer)/$($global:CustomScript_ServerInspector_ScriptFileName)")
$global:CustomScript_Cmd                                        = "powershell -ExecutionPolicy Unrestricted -File $($global:CustomScript_ServerInspector_ScriptFileName)"

# Storage account (protected settings, encrypted during deployment)
$ProtectedSettings = @{"storageAccountName" = $global:CustomScript_StorageAcctName; "storageAccountKey" = $global:CustomScript_StorageKey; "commandToExecute" = $global:CustomScript_Cmd };


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
# Upload newest edition of script(s) to storage account 
######################################################################

Write-Output "Updating file to Azure Storage Account ... Please Wait !"

$context = New-AzStorageContext -ConnectionString $global:CustomScript_StorageConnectString

$Create = New-AzStorageContainer -Name $global:CustomScript_StorageContainer -Context $Context -ErrorAction SilentlyContinue

# upload a file to the default account (inferred) access tier
$Uploadfile = @{
    File             = "$($global:CustomScript_SourcePathRepo)\$($global:CustomScript_ServerInspector_ScriptFileName)"
    Container        = $global:CustomScript_StorageContainer
    Blob             = $global:CustomScript_ServerInspector_ScriptFileName
    Context          = $Context
    StandardBlobTier = 'Hot'
}
Set-AzStorageBlobContent @UploadFile -Force


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


######################################################################
# Starting custom script jobs on Hybrid Azure Arc machines
######################################################################

$Scope_HybridAz = $Global:HybridVMsInScope_All | Where-Object { ($_.osType -eq "Windows") -and ($_.osSku -notlike "*2008 R2*") -and ($_.osSku -notlike "*Windows 10*") -and ($_.name -notin $Issues_CustomScripts_List) }

ForEach ($Server in $Scope_HybridAz)
    {
        $ReRunTime = (Get-date -format "yyyy-MM-dd_HH:mm:ss")
        If ($server.type -eq "microsoft.hybridcompute/machines")
            {
                $Context = Get-AzContext
                If ($Context.subscriptionId -ne $Server.subscriptionId)
                    {
                        $SetContext = Set-AzContext -Subscription $Server.subscriptionId
                    }

                Write-Output ""
                Write-Output "Hybrid AzArc: Starting script $($global:CustomScript_RunScriptName) on server as job -> $($Server.name)"

                # Adding lastrun to settings, causing job to re-run as  it is changed !
                $Settings          = @{"fileUris" = $global:CustomScript_FileUri; "lastrun" = $ReRunTime};

                $result = Set-AzConnectedMachineExtension -ResourceGroupName $Server.resourceGroup`
                    -Location $Server.location `
                    -MachineName $Server.name `
                    -Name $global:CustomScript_RunScriptName `
                    -Publisher "Microsoft.Compute" `
                    -ExtensionType "CustomScriptExtension" `
                    -Settings $Settings `
                    -ProtectedSettings $ProtectedSettings `
                    -ForceRerun $ReRunTime `
                    -AsJob
            }
    }


######################################################################
# Starting custom script jobs on native VMs
######################################################################

$Scope_NativeAz = $Global:NativeVMsInScope_All | Where-Object { ($_.osType -eq "Windows") -and ($_.osName -notlike "*2008 R2*") -and ($_.osName -notlike "*Windows 10*") -and ($_.name -notin $Issues_CustomScripts_List) }

ForEach ($Server in $Scope_NativeAz)
    {
    $ReRunTime = (Get-date -format "yyyy-MM-dd_HH:mm:ss")
        If ($Server.type -eq "microsoft.compute/virtualmachines")
            {
                $Context = Get-AzContext
                If ($Context.subscriptionId -ne $Server.subscriptionId)
                    {
                        $SetContext = Set-AzContext -Subscription $Server.subscriptionId
                    }

                # Adding lastrun to settings, causing job to re-run as  it is changed !
                $Settings          = @{"fileUris" = $global:CustomScript_FileUri; "lastrun" = $ReRunTime};

                Write-Output ""
                Write-Output "Native Az: Starting script $($global:CustomScript_RunScriptName) on VM as job -> $($Server.Name)"
                $Result = Set-AzVMExtension -ResourceGroupName $Server.resourceGroup`
                    -Location $Server.location `
                    -VMName $Server.name `
                    -Name $global:CustomScript_RunScriptName `
                    -Publisher "Microsoft.Compute" `
                    -ExtensionType "CustomScriptExtension" `
                    -TypeHandlerVersion "1.10" `
                    -Settings $Settings `
                    -ProtectedSettings $ProtectedSettings `
                    -AsJob `
                    -ForceRerun $ReRunTime
            }
    }

