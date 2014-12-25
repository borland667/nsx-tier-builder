cls

# Manually defined variables
$nsx = "nsx.glacier.local"
$jsonpath = "W:\Code\scripts\VMware NSX\prod-tier.json"

# Secure credentials
if (-not $nsxcreds) {$nsxcreds = Get-Credential -UserName "admin" -Message "NSX Credentials"}

# Create NSX authorization string and store in $head
$auth = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("admin:"+$($nsxcreds.GetNetworkCredential().password)))
$head = @{"Authorization"="Basic $auth"}
$uri = "https://$nsx"

# Combine switches and transit into a build list (easier than messing with a custom PS object!)
$switchlist = @()
foreach ($_ in $config.switches) {$switchlist += $_.name}
$switchlist += $config.transit.name

# Remove edge

# Remove router

$r = Invoke-WebRequest -Uri "$uri/api/4.0/edges" -Headers $head -ContentType "application/xml" -ErrorAction:Stop
[xml]$rxml = $r.Content
foreach ($_ in $rxml.pagedEdgeList.edgePage.edgeSummary) {
	if ($_.name -eq $config.router.name) {
		$r = Invoke-WebRequest -Uri "$uri/api/4.0/edges/$($_.objectId)" -Headers $head -Method:Delete -ContentType "application/xml" -ErrorAction:Stop
		if ($r.StatusCode -eq "204") {Write-Host -BackgroundColor:Black -ForegroundColor:Green "Status: Successfully deleted $($_.name) router."}
		}
	}

# Remove switches
$r = Invoke-WebRequest -Uri "$uri/api/2.0/vdn/virtualwires" -Headers $head -ContentType "application/xml" -ErrorAction:Stop
[xml]$rxml = $r.Content
foreach ($_ in $rxml.virtualWires.dataPage.virtualWire) {
	if ($switchlist -contains $_.name) {
		$r = Invoke-WebRequest -Uri "$uri/api/2.0/vdn/virtualwires/$($_.objectId)" -Headers $head -Method:Delete -ContentType "application/xml" -ErrorAction:Stop
		if ($r.StatusCode -eq "200") {Write-Host -BackgroundColor:Black -ForegroundColor:Green "Status: Successfully deleted $($_.name) switch."}
		}
	}