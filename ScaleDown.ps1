#requirements
#1)An Azure Storage Account on your subsciption like "azautomationacct"
#2)This is runbook code for your Azure Automation account so you'll need to have an Automation Account setup to execute this powershell runbook
####PLEASE CHECK THE STORAGE REGION FOR DETAILS like storage account name, account key, sas token etc
#3)The modules below are imported into your automation account & accessible by your runbook (Az.Accounts & Az.Websites)
#4)$connectionName is an account on your Azure Subscription that has access to work with the 
#5)$appServicePlanTableName & $sitesTableName are defined at the top in REQUIRE INPUT
#6) -Container "scaleappserviceplans" is a blob that exists on your storage account. You can name it whatever but update that name here
#7)THE FUNCTION IS CALLED AT THE BOTTOM
#8) $sasToken value is unique to you/your storage account so that will need replaced


################
#REQUIRED INPUT
################
#What Azure Table do you want this to look at?
################
#create a tableName using the date so we can run this multiple times/create multiple tables at that point in time
#####$appServicePlanTableName = 'AppServicePlans' + $dateTime
$appServicePlanTableName = 'AppServicePlans01132021'
#####$siteTableName = 'Sites' + $dateTime
$siteTableName = 'Sites01132021'


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
$LogFile = "ScaleDown$dateTime.log"

#storageaccountstuffs
$storageAccountName = "azautomationacct"
$storageAccountResourceGroup = "Automation"
#acctKey is so we can write to a logfile
Write-Output "getting storage account key on: $storageAccountName"
$acctKey = Get-AzStorageAccountKey -Name $storageAccountName -ResourceGroupName $storageAccountResourceGroup -ErrorVariable ev1 -ErrorAction SilentlyContinue
$temp1 = $acctKey.Count
$temp2 = $acctKey[0].value
Write-Output "show us a properties of storage account key - Count: $temp1 | Value: $temp2"
if ($ev1) {
    Write-Output "Get-AzStorageAccountKey errored out. Check your appServicePlanTableName or run the CreateTable runbook. Exiting this runbook"
    Exit
}
else {
    $temp = $acctKey.Count
    Write-Output "Get-AzStorageAccountKey succeeded. Here is count property: $temp"
}
Write-Output "use storage account key to create logStorageContext."
$logStorageContext = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $acctKey[0].value
$temp = $logStorageContext.BlobEndPoint
Write-Output "show us a property of logstoragecontext: $temp"
#sasToken is for the storageacct
$sasToken = 'YOUR SAS TOKEN GOES HERE'
#create storage context for this storage account using this sasToken
Write-Output "use sasToken to create storageContext."
$storageContext = New-AzStorageContext -StorageAccountName $storageAccountName -SasToken $sasToken
$temp = $storageContext.BlobEndPoint
Write-Output "show us a property of storagecontext: $temp"

#Check if Tables already exist. If Get-AzStorageTable finds nothing it throws and error so $ev would be true. 
##If $ev = true then stop everything and tell the user what to do
Write-Output "running checks to see if Azure Tables exist"
$appServicePlanTableObj = Get-AzStorageTable -Name $appServicePlanTableName -Context $storageContext -ErrorVariable ev2 -ErrorAction SilentlyContinue
$temp = $appServicePlanTableObj.Uri.AbsoluteUri
Write-Output "show us a property of appServicePlanTableObj: $temp"
if ($ev2) {
    Write-Output "Get-AzStorageTable errored out. Check your appServicePlanTableName or run the CreateTable runbook. Exiting this runbook"
    Exit
}
else {
    $temp = $appServicePlanTableObj.Name
    Write-Output "Get-AzStorageTable succeeded. Here is name property: $temp"
}
$siteTableObj = Get-AzStorageTable -Name $siteTableName -Context $storageContext -ErrorVariable ev3 -ErrorAction SilentlyContinue
$temp = $siteTableObj.Uri.AbsoluteUri
Write-Output "show us a property of appServicePlanTableObj: $temp"
if ($ev3) {
    Write-Output "Get-AzStorageTable errored out. Check your siteTableName or run the CreateTable runbook. Exiting this runbook"
    Exit
}
else {
    $temp = $siteTableObj.Name
    Write-Output "Get-AzStorageTable succeeded. Here is name property: $temp"
}
Write-Output "done running the get-azstoragetable commands. Show us something within them"
$temp1 = $appServicePlanTableObj.Uri.AbsoluteUri
$temp2 = $siteTableObj.Uri.AbsoluteUri
Write-Output "appService: $temp1 | site: $temp2"
Write-Output "if the tables are found the rest of the log will be found in the azure storage account blob"
#New-AzStorageTable -Name $appServicePlanTableName -Context $storageContext
#New-AzStorageTable -Name $siteTableName -Context $storageContext
#get the table objects so we can do operations on it
#$appServicePlanTableObj = Get-AzStorageTable -Name $appServicePlanTableName -Context $storageContext
#$siteTableObj = Get-AzStorageTable -Name $siteTableName -Context $storageContext

#endregion STORAGE/TABLE STUFFS
############################################################################################################

#1 get the appservice plan & associated sites
#2 check if any of the sites has alwaysOn enabled
#3 if it does run an update to flip alwaysOn to false
#4 run scale down against app service plan
function ScaleDown {
    param
    (
         [Parameter(Mandatory=$true, Position=0)]
         [string] $appServicePlanToLookFor
    )
    $appServicePlanFilter = "PartitionKey eq '" + $appServicePlanToLookFor + "'"
    #$appServicePlanFilter = "PartitionKey eq 'mypullrequest-012-myapp-webFarm'"
    #$appServicePlanFilter = "PartitionKey eq 'qa-coolApp-queueFarm'"

    Write-Output "--------------------------------------------------------------------"
    Write-Output "getting rows on the appServicePlanTableObj using this filter: $appServicePlanFilter"
    $getAppServicePlanTableRows = Get-AzTableRow -Table $appServicePlanTableObj.CloudTable -CustomFilter $appServicePlanFilter
    $temp1 = $getAppServicePlanTableRows.PartitionKey
    $temp2 = $getAppServicePlanTableRows.Count
    Write-Output "show us some properties of appServicePlanTableObj - Name: $temp1 | Count: $temp2"

    #this stopped working for some reason so switching to -lt 2
    #if rows.Count = 1 then we already know all the sites associated with that appserviceplan and we can check for always on
    #if rows.Count is null or 1 (-lt 2) then we dont need to iterate thru a buncha rows/objects
    if ($getAppServicePlanTableRows.Count -lt 2){
        $tempname = $getAppServicePlanTableRows.SiteName
        Write-Output "--------------------------------------------------------------------"
        Write-Output "row count equals one so we can immdiately look for alwaysOn value"
        Write-Output "getting the alwaysOn value for site: $tempname"
        Write-Output "--------------------------------------------------------------------"
        $sitesFilter = "PartitionKey eq '$tempname'"
        $getSitesTableRows = Get-AzTableRow -Table $siteTableObj.CloudTable -CustomFilter $sitesFilter

        #if alwayson is true flip alwaysOn to false first before running scale down command
        if($getSitesTableRows.AlwaysOn -eq $true){
            Write-Output "alwaysOn value we found equals true so we need to flip that value off first before scale down"
            Write-Output "--------------------------------------------------------------------"
            #get the webapp obj so we can set the value we want
            Write-Output "getting the webapp object"
            $webAppObj = Get-AzWebApp -name $getSitesTableRows.PartitionKey
            #set the value
            Write-Output "setting the alwaysOn value"
            $webAppObj.SiteConfig.AlwaysOn = $false
            $webAppObj | Set-AzWebApp
            #now run the scaledown command
            Write-Output "--------------------------------------------------------------------"
            Write-Output "now finally run the scale down command"
            Write-Output "--------------------------------------------------------------------"
            Set-AzAppServicePlan -Name $getAppServicePlanTableRows.PartitionKey -ResourceGroupName $getAppServicePlanTableRows.ResourceGroup -Tier Free -WorkerSize Small
            Write-Output "--------------------------------------------------------------------"
            Write-Output "done running the scaledown command"
            Write-Output "--------------------------------------------------------------------"
        }

        #else alwayson is false so just run scaledown command against this appserviceplan
        else{
            Write-Output "alwaysOn value we found is not true so just run the scaledown command"
            Write-Output "--------------------------------------------------------------------"
            Set-AzAppServicePlan -Name $getAppServicePlanTableRows.PartitionKey -ResourceGroupName $getAppServicePlanTableRows.ResourceGroup -Tier Free -WorkerSize Small
            Write-Output "--------------------------------------------------------------------"
            Write-Output "done running the scaledown command"
            Write-Output "--------------------------------------------------------------------"
        }
    }

    #if rows > 1 then we need to get all the sites and check for any AlwaysOn values
    ##if the value is true then we need to flip it to off
    elseif ($getAppServicePlanTableRows.Count -gt 1){
        #for each row in getAppServicePlanTableRows, get the site names and flip the alwaysOn values to false
        foreach($row in $getAppServicePlanTableRows){
            $tempname = $row.SiteName
            Write-Output "--------------------------------------------------------------------"
            Write-Output "elseif row count greater than one so we need to iterate thru sites and look for alwaysOn value"
            Write-Output "row we are working on has a sitename of: $tempname"
            $sitesFilter = "PartitionKey eq '$tempname'"
            Write-Output "getting the alwaysOn value for site: $tempname"
            Write-Output "--------------------------------------------------------------------"
            $getSitesTableRows = Get-AzTableRow -Table $siteTableObj.CloudTable -CustomFilter $sitesFilter

            #if alwayson is true flip alwaysOn to false first before running scale down command
            if($getSitesTableRows.AlwaysOn -eq $true){
                Write-Output "alwaysOn value we found equals true so we need to flip that value off first before scale down"
                Write-Output "--------------------------------------------------------------------"
                #get the webapp obj so we can set the value we want
                Write-Output "getting the webapp object"
                Write-Output "--------------------------------------------------------------------"
                $webAppObj = Get-AzWebApp -name $getSitesTableRows.PartitionKey
                #set the value
                Write-Output "setting the alwaysOn value"
                $webAppObj.SiteConfig.AlwaysOn = $false
                $webAppObj | Set-AzWebApp
                Write-Output "--------------------------------------------------------------------"
                Write-Output "done setting AlwaysOn for $tempname"
                Write-Output "--------------------------------------------------------------------"
            }
            #else alwaysOn not found for the siteName coming off of this row
            else{
                Write-Output "no alwaysOn value found for this row's sitename: $tempname"
                Write-Output "--------------------------------------------------------------------"
            }
        }
        #now that we've run the logic to find all alwaysOn's for this appServicePlan & associated sites, we can run the scale down
        Write-Output "--------------------------------------------------------------------"
        Write-Output "now finally run the scale down command"
        Set-AzAppServicePlan -Name $getAppServicePlanTableRows.PartitionKey -ResourceGroupName $getAppServicePlanTableRows.ResourceGroup -Tier Free -WorkerSize Small
        Write-Output "--------------------------------------------------------------------"
        Write-Output "done running the scaledown command"
        Write-Output "--------------------------------------------------------------------"
    }

    #with the change at the top to -lt 2 I'm not sure how we would ever hit this but leaving it just in case
    ###else the row count must be 0 in which case we need to do nothing i guess?
    else{
        $temp = $getAppServicePlanTableRows.SiteName
        Write-Output "--------------------------------------------------------------------"
        Write-Output "if row count is not 1 or -gt 1 it must be 0 so do nothing i guess?"
        Write-Output "was there anything in getAppServicePlanTableRows: $temp"
        Write-Output "--------------------------------------------------------------------"
    }
#endfunction
}

Write-Output "Write our output from function/runbook run to LogFile"

#run the function & write the output to logfile
ScaleDown 'mypullrequest-012-myapp-webFarm' > ./$logFile
#ScaleDown 'qa-coolApp-queueFarm' > ./$logFile

Write-Output "done writing LogFile"

#Copy the logfile to the storage account/blob
Set-AzStorageBlobContent -File $logFile -Container "scaleappserviceplans" -BlobType "Block" -Context $logStorageContext -Verbose -Force
