# Report-InactiveTeamsByEmail.PS1
# an example of how to report inactive teams based on their activity as recorded in audit logs and 
# the usage report.
# 
# V1.0 19-Feb-2025
# GitHub Link: https://github.com/12Knocksinna/Office365itpros/blob/master/Report-InactiveTeamsByEmail.PS1

# Needs these permissions:
# Team.ReadBasic.All - read Teams information
# AuditQuery.Read.All and AuditLog.Read.All to access audit data
# Reports.Read.All to read usage data for Teams
# Sites.Read.All to read the site URL for a team 
# ReportSettings.ReadWrite.All to disable/enable usage report obfuscation if required
# GroupMember.Read.All to read team membership
# User.Read.All to read details of members found in groups

# Would like to use SharePoint Site Usage report but site URL is not included https://learn.microsoft.com/en-gb/graph/api/reportroot-getsharepointsiteusagedetail?view=graph-rest-1.0&WT.mc_id=M365-MVP-9501
# So we have to use the audit log to find file upload and file modified events
# See https://office365itpros.com/2024/02/19/sharepoint-usage-data-issue/ 

# Script runs in app-only mode or using an Azure Automation account
Connect-MgGraph -TenantId $TenantId -AppId $AppId -CertificateSubjectName $Thumbprint

# Run an audit job to find SharePoint FileUpload and FileModified events
# SharePoint events at https://learn.microsoft.com/en-us/purview/audit-log-activities?WT.mc_id=M365-MVP-9501#file-and-page-activities

Write-Output "Generating audit report for SharePoint file activities..."
Set-MgRequestContext -MaxRetry 10 -RetryDelay 15 | Out-Null
$AuditQueryName = ("Audit Job SPO Operations created at {0}" -f (Get-Date))
$StartDate = (Get-Date).AddDays(-30)
$EndDate = (Get-Date).AddDays(1)
$AuditQueryStart = (Get-Date $StartDate -format s)
$AuditQueryEnd = (Get-Date $EndDate -format s)
[array]$AuditQueryOperations = "FileModified", "FileUploaded"
$AuditQueryParameters = @{}
#$AuditQueryParameters.Add("@odata.type","#microsoft.graph.security.auditLogQuery")
$AuditQueryParameters.Add("displayName", $AuditQueryName)
$AuditQueryParameters.Add("OperationFilters", $AuditQueryOperations)
$AuditQueryParameters.Add("filterStartDateTime", $AuditQueryStart)
$AuditQueryParameters.Add("filterEndDateTime", $AuditQueryEnd)

# Submit the audit query job
$AuditJob =  New-MgBetaSecurityAuditLogQuery -BodyParameter $AuditQueryParameters

# Check the audit query job status every 20 seconds until it completes
[int]$i = 1
[int]$SleepSeconds = 20
$SearchFinished = $false; [int]$SecondsElapsed = 20
Write-Host "Checking audit query status..."
Start-Sleep -Seconds 30
$Uri = ("https://graph.microsoft.com/beta/security/auditLog/queries/{0}" -f $AuditJob.Id)
$AuditQueryStatus = Invoke-MgGraphRequest -Uri $Uri -Method GET
While ($SearchFinished -eq $false) {
    $i++
    Write-Host ("Waiting for audit search to complete. Check {0} after {1} seconds. Current state {2}" -f $i, $SecondsElapsed, $AuditQueryStatus.status)
    If ($AuditQueryStatus.status -eq 'succeeded') {
        $SearchFinished = $true
    } Else {
        Start-Sleep -Seconds $SleepSeconds
        $SecondsElapsed = $SecondsElapsed + $SleepSeconds
        $AuditQueryStatus = Invoke-MgGraphRequest -Uri $Uri -Method GET
    }
}

Write-Host "Fetching audit records found by the search..."
$Uri = ("https://graph.microsoft.com/beta/security/auditLog/queries/{0}/records?`$Top=999" -f $AuditJob.Id)
[array]$SearchRecords = Invoke-MgGraphRequest -Uri $Uri -Method GET

[array]$AuditRecords = $SearchRecords.value
# Paginate to fetch all available audit records
$NextLink = $SearchRecords.'@odata.NextLink'
While ($null -ne $NextLink) {
    $SearchRecords = $null
    [array]$SearchRecords = Invoke-MgGraphRequest -Uri $NextLink -Method GET 
    $AuditRecords += $SearchRecords.value
    Write-Host ("{0} audit records fetched so far..." -f $AuditRecords.count)
    $NextLink = $SearchRecords.'@odata.NextLink' 
}

Write-Host ("Total of {0} audit records found" -f $AuditRecords.count) -ForegroundColor Red

# Parse the audit records and extract information about the sites where activities occurred.
$SPOAuditInfo = [System.Collections.Generic.List[Object]]::new()
ForEach ($Record in $AuditRecords) {
    $SiteUrl = $null

    Switch ($Record.Operation) {
        "FileModified" {
            If ($Record.AuditData.SourceRelativeURL -notlike "*PreservationHoldLibrary") {
                $SiteUrl = $Record.AuditData.SiteUrl
            }
        }
        "FileUploaded" {
            $SiteUrl = $Record.AuditData.SiteUrl
        }
    }
    $SPOAuditLine = [PSCustomObject]@{
        Id          = $Record.Id
        Creation    = Get-Date $Record.CreatedDateTime -format 'dd-MMM-yyyy HH:mm:ss'
        User        = $Record.UserId
        Operation   = $Record.Operation
        SiteURL     = $SiteUrl
    }
    $SPOAuditInfo.Add($SPOAuditLine)
}

# Now get the usage report data
$ObfuscationChanged = $false
If ((Get-MgAdminReportSetting).DisplayConcealedNames -eq $True) {
   $Parameters = @{ displayConcealedNames = $False }
   Update-MgAdminReportSetting -BodyParameter $Parameters
   $ObfuscationChanged = $true
}
Write-Output "Fetching Teams usage data..."
$TempFile = "C:\Temp\TeamActivityDetail.csv"
Get-MgReportTeamActivityDetail -Period 'D30' -OutFile $TempFile
$TeamsData = Import-Csv -Path $TempFile

If ($ObfuscationChanged) {
    If ((Get-MgAdminReportSetting).DisplayConcealedNames -eq $False) {
       $Parameters = @{ displayConcealedNames = $True }
       Update-MgAdminReportSetting -BodyParameter $Parameters
    }
}

# Get a list of all teams
Write-Host "Fetching list of Teams..."
[array]$Teams = Get-MgTeam -All -PageSize 500
If (!$Teams) {
    Write-Host "No Teams found"
    Break
}
Write-Output ("Found {0} Teams" -f $Teams.Count)

Write-Output "Generating report about Teams activity..."
# For each team, check what activities we know about
$TeamReport = [System.Collections.Generic.List[Object]]::new()
ForEach ($Team in $Teams) {

    # To be able to filter out archived teams and to get the created date, we need to fetch the Team settings
    # It's silly that these properties aren't returned by default when you list teams.
    # https://learn.microsoft.com/en-us/graph/api/teams-list?view=graph-rest-1.0&WT.mc_id=M365-MVP-9501
    $TeamSettings = Get-MgTeam -Team $Team.Id
    If ($TeamSettings.IsArchived -eq $true) {
        Write-Host ("The {0} team is archived and is excluded from active status checks" -f $Team.DisplayName)
        Continue
    }
    $CreatedDate = $TeamSettings.CreatedDateTime
    $AgeInDays = (New-TimeSpan -Start $CreatedDate -End (Get-Date)).Days

    # Get the webURL for the Team site - this is one way to get the information
    $WebURL = $null
    $Uri = ("https://graph.microsoft.com/v1.0/groups/{0}/sites/root?`$select=webUrl" -f $Team.id)
    Try {
        $Data = Invoke-MgGraphRequest -Uri $Uri -Method Get -ErrorAction SilentlyContinue
    } Catch {
        Write-Host ("Unable to find SharePoint site for {0}. It might not have been created." -f $Team.DisplayName)
        Continue
    }
    $WebURL = $Data.WebUrl + "/"
    # Get team owners
    $OwnersDisplayNames = $null
    [array]$Owners = Get-MgGroupOwner -GroupId $Team.Id | Select-Object -ExpandProperty AdditionalProperties 
    $OwnersDisplayNames = $Owners.displayName -join ", "
    # Try and find any audit records for filesuploaded and updated for the site
    [array]$FilesUploaded = $SPOAuditInfo | Where-Object { $_.SiteURL -eq $WebURL -and $_.Operation -eq 'FileUploaded' }
    [array]$FilesModified = $SPOAuditInfo | Where-Object { $_.SiteURL -eq $WebURL -and $_.Operation -eq 'FileModified' }
    [array]$UsageData = $TeamsData | Where-Object { $_.'Team Id' -eq $Team.Id }
    If ($UsageData) {
        $ActiveUsers = $UsageData.'Active Users'
        $ActiveChannels = $UsageData.'Active Channels'	    
        $ChannelMessages = $UsageData.'Channel Messages'
        $Reactions = $UsageData.'Reactions'
        $MeetingsOrganized = $UsageData.'Meetings Organized'    
        $PostMessages = $UsageData.'Post Messages'
        $ReplyMessages = $UsageData.'Reply Messages'
        $UrgentMessages = $UsageData.'Urgent Messages'
        $Mentions = $UsageData.'Mentions'
        $ActiveSharedChannels = $UsageData.'Active Shared Channels'
    } Else {
        $ActiveUsers = 0
        $ActiveChannels = 0
        $ChannelMessages = 0
        $Reactions = 0
        $MeetingsOrganized = 0
        $PostMessages = 0
        $ReplyMessages = 0
        $UrgentMessages = 0
        $Mentions = 0       
        $ActiveSharedChannels = 0
    }

    If ($UsageData.'Last Activity Date') {
        $LastActiveDate = Get-Date $UsageData.'Last Activity Date' -format dd-MMM-yyyy
    } Else {
        $LastActiveDate = "Never active"
    }   

    [int]$CountOfTeamActivities = $FilesUploaded.Count + $FilesModified.Count + $ActiveUsers + $Reactions + $ChannelMessages + $PostMessages + $ReplyMessages

    $TeamReportLine = [PSCustomObject][Ordered]@{ 
        DisplayName         = $Team.DisplayName
        TeamId              = $Team.Id
        Created             = Get-Date $CreatedDate -format 'dd-MMM-yyyy HH:mm'
        'Age in Days'       = $AgeInDays
        Visibility          = $Team.Visibility
        Description         = $Team.Description
        Owners              = $OwnersDisplayNames
        SiteURL             = $WebURL
        FilesUploaded       = $FilesUploaded.Count
        FilesModified       = $FilesModified.Count
        'Last active date'  = $LastActiveDate
        'Active Users'      = $ActiveUsers
        'Active Channels'   = $ActiveChannels
        'Channel Messages'  = $ChannelMessages
        Reactions           = $Reactions
        'Meetings Organized' = $MeetingsOrganized
        'Post Messages'     = $PostMessages
        'Reply Messages'    = $ReplyMessages
        'Urgent Messages'   = $UrgentMessages
        Mentions            = $Mentions
        Members             = $TeamSettings.Summary.MembersCount
        'Owner count'       = $TeamSettings.Summary.OwnersCount
        Guests              = $TeamSettings.Summary.GuestsCount
        'Active Shared Channels' = $ActiveSharedChannels
        'Count of Activities' = $CountOfTeamActivities
    }
    $TeamReport.Add($TeamReportLine)
}

$SelectedTeamReport =  [System.Collections.Generic.List[Object]]::new()
$SelectedTeamReport = $TeamReport | Where-Object {$_.'Count of Activities' -le 100} | Select-Object DisplayName, Created, 'Age in Days', 'Last active date', Owners, 'Count of Activities', SiteURL

[array]$MsgAttachments = $null
$OutputFile = "C:\Temp\InactiveTeams.csv"
$TeamReport | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8

$ConvertedContent = [Convert]::ToBase64String([IO.File]::ReadAllBytes($OutputFile))
$FileName = [System.IO.Path]::GetFileName($OutputFile)

$AttachmentDetails = @{
    "@odata.type" = "#microsoft.graph.fileAttachment"
    Name = $FileName
    ContentBytes = $ConvertedContent
}
$MsgAttachments += $AttachmentDetails

# Define some variables used to construct the HTML content in the message body
# HTML header with styles
$HtmlHead="<html>
    <style>
    BODY{font-family: Arial; font-size: 10pt;}
	H1{font-size: 22px;}
	H2{font-size: 18px; padding-top: 10px;}
	H3{font-size: 16px; padding-top: 8px;}
    H4{font-size: 8px; padding-top: 4px;}
</style>"

$HtmlBody = $null
$HtmlBody = $HtmlBody + "<body> <h1>Check for potentially inactive teams.</h1><p></p>"   

$HtmlBody = $HtmlBody + ($SelectedTeamReport | Sort-Object DisplayName | ConvertTo-HTML -Fragment -As Table -PreContent "<h2>Administrative alert: Inactive Teams based on 30-day lookback</h2>")
$HtmlBody = $HtmlBody + "<p>These teams are highlighted because of their lack of activity in Teams messaging and SharePoint Online. Please check to ensure that they are still needed.</p>"
$HtmlBody = $HtmlBody + "<p><h4>Generated:</strong> $(Get-Date -Format 'dd-MMM-yyyy HH:mm')</h4></p>"

$HtmlMsg = $HtmlHead + $HtmlBody + "<p></body>"

$MsgSubject = "Potentially inactive Teams for review"
$MsgFrom = 'Customer.Services@office365itpros.com'
$MsgAddressee = "tony.redmond@office365itpros.com"

$ToRecipients = @{}
$ToRecipients.Add("emailAddress", @{"address"=$MsgAddressee} )
[array]$MsgTo = $ToRecipients

# Construct the message body
$MsgBody = @{}
$MsgBody.Add('Content', "$($HtmlMsg)")
$MsgBody.Add('ContentType','html')

$Message = @{}
$Message.Add('subject', $MsgSubject)
$Message.Add('toRecipients', $MsgTo)    
$Message.Add('body', $MsgBody)
$Message.Add('attachments', $MsgAttachments) 

$Params = @{}
$Params.Add('message', $Message)
$Params.Add('saveToSentItems', $true)
$Params.Add('isDeliveryReceiptRequested', $true)    

Send-MgUserMail -UserId $MsgFrom -BodyParameter $Params

Write-Output ("Email with inactive Teams listing sent to {0}" -f $MsgAddressee)

# An example script used to illustrate a concept. More information about the topic can be found in the Office 365 for IT Pros eBook https://gum.co/O365IT/
# and/or a relevant article on https://office365itpros.com or https://www.practical365.com. See our post about the Office 365 for IT Pros repository # https://office365itpros.com/office-365-github-repository/ for information about the scripts we write.

# Do not use our scripts in production until you are satisfied that the code meets the need of your organization. Never run any code downloaded from the Internet without
# first validating the code in a non-production environment.