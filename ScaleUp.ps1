#requirements
#1)An Azure Storage Account on your subsciption like "azautomationacct"
#2)This is runbook code for your Azure Automation account so you'll need to have an Automation Account setup to execute this powershell runbook
####PLEASE CHECK THE STORAGE REGION FOR DETAILS like storage account name, account key, sas token etc
#3)The modules below are imported into your automation account & accessible by your runbook (Az.Accounts & Az.Websites)
#4)$connectionName is an account on your Azure Subscription that has access to work with the 
#5)$appServicePlanTableName & $sitesTableName are defined at the top in REQUIRE INPUT
#6) -Container "scaleappserviceplans" is a blob that exists on your storage account. You can name it whatever but update that name here
#7)THE FUNCTION IS CALLED AT THE BOTTOM
#8) the function AppServicePlanScaleUp only working against Pv2 and S1, S2 etc currently. 
#9) $sasToken value is unique to you/your storage account so that will need replaced

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
$LogFile = "ScaleUp$dateTime.log"

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

#########################################################################################################################
#region AppServicePlanScaleUp
#########################################################################################################################

#########################################################################################################################
#READ ME - this is important to know to use this correctly
#########################################################################################################################
#this is the order they appear in the blob
##appserviceplan - name, resourcegroupname, sku.name, sku.tier, sku.size, sku.family, sku.capacity
################
#set-azappserviceplan params:
###-Tier maps to sku.tier
###-NumberofWorkers maps to sku.capacity
###-WorkerSize does not map directly to anything and is instead:
#######P1v2 = -WorkerSize "Small" | P2v2 = -WorkerSize "Medium" | P3v2 = -WorkerSize "Large"
#######Standard S1:1 = -WorkerSize "Small" -NumberofWorkers 1
################

#skutier values i've seen at VPL thus far
#most common == "Standard" ,  "PremiumV2"
#less common == "Dynamic",  "ElasticPremium", "Basic"

#####################
#some examples ive tested that work
#p2v2
##AppServicePlanScaleUp $testresourcegroup $testappserviceplan "PremiumV2" "3" "Medium"
#s1:1
##AppServicePlanScaleUp $testresourcegroup $testappserviceplan "Standard" "1" "Small"
#####################

#since i can only get those 2 working - this function is written for those 2 only currently
function AppServicePlanScaleUp{
    param
    (
         [Parameter(Mandatory=$true, Position=0)]
         [string] $ResourceGroupName,
         [Parameter(Mandatory=$true, Position=1)]
         [string] $AppServicePlanName,
         [Parameter(Mandatory=$true, Position=2)]
         [ValidateSet('PremiumV2','Standard','ElasticPremium','Dynamic')]
         [string] $AppServicePlanSkuTier,
         [Parameter(Mandatory=$true, Position=3)]
         [string] $AppServicePlanSkuCapacity,
         [Parameter(Mandatory=$true, Position=4)]
         [ValidateSet('S1','S2','S3','P1v2','P2v2','P3v2','Y1','EP1')]
         [string] $AppServicePlanSkuName
         
    )
    #############################################################################################
    #region best guess on workersize mapping to skuname
    #############################################################################################
    ###-WorkerSize does not map directly to anything and is instead:
    #######P1v2 = -WorkerSize "Small" | P2v2 = -WorkerSize "Medium" | P3v2 = -WorkerSize "Large"
    #SkuName -eq P1v2 - WorkerSize = Small
    #SkuName -eq P2v2 - WorkerSize = Medium
    #SkuName -eq P3v2 - WorkerSize = Large
    ########
    #SkuName -eq S1 - WorkerSize = Small ????
    #SkuName -eq S2 - WorkerSize = Medium ????
    #SkuName -eq S3 - WorkerSize = Large ????
    #############################################################################################
    #endregion best guess on workersize mapping to skuname
    #############################################################################################
    
    #if P1 or S1 then Workersize = Small
    if($appServicePlanSkuName -eq 'P1v2' -OR $appServicePlanSkuName -eq 'S1'){
        $AppServicePlanWorkerSize = 'Small'
    }
    #if P2 or S2 then Workersize = Medium
    if($appServicePlanSkuName -eq 'P2v2' -OR $appServicePlanSkuName -eq 'S2'){
        $AppServicePlanWorkerSize = 'Medium'
    }
    #if P3 or S3 then Workersize = Large
    if($appServicePlanSkuName -eq 'P3v2' -OR $appServicePlanSkuName -eq 'S3'){
        $AppServicePlanWorkerSize = 'Large'
    }

    #if sku = p2v2 then run this command, which is unique to p2v2 and not just a couple diff parameters
    If($AppServicePlanSkuTier -eq "PremiumV2"){
        Set-AzAppServicePlan -Name $appServicePlanName -ResourceGroupName $resourceGroupName -Tier "PremiumV2"  -NumberofWorkers $AppServicePlanSkuCapacity -WorkerSize $AppServicePlanWorkerSize
    }

    If($AppServicePlanSkuTier -eq "Standard"){
        Set-AzAppServicePlan -Name $appServicePlanName -ResourceGroupName $resourceGroupName -Tier "Standard"  -NumberofWorkers $AppServicePlanSkuCapacity -WorkerSize $AppServicePlanWorkerSize
    }

    # If($AppServicePlanSkuTier -eq "Dynamic"){
    #     Set-AzAppServicePlan -Name $appServicePlanName -ResourceGroupName $resourceGroupName -Tier "Dynamic"  -NumberofWorkers $AppServicePlanSkuCapacity -WorkerSize $AppServicePlanWorkerSize
    # }

    # If($AppServicePlanSkuTier -eq "ElasticPremium"){
    #     Set-AzAppServicePlan -Name $appServicePlanName -ResourceGroupName $resourceGroupName -Tier "PremiumV2"  -NumberofWorkers 1 -WorkerSize "Medium"
    # }

    # If($AppServicePlanSkuTier -eq "Basic"){
    #     Set-AzAppServicePlan -Name $appServicePlanName -ResourceGroupName $resourceGroupName -Tier "PremiumV2"  -NumberofWorkers 1 -WorkerSize "Medium"
    # }

}

#endregion
#########################################################################################################################


#1 based on appservice plan name
#2 get the sku that was previously used
#3 run the AppServicePlanScaleUp function/commands first before you set AlwaysOn (not able to set alwaysOn with Free tier)
#4 get the sites that previously had alwaysOn
#5 set alwaysOn = $true for those sites only
function ScaleUp {
    param
    (
         [Parameter(Mandatory=$true, Position=0)]
         [string] $appServicePlanToLookFor
    )
    $appServicePlanFilter = "PartitionKey eq '" + $appServicePlanToLookFor + "'"
    Write-Output "--------------------------------------------------------------------"
    Write-Output "getting rows on the appServicePlanTableObj using this filter: $appServicePlanFilter"
    $getAppServicePlanTableRows = Get-AzTableRow -Table $appServicePlanTableObj.CloudTable -CustomFilter $appServicePlanFilter
    $temp1 = $getAppServicePlanTableRows.PartitionKey
    $temp2 = $getAppServicePlanTableRows.Count
    Write-Output "show us some properties of appServicePlanTableObj - Name: $temp1 | Count: $temp2"
    Write-Output "did get-tablerow come back empty? if so kick into exit-if loop"
    #if the get-tablerow command keeps coming up empty we have to keep this check. i dont know why its empty but if it is we gotta exit the script
    if($null -eq $getAppServicePlanTableRows){
        Write-Output "our get rows came back empty so write to log then exit"
        Set-AzStorageBlobContent -File $logFile -Container "scaledownappserviceplans" -BlobType "Block" -Context $logStorageContext -Verbose -Force
        Exit
    }

    #this stopped working for some reason so switching to -lt 2
    #if rows.Count = 1 then we already know all the sites associated with that appserviceplan and we can check for always on
    #if rows.Count is null or 1 (-lt 2) then we dont need to iterate thru a buncha rows/objects
    if ($getAppServicePlanTableRows.Count -lt 2){
        $tempname = $getAppServicePlanTableRows.PartitionKey
        $tempObj = $getAppServicePlanTableRows
        Write-Output "--------------------------------------------------------------------"
        Write-Output "row count equals one so we can immediately get to work on $tempname"
        Write-Output "--------------------------------------------------------------------"
        Write-Output "running scaleUp command first before running alwayOn stuffs"
        AppServicePlanScaleUp $tempObj.ResourceGroup $tempObj.PartitionKey $tempObj.SkuTier $tempObj.SkuCapacity $tempObj.SkuName
        Write-Output "--------------------------------------------------------------------"
        Write-Output "done running scaleUp command on $tempname"
        Write-Output "--------------------------------------------------------------------"

        $siteToSearchFor = $getAppServicePlanTableRows.SiteName
        $sitesFilter = "PartitionKey eq '$siteToSearchFor'"
        Write-Output "running command to get alwaysOn value"
        $getSitesTableRows = Get-AzTableRow -Table $siteTableObj.CloudTable -CustomFilter $sitesFilter
        #if alwayson is true in our table for this site, flip alwaysOn now that ScaleUp has finished
        if($getSitesTableRows.AlwaysOn -eq $true){
            Write-Output "alwaysOn value we found equals true so we need to flip that value on after Scaling Up"
            Write-Output "--------------------------------------------------------------------"
            #get the webapp obj so we can set the value we want
            Write-Output "getting the webapp object"
            Write-Output "--------------------------------------------------------------------"
            $tempName2 = $getSitesTableRows.PartitionKey
            $webAppObj = Get-AzWebApp -name $tempName2
            #set the value
            Write-Output "setting the alwaysOn value"
            Write-Output "--------------------------------------------------------------------"
            $webAppObj.SiteConfig.AlwaysOn = $true
            $webAppObj | Set-AzWebApp
            Write-Output "--------------------------------------------------------------------"
            Write-Output "done setting AlwaysOn for $tempName2"
            Write-Output "--------------------------------------------------------------------"
        }
        Write-Output "done working on row/rows for: $tempname"
        Write-Output "--------------------------------------------------------------------"
    }

    #if rows.Count -gt 1 then scale up the appservice plan before anything else - then iterate thru each site for that plan and flip alwaysOn where needed
    elseif ($getAppServicePlanTableRows.Count -gt 1){
        $tempname1 = $getAppServicePlanTableRows[0].PartitionKey
        $tempObj = $getAppServicePlanTableRows
        Write-Output "--------------------------------------------------------------------"
        Write-Output "elseif row count greater than one so we need to scaleUp the appserviceplan before anything else"
        Write-Output "array position 0 has a partitionkey name (or appserviceplan name of): $tempname1"
        Write-Output "--------------------------------------------------------------------"
        Write-Output "running scaleUp command first before running alwayOn stuffs"
        AppServicePlanScaleUp $tempObj.ResourceGroup $tempObj.PartitionKey $tempObj.SkuTier $tempObj.SkuCapacity $tempObj.SkuName
        Write-Output "--------------------------------------------------------------------"
        Write-Output "done running scaleUp command on $tempname1"
        Write-Output "--------------------------------------------------------------------"

        #for each row in getAppServicePlanTableRows, get the site names and flip the alwaysOn values to true where necessary
        foreach($row in $getAppServicePlanTableRows){
            $tempname = $row.SiteName
            Write-Output "--------------------------------------------------------------------"
            Write-Output "now the appservice plan is scaled up so for each site check the sitesTable for alwaysOn then flip them on where necessary"
            Write-Output "row we are working on has a sitename of: $tempname"
            $sitesFilter = "PartitionKey eq '$tempname'"
            Write-Output "getting the alwaysOn value for site: $tempname"
            Write-Output "--------------------------------------------------------------------"

            $siteToSearchFor = $getAppServicePlanTableRows.SiteName
            $sitesFilter = "PartitionKey eq '$siteToSearchFor'"
            Write-Output "running command to get alwaysOn value"
            $getSitesTableRows = Get-AzTableRow -Table $siteTableObj.CloudTable -CustomFilter $sitesFilter
            #if alwayson is true flip alwaysOn to false first before running scale down command
            if($getSitesTableRows.AlwaysOn -eq $true){
                Write-Output "alwaysOn value we found equals true for: $tempname - lets set it now"
                Write-Output "--------------------------------------------------------------------"
                #get the webapp obj so we can set the value we want
                Write-Output "getting the webapp object"
                Write-Output "--------------------------------------------------------------------"
                $tempName2 = $getSitesTableRows.PartitionKey
                $webAppObj = Get-AzWebApp -name $tempName2
                #set the value
                Write-Output "setting the alwaysOn value"
                Write-Output "--------------------------------------------------------------------"
                $webAppObj.SiteConfig.AlwaysOn = $true
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
        Write-Output "done working on row/rows for: $tempname1"
        Write-Output "--------------------------------------------------------------------"

    }

## endfunction
}

Write-Output "Write our output from function/runbook run to LogFile"

#run the function & write the output to logfile
ScaleUp 'mypullrequest-012-myapp-webFarm' > ./$logFile
#Scaleup 'qa-coolApp-queueFarm' > ./$logFile

Write-Output "done writing LogFile"

#Copy the logfile to the storage account/blob
Set-AzStorageBlobContent -File $logFile -Container "scaleappserviceplans" -BlobType "Block" -Context $logStorageContext -Verbose -Force
