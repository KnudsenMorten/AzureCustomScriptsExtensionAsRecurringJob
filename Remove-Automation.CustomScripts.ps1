#------------------------------------------------------------------------------------------------
Write-Output "***********************************************************************************************"
Write-Output "Remove failed Automation.CustomScripts"
Write-Output ""
Write-Output "Purpose: This script removes any failed Automation.CustomScripts"
Write-Output ""
Write-Output "Support: Morten Knudsen - mok@2linkit.net | 40 178 179"
Write-Output "***********************************************************************************************"
#------------------------------------------------------------------------------------------------


#------------------------------------------------------------------------------------------------------------
# Loading Functions, Connectivity & Default variables
#------------------------------------------------------------------------------------------------------------
    $ScriptDirectory = $PSScriptRoot
    $global:PathScripts = Split-Path -parent $ScriptDirectory
    Write-Output ""
    Write-Output "Script Directory -> $($global:PathScripts)"

    # Loading function modules (2LINKIT)
    Import-Module "$($global:PathScripts)\FUNCTIONS\2LINKIT-Functions.psm1" -Global -force  -WarningAction SilentlyContinue

    # Loading automation prerequsites
    Import-Module "$($global:PathScripts)\FUNCTIONS\Automation-Powershell-WindowsFeatures-PreReq.psm1" -Global -force -WarningAction SilentlyContinue
    LoadModules

    Import-Module "$($global:PathScripts)\FUNCTIONS\Automation-ConnectDetails.psm1" -Global -force -WarningAction SilentlyContinue
    ConnectDetails
    
    Import-Module "$($global:PathScripts)\FUNCTIONS\Automation-DefaultVariables.psm1" -Global -force -WarningAction SilentlyContinue
    Default_Variables

    # Connecting using modern authentication
    & "$($global:PathScripts)\FUNCTIONS\Connect_Azure.ps1"


######################################################################################
##    MAIN PROGRAM
######################################################################################

$Global:DebugModeOn = $false

# Enum all subscriptions
    AZ_Find_Subscriptions_in_Tenant

# Collection of information about hybrid computers in Azure (Azure Arc enabled)
    AZ_Find_All_Hybrid_VM_Resources    # $HybridVMsInScope_All

# Collection of information about native VM in Azure
    AZ_Find_All_Native_VM_Resources    # $Global:NativeVMsInScope_All



######################################################################
# Build extension status
######################################################################

    # Build complete list of extension status
    Build_Extension_Status
    # $Global:Extension_Status_All_Computers_Array


################################################################################
# Remove 'Automation.CustomScripts in any issue state - local server clean-up
################################################################################

    $RemoveExtensions =  $Global:Extension_Status_All_Computers_Array | where-Object { ($_.Extname -eq 'Automation.CustomScripts') -and ($_.ExtprovisioningState -ne 'Succeeded') }

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

