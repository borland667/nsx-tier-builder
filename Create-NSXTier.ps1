function Create-NSXTier {

<#  
.SYNOPSIS  Creates a virtual network tier for VMware NSX
.DESCRIPTION Creates a virtual network tier for VMware NSX
.NOTES  Author:  Chris Wahl, @ChrisWahl, WahlNetwork.com
.PARAMETER NSX
	NSX Manager IP or FQDN
.PARAMETER NSXPassword
	NSX Manager credentials with administrative authority
.PARAMETER NSXUsername
	NSX Manager username with administrative authority
.PARAMETER JSONPath
	Path to your JSON configuration file
.PARAMETER vCenter
	vCenter Server IP or FQDN
.PARAMETER NoAskCreds
	Use your current login credentials for vCenter
.EXAMPLE
	PS> Create-NSXTier -NSX nsxmgr.tld -vCenter vcenter.tld -JSONPath "c:\path\prod.json"
#>

[CmdletBinding()]
Param(
	[Parameter(Mandatory=$true,Position=0,HelpMessage="NSX Manager IP or FQDN")]
	[ValidateNotNullorEmpty()]
	[String]$NSX,
	[Parameter(Mandatory=$true,Position=1,HelpMessage="NSX Manager credentials with administrative authority")]
	[ValidateNotNullorEmpty()]
	[System.Security.SecureString]$NSXPassword,
	[Parameter(Mandatory=$true,Position=2,HelpMessage="Path to your JSON configuration file")]
	[ValidateNotNullorEmpty()]
	[String]$JSONPath,
	[Parameter(Mandatory=$true,Position=3,HelpMessage="vCenter Server IP or FQDN")]
	[ValidateNotNullorEmpty()]
	[String]$vCenter,
	[String]$NSXUsername = "admin",
	[Parameter(HelpMessage="Use your current login credentials for vCenter")]
	[Switch]$NoAskCreds
	)

Process {
# Time this puppy!
$startclock = (Get-Date)

# Create NSX authorization string and store in $head
$nsxcreds = New-Object System.Management.Automation.PSCredential "admin",$NSXPassword
$auth = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($NSXUsername+":"+$($nsxcreds.GetNetworkCredential().password)))
$head = @{"Authorization"="Basic $auth"}
$uri = "https://$nsx"

# Plugins and version check
Add-PSSnapin VMware.VimAutomation.Core -ErrorAction:SilentlyContinue
Add-PSSnapin VMware.VimAutomation.Vds -ErrorAction:SilentlyContinue
if ($Host.Version.Major -lt 3) {throw "PowerShell 3 or higher is required"}

# Parse configuration from json file
$config = Get-Content -Raw -Path $jsonpath | ConvertFrom-Json
	if ($config) {Write-Host -BackgroundColor:Black -ForegroundColor:Yellow "Status: Parsed configuration from json file."}
	else {throw "I don't have a config, something went wrong."}

# Combine switches and transit into a build list (easier than messing with a custom PS object!)
$switchlist = @()
foreach ($_ in $config.switches) {$switchlist += $_.name}
$switchlist += $config.transit.name

# Get MoRefs for the vSphere components
if ($NoAskCreds -eq $false) {
	$vcentercreds = Get-Credential -Message "vCenter Server credentials"
	Connect-VIServer -Server $vCenter -Credential $vcentercreds | Out-Null
	}
else {Connect-VIServer -Server $vCenter | Out-Null}
$moref = @{}
$moref.Add("datacenter",(Get-Datacenter $config.vsphere.datacenter | Get-View).MoRef.Value)
$moref.Add("cluster",(Get-Cluster $config.vsphere.cluster | Get-View).MoRef.Value)
$moref.Add("rp",(Get-ResourcePool -Location (Get-Cluster $config.vsphere.cluster) -Name "Resources" | Get-View).MoRef.Value)
$moref.Add("datastore",(Get-Datastore -Location (Get-Datacenter $config.vsphere.datacenter) $config.vsphere.datastore | Get-View).MoRef.Value)
$moref.Add("folder",(Get-Folder $config.vsphere.folder | Get-View).MoRef.Value)
$moref.Add("edge_uplink",(Get-VDPortgroup $config.edge.uplink.iface | Get-View).MoRef.Value)
$moref.Add("edge_mgmt",(Get-VDPortgroup $config.edge.management.iface | Get-View).MoRef.Value)
$moref.Add("router_mgmt",(Get-VDPortgroup $config.router.management.iface | Get-View).MoRef.Value)
	if ($moref) {
		Write-Host -BackgroundColor:Black -ForegroundColor:Yellow "Status: Gathered MoRef IDs from $vcenter."
		Disconnect-VIServer -Confirm:$false
		}
	else {throw "I don't have any MoRefs, something went wrong."}

# Allow untrusted SSL certs
	add-type @"
	    using System.Net;
	    using System.Security.Cryptography.X509Certificates;
	    public class TrustAllCertsPolicy : ICertificatePolicy {
	        public bool CheckValidationResult(
	            ServicePoint srvPoint, X509Certificate certificate,
	            WebRequest request, int certificateProblem) {
	            return true;
	        }
	    }
"@
	[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

# Get the network scope (transport zone)
# Note: I'm assuming your TZ is attached to the correct clusters
$r = Invoke-WebRequest -Uri "$uri/api/2.0/vdn/scopes" -Headers $head -ContentType "application/xml" -ErrorAction:Stop
[xml]$rxml = $r.Content
	if (-not $rxml.vdnScopes.vdnScope.objectId) {throw "No network scope found. Create a transport zone and attach to your cluster."}
	$nsxscopeid = $rxml.vdnScopes.vdnScope.objectId

#############################################################################################################################################
# Create switches																															#
#############################################################################################################################################

	# Get current list of switches to find if any already exist
	$r = Invoke-WebRequest -Uri "$uri/api/2.0/vdn/virtualwires" -Headers $head -ContentType "application/xml" -ErrorAction:Stop
	[xml]$rxml = $r.Content
	$switches = @()
	foreach ($_ in $rxml.virtualWires.dataPage.virtualWire) {$switches += $_.name}

	# Loop through our build list from earlier
	foreach ($_ in $switchlist) {
		
		# Skip any duplicate switches
		if ($switches -contains $_) {Write-Host -BackgroundColor:Black -ForegroundColor:Red "Warning: $_ exists. Skipping."}
		
		# Build any missing switches
		else {						
			[xml]$body = "<virtualWireCreateSpec><name>$_</name><tenantId></tenantId></virtualWireCreateSpec>"
			$r = Invoke-WebRequest -Uri "$uri/api/2.0/vdn/scopes/$nsxscopeid/virtualwires" -Body $body -Method:Post -Headers $head -ContentType "application/xml" -ErrorAction:Stop -TimeoutSec 30
			if ($r.StatusDescription -match "Created") {Write-Host -BackgroundColor:Black -ForegroundColor:Green "Status: Successfully created $_ switch."}
			else {throw "Was not able to create switch. API status description was not `"created`""}
			}
		}
	
	Write-Host -BackgroundColor:Black -ForegroundColor:Yellow "Status: Switch section completed."

#############################################################################################################################################
# Create router																																#
#############################################################################################################################################

	# Make sure the router doesn't already exist
	$makerouter = $true
	$r = Invoke-WebRequest -Uri "$uri/api/4.0/edges" -Headers $head -ContentType "application/xml" -ErrorAction:Stop
	[xml]$rxml = $r.Content
	foreach ($_ in $rxml.pagedEdgeList.edgePage.edgeSummary) {
		if ($_.name -eq $config.router.name) {
			Write-Host -BackgroundColor:Black -ForegroundColor:Red "Warning: $($_.name) exists. Skipping."
			$makerouter = $false
			}
		}

	# Get virtualwire ID for switches
	# Note: We can't assume that this script built the switches above, so let's query the API again now that all switches exist
	$r = Invoke-WebRequest -Uri "$uri/api/2.0/vdn/virtualwires" -Headers $head -ContentType "application/xml" -ErrorAction:Stop
	[xml]$rxml = $r.Content
	$switchvwire = @{}
	foreach ($_ in $rxml.virtualWires.dataPage.virtualWire) {
		$switchvwire.Add($_.name,$_.objectId)
		}

	# If the $makerouter flag is $false, skip the router part. Using it as a flag based on the previous router search.
	If ($makerouter -ne $false) {

	# Start a new body for the router XML payload (bleh to XML!)
	[string]$body = "<edge>
<datacenterMoid>$($moref.datacenter)</datacenterMoid>
<name>$($config.router.name)</name>
<fqdn>$($config.router.name)</fqdn>
<tenant>$($config.router.tenant)</tenant>
<appliances>
<applianceSize>compact</applianceSize>
<appliance>
<resourcePoolId>$($moref.rp)</resourcePoolId>
<datastoreId>$($moref.datastore)</datastoreId>
<vmFolderId>$($moref.folder)</vmFolderId>
</appliance>
</appliances>
<cliSettings>
<remoteAccess>$($config.router.cli.enabled)</remoteAccess>
<userName>$($config.router.cli.user)</userName>
<password>$($config.router.cli.pass)</password>
<passwordExpiry>$($config.router.cli.expiredays)</passwordExpiry>
</cliSettings>
<type>distributedRouter</type>
<mgmtInterface>
<label>vNic_0</label>
<name>mgmtInterface</name>
<addressGroups />
<mtu>1500</mtu>
<index>0</index>
<connectedToId>$($moref.router_mgmt)</connectedToId>
</mgmtInterface>
<features>
<firewall>
<enabled>$($config.router.firewall)</enabled>
</firewall>
<highAvailability>
<enabled>$($config.router.ha)</enabled>
</highAvailability>
</features>"
 
 	# Add the uplink interface
	
	$body += "<interfaces><interface>
<name>$($config.transit.name)</name>
<type>uplink</type>
<mtu>1500</mtu>
<isConnected>true</isConnected>
<addressGroups>
<addressGroup>
<primaryAddress>$($config.transit.routerip)</primaryAddress>
<subnetMask>$($config.transit.mask)</subnetMask>
</addressGroup>
</addressGroups>
<connectedToId>$($switchvwire.get_Item($config.transit.name))</connectedToId>
</interface>"
 
 	# Add the internal interface(s) via a loop
	
	foreach ($_ in $config.switches) {
		$body += "<interface>
<name>$($_.name)</name>
<type>internal</type>
<mtu>1500</mtu>
<isConnected>true</isConnected>
<addressGroups>
<addressGroup>
<primaryAddress>$($_.ip)</primaryAddress>
<subnetMask>$($_.mask)</subnetMask>
</addressGroup>
</addressGroups>
<connectedToId>$($switchvwire.get_Item($_.name))</connectedToId>
</interface>"		
		}
	
	# Close XML tags
	$body += "</interfaces></edge>"
	
	# Post the router to the API
	# Note: At this point, no routing is configured. It appears the API wants that after the build is done and not before.
	Write-Host -BackgroundColor:Black -ForegroundColor:Yellow "Status: Creating router. This may take a few minutes."
	try {$r = Invoke-WebRequest -Uri "$uri/api/4.0/edges" -Body $body -Method:Post -Headers $head -ContentType "application/xml" -TimeoutSec 180 -ErrorAction:Stop} catch {Failure}
	if ($r.StatusDescription -match "Created") {Write-Host -BackgroundColor:Black -ForegroundColor:Green "Status: Successfully created $($config.router.name) router."
	$routerid = ($r.Headers.get_Item("Location")).split("/") | Select-Object -Last 1
		}
	else {
		$body
		throw "Was not able to create router. API status description was not `"created`""
		}

	# Routing configuration
	$body = "<routing>
<enabled>true</enabled>
<routingGlobalConfig>
<routerId>$($config.transit.routerip)</routerId>
<logging>
<enable>true</enable>
<logLevel>warning</logLevel>
</logging>
</routingGlobalConfig>
<staticRouting>
<defaultRoute>
<vnic>2</vnic>
<mtu>1500</mtu>
<gatewayAddress>$($config.transit.edgeip)</gatewayAddress>
</defaultRoute>
</staticRouting>
<ospf>
<enabled>$($config.router.ospf.enabled)</enabled>
<protocolAddress>$($config.transit.protoip)</protocolAddress>
<forwardingAddress>$($config.transit.routerip)</forwardingAddress>
<ospfAreas>
<ospfArea>
<areaId>$($config.router.ospf.area)</areaId>
<type>$($config.router.ospf.type)</type>
<authentication>
<type>none</type>
</authentication>
</ospfArea>
</ospfAreas>
<ospfInterfaces>
<ospfInterface>
<vnic>2</vnic>
<areaId>$($config.router.ospf.area)</areaId>
<helloInterval>10</helloInterval>
<deadInterval>40</deadInterval>
<priority>128</priority>
<cost>1</cost>
<mtuIgnore>false</mtuIgnore>
</ospfInterface>
</ospfInterfaces>
<redistribution>
<enabled>true</enabled>
<rules>
<rule>
<id>0</id>
<from>
<isis>false</isis>
<ospf>false</ospf>
<bgp>false</bgp>
<static>false</static>
<connected>true</connected>
</from>
<action>permit</action>
</rule>
</rules>
</redistribution>
<gracefulRestart>true</gracefulRestart>
<defaultOriginate>false</defaultOriginate>
</ospf>
</routing>"
	
	# Configure routing on the router (yo dawg)
	try {$r = Invoke-WebRequest -Uri "$uri/api/4.0/edges/$routerid/routing/config" -Body $body -Method:Put -Headers $head -ContentType "application/xml" -ErrorAction:Stop -TimeoutSec 30} catch {Failure}
	if ($r.StatusCode -match "204") {Write-Host -BackgroundColor:Black -ForegroundColor:Green "Status: Successfully applied routing config to $($config.router.name)."}
	else {
		$body
		throw "Was not able to apply routing config to router. API status code was not 204."
		}

	# End of the $makerouter check
	}
	
	Write-Host -BackgroundColor:Black -ForegroundColor:Yellow "Status: Router section completed."

#############################################################################################################################################
# Create edge																																#
#############################################################################################################################################

	# Make sure the edge doesn't already exist
	$makeedge = $true
	$r = Invoke-WebRequest -Uri "$uri/api/4.0/edges" -Headers $head -ContentType "application/xml" -ErrorAction:Stop
	[xml]$rxml = $r.Content
	foreach ($_ in $rxml.pagedEdgeList.edgePage.edgeSummary) {
		if ($_.name -eq $config.edge.name) {
			Write-Host -BackgroundColor:Black -ForegroundColor:Red "Warning: $($_.name) exists. Skipping."
			$makeedge = $false
			}
		}

	# If the $makerouter flag is $false, skip the router part. Using it as a flag based on the previous router search.
	If ($makeedge -ne $false) {

	# Start a new body for the edge XML payload (bleh to XML!)
	[string]$body = "<edge>
<datacenterMoid>$($moref.datacenter)</datacenterMoid>
<name>$($config.edge.name)</name>
<fqdn>$($config.edge.name)</fqdn>
<tenant>$($config.edge.tenant)</tenant>
<vseLogLevel>emergency</vseLogLevel>
<vnics>
<vnic>
<label>vNic_0</label>
<name>$($config.transit.name)</name>
<addressGroups>
<addressGroup>
<primaryAddress>$($config.transit.edgeip)</primaryAddress>
<subnetMask>$($config.transit.mask)</subnetMask>
</addressGroup>
</addressGroups>
<mtu>1500</mtu>
<type>internal</type>
<isConnected>true</isConnected>
<index>0</index>
<portgroupId>$($switchvwire.get_Item($config.transit.name))</portgroupId>
<enableProxyArp>false</enableProxyArp>
<enableSendRedirects>false</enableSendRedirects>
</vnic>
<vnic>
<label>vNic_1</label>
<name>$($config.edge.uplink.name)</name>
<addressGroups>
<addressGroup>
<primaryAddress>$($config.edge.uplink.ip)</primaryAddress>
<subnetMask>$($config.edge.uplink.mask)</subnetMask>
</addressGroup>
</addressGroups>
<mtu>1500</mtu>
<type>uplink</type>
<isConnected>true</isConnected>
<index>1</index>
<portgroupId>$($moref.edge_uplink)</portgroupId>
<enableProxyArp>false</enableProxyArp>
<enableSendRedirects>true</enableSendRedirects>
</vnic>
</vnics>
<appliances>
<applianceSize>compact</applianceSize>
<appliance>
<resourcePoolId>$($moref.rp)</resourcePoolId>
<datastoreId>$($moref.datastore)</datastoreId>
<vmFolderId>$($moref.folder)</vmFolderId>
</appliance>
</appliances>
<cliSettings>
<remoteAccess>$($config.edge.cli.enabled)</remoteAccess>
<userName>$($config.edge.cli.user)</userName>
<password>$($config.edge.cli.pass)</password>
<passwordExpiry>$($config.edge.cli.expiredays)</passwordExpiry>
</cliSettings>
<features>
<firewall>
<enabled>$($config.edge.firewall)</enabled>
</firewall>
<highAvailability>
<enabled>$($config.edge.ha)</enabled>
</highAvailability>
</features>
<type>gatewayServices</type>
</edge>"
	
	# Post the edge to the API
	# Note: At this point, no routing is configured. It appears the API wants that after the build is done and not before.
	Write-Host -BackgroundColor:Black -ForegroundColor:Yellow "Status: Creating edge. This may take a few minutes."
	try {$r = Invoke-WebRequest -Uri "$uri/api/4.0/edges" -Body $body -Method:Post -Headers $head -ContentType "application/xml" -ErrorAction:Stop -TimeoutSec 180} catch {Failure}
	if ($r.StatusDescription -match "Created") {Write-Host -BackgroundColor:Black -ForegroundColor:Green "Status: Successfully created $($config.edge.name) edge."
	$edgeid = ($r.Headers.get_Item("Location")).split("/") | Select-Object -Last 1
		}
	else {
		$body
		throw "Was not able to create edge. API status description was not `"created`""
		}
	
	# Routing configuration
	$body = "<routing>
<enabled>true</enabled>
<routingGlobalConfig>
<routerId>$($config.edge.uplink.ip)</routerId>
<logging>
<enable>true</enable>
<logLevel>warning</logLevel>
</logging>
</routingGlobalConfig>
<staticRouting>
<defaultRoute>
<vnic>1</vnic>
<mtu>1500</mtu>
<gatewayAddress>$($config.edge.uplink.gateway)</gatewayAddress>
</defaultRoute>
</staticRouting>
<ospf>
<enabled>$($config.edge.ospf.enabled)</enabled>
<ospfAreas>
<ospfArea>
<areaId>$($config.edge.ospf.area)</areaId>
<type>$($config.edge.ospf.type)</type>
</ospfArea>
<ospfArea>
<areaId>0</areaId>
<type>normal</type>
</ospfArea>
</ospfAreas>
<ospfInterfaces>"

# Configure OSPF on the Internal (south) interface, vNIC0
if ($($config.edge.ospf.internal) -eq "true") {
$body += "<ospfInterface>
<vnic>0</vnic>
<areaId>$($config.edge.ospf.area)</areaId>
<helloInterval>10</helloInterval>
<deadInterval>40</deadInterval>
<priority>128</priority>
<cost>1</cost>
<mtuIgnore>false</mtuIgnore>
</ospfInterface>"
	}

# Configure OSPF on the Uplink (north) interface, vNIC1
if ($($config.edge.ospf.uplink) -eq "true") {
$body += "<ospfInterface>
<vnic>1</vnic>
<areaId>$($config.edge.ospf.area)</areaId>
<helloInterval>10</helloInterval>
<deadInterval>40</deadInterval>
<priority>128</priority>
<cost>1</cost>
<mtuIgnore>false</mtuIgnore>
</ospfInterface>"
	}

$body += "</ospfInterfaces>
<redistribution>
<enabled>false</enabled>
<rules />
</redistribution>
<gracefulRestart>true</gracefulRestart>
<defaultOriginate>false</defaultOriginate>
</ospf>
</routing>"

	# Configure routing on the edge
	try {$r = Invoke-WebRequest -Uri "$uri/api/4.0/edges/$edgeid/routing/config" -Body $body -Method:Put -Headers $head -ContentType "application/xml" -ErrorAction:Stop -TimeoutSec 30} catch {Failure}
	if ($r.StatusCode -match "204") {Write-Host -BackgroundColor:Black -ForegroundColor:Green "Status: Successfully applied routing config to $($config.edge.name)."}
	else {
		$body
		throw "Was not able to apply routing config to router. API status code was not 204."
		}

	# End of the $makeedge check
	}

	Write-Host -BackgroundColor:Black -ForegroundColor:Yellow "Status: Edge section completed."

#############################################################################################################################################
# Complete																																	#
#############################################################################################################################################

$endclock = (Get-Date)
$totalclock = [Math]::Round(($endclock-$startclock).totalseconds)

Write-Host -BackgroundColor:Black -ForegroundColor:Green "Status: Environment created in $totalclock seconds"

	} # End of process
} # End of function

function Failure {
	$global:helpme = $body
	$global:helpmoref = $moref
	$global:result = $_.Exception.Response.GetResponseStream()
	$global:reader = New-Object System.IO.StreamReader($global:result)
	$global:responseBody = $global:reader.ReadToEnd();
	Write-Host -BackgroundColor:Black -ForegroundColor:Red "Status: A system exception was caught."
	Write-Host -BackgroundColor:Black -ForegroundColor:Red $global:responsebody
	Write-Host -BackgroundColor:Black -ForegroundColor:Red "The request body has been saved to `$global:helpme"
	break
}