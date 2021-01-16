#requirements
#1)An Azure Storage Account on your subsciption like "azautomationacct"
#2)This is runbook code for your Azure Automation account so you'll need to have an Automation Account setup to execute this powershell runbook
####PLEASE CHECK THE STORAGE REGION FOR DETAILS like storage account name, account key, sas token etc
#3)The modules below are imported into your automation account & accessible by your runbook (Az.Accounts & Az.Websites)
#4)$connectionName is an account on your Azure Subscription that has access to work with the 
#5)$arrayOfRegions contains all of the regions you want this script to be ran against (where to look for app service plans and sites)
#6) -Container "scaleappserviceplans" is a blob that exists on your storage account. You can name it whatever but update that name here

####################################################################################################################################
#region Module Import & Setup Connection
####################################################################################################################################
#in order to use az modules need to import them here
#doing this because azurerm is going end of life and moving to az
Import-Module Az.Accounts
Import-Module Az.Websites

#the account/service principal used to do the work on your azure subscription
$connectionName = "AzureRunAsConnection"

try
{
    # Get the connection "AzureRunAsConnection "
    $servicePrincipalConnection=Get-AutomationConnection -Name $connectionName         

    "Logging in to Azure..."
    Connect-AzAccount `
        -ServicePrincipal `
        -TenantId $servicePrincipalConnection.TenantId `
        -ApplicationId $servicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint
    Write-Output "TenantId = " $servicePrincipalConnection.TenantId
    Write-Output "ApplicationId = " $servicePrincipalConnection.ApplicationId
}
catch {
    if (!$servicePrincipalConnection)
    {
        $ErrorMessage = "Connection $connectionName not found."
        throw $ErrorMessage
    } else{
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
}
#endregion
####################################################################################################################################

############################################################################################################
#region STORAGE/TABLE STUFFS & Logging Setup

Write-Output "Setting up our logfile"
$dateTime = get-date -Format MMddyyyy
$LogFile = "InsertAppServicePlansIntoTable$dateTime.log"

#storageaccountstuffs
$storageaccountname = "azautomationacct"
$storageaccountresourcegroup = "Automation"
#acctKey is so we can write to a logfile
$acctKey = Get-AzStorageAccountKey -Name $storageaccountname -ResourceGroupName $storageaccountresourcegroup
$logStorageContext = New-AzStorageContext -StorageAccountName $storageaccountname -StorageAccountKey $acctKey[0].value
#sasToken is for the storageacct
$sasToken = 'YOUR SAS TOKEN GOES HERE'
#create storage context for this storage account using this sasToken
$storageContext = New-AzStorageContext -StorageAccountName $storageAccountName -SasToken $sasToken
#create a tableName using the date so we can run this multiple times/create multiple tables at that point in time
$appServicePlanTableName = 'AppServicePlans' + $dateTime
$siteTableName = 'Sites' + $dateTime
#create new tables, one for each
New-AzStorageTable -Name $appServicePlanTableName -Context $storageContext
New-AzStorageTable -Name $siteTableName -Context $storageContext
#get the table objects so we can do operations on it
$appServicePlanTableObj = Get-AzStorageTable -Name $appServicePlanTableName -Context $storageContext
$siteTableObj = Get-AzStorageTable -Name $siteTableName -Context $storageContext

#endregion STORAGE/TABLE STUFFS
############################################################################################################

function CreateAppServicePlansANDSiteTables {

    Write-Output "--------------------------------------------------------------------"
    Write-Output "get ALL App Service Plans in this region: $searchThisRegion"
    Write-Output "--------------------------------------------------------------------"
    $arrayOfRegions = @('East US 2', 'East US', 'Central US', 'North Central US')
    foreach ($region in $arrayOfRegions){
        $appServicePlans += Get-AzAppServicePlan -Location $region
    }

    foreach ($appServicePlan in $appServicePlans){
        $tempname = $appServicePlan.Name
        Write-Output "show the name of the appserviceplan we are working with = $tempname"
        #if appServicePlan.NumberOfSites -eq 1 then get the sitename. add the appserviceplan with the sitename1 filled out
        if($appServicePlan.NumberOfSites -eq 1){
            Write-Output "--------------------------------------------------------------------"
            Write-Output "Found only 1 site on appservice plan: $tempname"
            Write-Output "Get the WebApp object using this AppServicePlan object"
            $resources = Get-AzWebApp -AppServicePlan $appServicePlan
            Write-Output "Add all this app service plan info + the site name to our AppServices table"
            Add-AzTableRow -table $appServicePlanTableObj.CloudTable -partitionKey $appServicePlan.Name -rowKey ([guid]::NewGuid().tostring()) -property @{
                'ResourceGroup' = $appServicePlan.ResourceGroup
                'SiteName' = $resources.Name
                'SkuName' = $appServicePlan.Sku.Name
                'SkuTier' = $appServicePlan.Sku.Tier
                'SkuSize' = $appServicePlan.Sku.Size
                'SkuFamily' = $appServicePlan.Sku.Family
                'SkuCapacity' = $appServicePlan.Sku.Capacity
            } | Out-Null
            Write-Output "--------------------------------------------------------------------"

            #####################################################################################################
            #now that the appserviceplan table info looks correct lets also use the info to create our site table
            ##get the webapp object from our list
            Write-Output "Now get the site detail by running Get-AzWebApp again against the resource.name we got from above"
            $webAppObj = Get-AzWebApp -name $resources.name
            Write-Output "Add all this site + alwaysOn info to our sites table"
            Add-AzTableRow -table $siteTableObj.CloudTable -partitionKey $webAppObj.Name -rowKey ([guid]::NewGuid().tostring()) -property @{
               'ResourceGroup' = $appServicePlan.ResourceGroup
               "AlwaysOn" = $webAppObj.SiteConfig.AlwaysOn
            } | Out-Null
            Write-Output "--------------------------------------------------------------------"

        #endif
        }

        #else the appServicePlan.NumberOfSites > 1 so figure out how many site names and site always on details we need to add
        else{
            Write-Output "--------------------------------------------------------------------"
            $numOfSites = $appServicePlan.NumberOfSites
            Write-Output "Found $numOfSites sites on this appservice plan: $tempname"
            Write-Output "Get each WebApp object using this AppServicePlan object"
            $resources = Get-AzWebApp -AppServicePlan $appServicePlan
            $counter = 0
            #while our counter is less than our number of sites, use the counter to get the correct resource array position and get the name for it
            while ($counter -lt $numOfSites){
                Write-Output "Add all this app service plan info + the site name to our AppServices table"
                Write-Output "counter = $counter"
                Add-AzTableRow -table $appServicePlanTableObj.CloudTable -partitionKey $appServicePlan.Name -rowKey ([guid]::NewGuid().tostring()) -property @{
                    'ResourceGroup' = $appServicePlan.ResourceGroup
                    'SiteName' = $resources[$counter].Name
                    'SkuName' = $appServicePlan.Sku.Name
                    'SkuTier' = $appServicePlan.Sku.Tier
                    'SkuSize' = $appServicePlan.Sku.Size
                    'SkuFamily' = $appServicePlan.Sku.Family
                    'SkuCapacity' = $appServicePlan.Sku.Capacity
                } | Out-Null

                #####################################################################################################
                #now that the appserviceplan table info looks correct lets also use the info to create our site table
                ##get the webapp object from our list
                Write-Output "Now get the site detail by running Get-AzWebApp again against the resource.name we got from above"
                $webAppObj = Get-AzWebApp -name $resources[$counter].name
                Write-Output "Add all this site + alwaysOn info to our sites table"
                Add-AzTableRow -table $siteTableObj.CloudTable -partitionKey $webAppObj.Name -rowKey ([guid]::NewGuid().tostring()) -property @{
                'ResourceGroup' = $appServicePlan.ResourceGroup
                "AlwaysOn" = $webAppObj.SiteConfig.AlwaysOn
                } | Out-Null

                #increment counter
                $counter++
            }
            Write-Output "Done looping thru objects on $tempname"
            Write-Output "--------------------------------------------------------------------"
        }
    }

#endfunction
}

Write-Output "Write our output from function/runbook run to LogFile"

#run the function & write the output to logfile
CreateAppServicePlansANDSiteTables > ./$logFile 

Write-Output "done writing LogFile"

#Copy the logfile to the storage account/blob
Set-AzStorageBlobContent -File $LogFile -Container "scaleappserviceplans" -BlobType "Block" -Context $logStorageContext -Verbose -Force
