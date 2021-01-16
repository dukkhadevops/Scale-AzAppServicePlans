# Scale-AzAppServicePlans

## REQUIREMENTS
  Azure Subscription
    Storage Account w/Blobs & Tables
    Azure Automation Account w/access to the Subscription

## DESCRIPTION
This is a solution I've been working on to evaluate all of our subscriptions App Service Plans and, on a schedule of my choosing, scale them up or down based on data I'm creating/manipulating over time within Azure Tables. 

### DISCLAIMER
I'm sure this is far from perfect.... in so many ways. I don't claim to be a whiz at any of this stuff but I thought this may be able to help someone out there so I wanted to take the time to share it. If you do find something you think will help whether thats code logic or just explanation of it feel free to contribute.

############################################################

### OVERVIEW

#### Azure Storage Account = azautomationacct
  1) Azure Tables
  * AppServicePlans+$date
  * Sites+$date
  2) Azure Blobs
  * ScaleAppServicePlans
    * ScaleDown.log
    * ScaleUp.log
    * CreateAppServicePlansAndSiteTables.log
     
#### Automation Account = Scale-AppServicePlans
  1) Runbooks
  * CreateAppServicePlansAndSiteTables
    * Creates a new azure table in the storage account. If a table by the same name exists already it will error out
  * ScaleDown
    * Will evaluate whether or not an App Service Plan has any sites with alwaysOn enabled. If it does it will flip that value off.
    * Once alwaysOn is off it will scale the App Service Plan to Free Tier
  * ScaleUp
    * Will pull the data needed from the Azure Tables we built with CreateAppServicePlansAndSiteTables
      * AppServicePlanTable == App Service Plan + each site using it + the sku detail for each app service plan
      * SitesTable == All the sites you have + if they have alwaysOn property
    * First scales up the App Service Plan according to the sku details found in Azure Table.  
    * Then evaluates each site for an App Service Plan and if alwaysOn was needed, flips it back on (you can't flip it while in free tier so it must be scaled first)
