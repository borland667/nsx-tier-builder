cls

# Manually defined variables
$vcenter = "vcenter.glacier.local"
$nsx = "nsx.glacier.local"
$jsonpath = "W:\Code\scripts\VMware NSX\prod-tier.json"

# Secure credentials
if (-not $vcentercreds) {$vcentercreds = Get-Credential -Message "vCenter Credentials"}
if (-not $nsxcreds) {$nsxcreds = Get-Credential -UserName "admin" -Message "NSX Credentials"}

# Create NSX authorization string and store in $head
$auth = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("admin:"+$($nsxcreds.GetNetworkCredential().password)))
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
Connect-VIServer -Server vcenter -Credential $vcentercreds | Out-Null
$moref = @{}
$moref.Add("datacenter",(Get-Datacenter $config.vsphere.datacenter | Get-View).MoRef.Value)
$moref.Add("cluster",(Get-Cluster $config.vsphere.cluster | Get-View).MoRef.Value)
$moref.Add("rp",(Get-ResourcePool -Location (Get-Cluster $config.vsphere.cluster) | Get-View).MoRef.Value)
$moref.Add("datastore",(Get-Datastore $config.vsphere.datastore | Get-View).MoRef.Value)
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

# Create switches

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
	
	Write-Host -BackgroundColor:Black -ForegroundColor:Yellow "Status: Switch creation completed."

# Create router

	# Make sure the router doesn't already exist
	$r = Invoke-WebRequest -Uri "$uri/api/4.0/edges" -Headers $head -ContentType "application/xml" -ErrorAction:Stop
	[xml]$rxml = $r.Content
	foreach ($_ in $rxml.pagedEdgeList.edgePage.edgeSummary) {if ($_.name -eq $config.router.name) {throw "The router already exists. Halting script."}}

	# Get virtualwire ID for switches
	# Note: We can't assume that this script built the switches above, so let's query the API again now that all switches exist
	$r = Invoke-WebRequest -Uri "$uri/api/2.0/vdn/virtualwires" -Headers $head -ContentType "application/xml" -ErrorAction:Stop
	[xml]$rxml = $r.Content
	$switchvwire = @{}
	foreach ($_ in $rxml.virtualWires.dataPage.virtualWire) {
		$switchvwire.Add($_.name,$_.objectId)
		}
	
	# Start a new body for the XML payload (bleh to XML!)
	[string]$body = "<edge>
<datacenterMoid>$($moref.datacenter)</datacenterMoid>
<name>$($config.router.name)</name>
<fqdn>$($config.router.name)</fqdn>
<appliances>
<applianceSize>compact</applianceSize>
<appliance>
<highAvailabilityIndex>$($config.router.ha)</highAvailabilityIndex>
<resourcePoolId>$($moref.rp)</resourcePoolId>
<datastoreId>$($moref.datastore)</datastoreId>
<vmFolderId>$($moref.folder)</vmFolderId>
</appliance>
</appliances>
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
	Write-Host -BackgroundColor:Black -ForegroundColor:Yellow "Status: Sending POST to API for the router. This may take a few minutes."
	$r = Invoke-WebRequest -Uri "$uri/api/4.0/edges" -Body $body -Method:Post -Headers $head -ContentType "application/xml" -ErrorAction:Stop -TimeoutSec 180
	if ($r.StatusDescription -match "Created") {Write-Host -BackgroundColor:Black -ForegroundColor:Green "Status: Successfully created $($config.router.name) router."
	$routerid = ($r.Headers.get_Item("Location")).split("/") | Select-Object -Last 1
		}
	else {throw "Was not able to create router. API status description was not `"created`""}
	
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
	
	# Put the routing on the router (yo dawg)
	$r = Invoke-WebRequest -Uri "$uri/api/4.0/edges/$routerid/routing/config" -Body $body -Method:Put -Headers $head -ContentType "application/xml" -ErrorAction:Stop -TimeoutSec 30
	if ($r.StatusCode -match "204") {Write-Host -BackgroundColor:Black -ForegroundColor:Green "Status: Successfully applied routing config to $($config.router.name)."}
	else {throw "Was not able to apply routing config to router. API status code was not 204."}

# Create edge