param(
        [Parameter(Position = 0, Mandatory = $false)]
        [object]
        $WebhookData
)


function Invoke-PresenceDLCheck {
    param(
        [Parameter(Position = 0, Mandatory = $false)]
        [string]
        $ServiceAccount,
        [Parameter(Position = 1, Mandatory = $true)]
        [PSCredential]
        $ServiceAccountCredential,
        [Parameter(Position = 2, Mandatory = $false)]
        [string]
        $GroupEmailAddress,
        [Parameter(Position = 3, Mandatory = $false)]
        [String]
        $CertificateFilePath,

        [Parameter(Position = 4, Mandatory = $false)]
        [SecureString]
        $CertificateFilePassword,

        [Parameter(Position = 5, Mandatory = $false)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]
        $Certificate,

        [Parameter(Position = 6, Mandatory = $false)]
        [String]
        $AppTokenApplicationId = "450ce1c4-5a75-447a-a67b-65031430cd7f",

        [Parameter(Position = 7, Mandatory = $false)]
        [String]
        $ExtensionName = "com.datarumble.dlprocessed",

        [Parameter(Position = 8, Mandatory = $false)]
        [String]
        $ServiceAccountClientId = "d3590ed6-52b3-4102-aeff-aad2292ab01c",
        
        [Parameter(Position = 9, Mandatory = $false)]
        [string]
        $ThreadURI,

        [Parameter(Position = 10, Mandatory = $false)]
        [string]
        $WebHookAddress
        
    )
    process {


        $AppToken = $null
        $connectedToSkype = $false
        $ToRecipents = @();
        Connect-ExrMailbox -MailboxName $ServiceAccount -ClientId $ServiceAccountClientId -Credential $ServiceAccountCredential  -ResourceURL graph.microsoft.com
        $Group = Get-EXRUnifedGroups -mail $GroupEmailAddress
        #Get Group Post created in the last 5 minutes
        if([String]::IsNullOrEmpty($ThreadURI)){
            $Threads = Get-EXRGroupThreads -Group $Group -lastDeliveredDateTime (Get-Date).AddMinutes(-5)
        }
        else{
            $Threads = Get-EXRGroupThread -ThreadURI $ThreadURI
        }
        foreach ($Thread in $Threads) {
            $LastPost = Get-EXRGroupThreadPosts -Group $Group -ThreadId $Thread.id -Top 1 -extensions $ExtensionName
            Write-Verbose "LastPost"
            if (!$LastPost.extensions) {
                Invoke-EXRPostExtension -ItemUri $LastPost.ItemUri -extensionName $ExtensionName -Values "`"processed`":true"
                if (!$connectedToSkype) {
                    connect-exrSK4B -MailboxName $ServiceAccount
                    $connectedToSkype = $true
                }        
                Get-EXRGroupMembers -GroupId $Group.id | ForEach-Object {
                    Write-Verbose $_.mail
                    if (![String]::IsNullOrEmpty($_.mail)) {
                        if ($_.mail -ne $ServiceAccount) {
                            $sk4bUser = Search-EXRSK4BPeople -mail $_.mail
                            if ($sk4bUser._embedded.contact[0]._links.contactPresence) {
                                Write-Verbose $sk4bUser._embedded.contact[0]._links.contactPresence
                                $sk4bPresence = Get-EXRSK4BPresence -PresenceURI $sk4bUser._embedded.contact[0]._links.contactPresence.href
                                if ($sk4bPresence.availability -eq "Online") {
                                    $ToRecipents += (New-EXREmailAddress -Address $_.mail)
                                }
                            }
                        }
                    }
                }
                if ($ToRecipents.Count -eq 0) {
                    #Send Response to user
                    Send-EXRMessageREST -MailboxName $ServiceAccount  -ToRecipients @(New-EXREmailAddress -Address $LastPost.sender.emailAddress.address) -Subject ("Re: " + $Thread.topic ) -Body "Sorry no one is currently available to service this request"
                }
                else {
                    
                    $BodyJson = (ConvertTo-Json $LastPost.PR_BODY_HTML)
                    if (!$AppToken) {
                        $TenantId = Get-EXRTenantId -DomainName  $LastPost.sender.emailAddress.address.Split('@')[1]
                        if(![String]::IsNullOrEmpty($CertificateFilePath)){
                            $AppToken = Get-EXRAppOnlyToken -MailboxName $LastPost.sender.emailAddress.address -CertFileName $CertificateFilePath -password $CertificateFilePassword -ClientId $AppTokenApplicationId -NoCache -TenantId $TenantId -ResourceURL "graph.microsoft.com"
                        }else{
                            $AppToken = Get-EXRAppOnlyToken -MailboxName $LastPost.sender.emailAddress.address -Certificate $Certificate -ClientId $AppTokenApplicationId -NoCache -TenantId $TenantId -ResourceURL "graph.microsoft.com"
                        }
                    }
            
                    Send-EXRMessageREST -MailboxName $LastPost.sender.emailAddress.address  -AccessToken $AppToken -ToRecipients $ToRecipents -Subject $Thread.topic -Body $BodyJson.SubString(1, ($BodyJson.length - 2))  -SenderEmailAddress (New-EXREmailAddress -Address $LastPost.sender.emailAddress.address)
                }
            }
        }
        write-output "Start Subscriptions"
        $GroupURI = "groups('" + $Group.id + "')/Threads"
        $Subscriptions = Get-EXRSubscriptions 
        $Subscribe = $true
        foreach($Subscription in $Subscriptions){
            if(($Subscription.notificationUrl -eq $WebHookAddress) -band ($Subscription.resource -eq $GroupURI)){
                 if(([DateTime]$Subscription.expirationDateTime).ToUniversalTime() -lt (Get-Date).ToUniversalTime().AddHours(2)){
                    Invoke-EXRDeleteSubscription -SubscriptionId $Subscription.id
                 }else{
                    $Subscribe = $false
                }
            }
        }
        if($Subscribe){
            write-output "Create Subscriptions"
            New-EXRSubscription -changeType created -notificationUrl $WebHookAddress -resource $GroupURI -expirationDateTime (Get-Date).ToUniversalTime().AddDays(2) -clientState "none"    
        }else{
            write-output "Subscription Exists"
        }
    }
}

if($WebhookData.RequestBody){
    $JSONData = ConvertFrom-Json $WebhookData.RequestBody
    $WebHookThreadURI = "https://graph.microsoft.com/v1.0/" + $JSONData.value[0].resource
}

$WebHookAddress = "https://graph-relay.azurewebsites.net/api/graphhook?code=......";
$ServiceAccountCreds = Get-AutomationPSCredential -Name 'DL-ServiceAccount@datarumble.com'
$Certificate = Get-AutomationCertificate -Name "AppOnlyMail"
Invoke-PresenceDLCheck -ServiceAccount "DL-ServiceAccount@datarumble.com" -ServiceAccountCredential $ServiceAccountCreds -GroupEmailAddress "Available-Techies@datarumble.com" -Certificate $Certificate -ThreadURI $WebHookThreadURI -WebHookAddress $WebHookAddress
write-output "done"