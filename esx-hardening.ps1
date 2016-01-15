## Preparation
# Load SnapIn
if (!(get-pssnapin -name VMware.VimAutomation.Core -erroraction silentlycontinue)) {
    add-pssnapin VMware.VimAutomation.Core
}
# Inputs
[System.Reflection.Assembly]::LoadWithPartialName('Microsoft.VisualBasic') | Out-Null
$HostList = [Microsoft.VisualBasic.Interaction]::InputBox("ESXi Hosts FQDN or IP", "Hosts", "esx01.test.lab") 
$ESXiHostList = Get-VMHost -Name $HostList

# Read XML
$Validate = $true
If (Test-Path ".\Config.xml") {
        try {$Variable = [XML] (Get-Content ".\Config.xml")} catch {$Validate = $false;Write-Host "Invalid Config.xml" -ForegroundColor Red}
    } Else {
        $Validate = $false
        Write-Host "Missing Config.xml" -ForegroundColor Red
    }
If ($Validate) {
        Write-Host "Reading XML Inputs:" -ForegroundColor Green
        $NTP1 = $Variable.Config.NTP.First
        $NTP2 = $Variable.Config.NTP.Second
        Write-Host "NTP List: $NTP1, $NTP2" -ForegroundColor DarkGray

        $SNMP_NET = ($Variable.Config.Variable | Where-Object {$_.Name -eq "SNMP_NET"}).Value
        Write-Host "Firewall SNMP Network: $SNMP_NET" -ForegroundColor DarkGray
    }



foreach ($ESXiHost in $ESXiHostList){
# Configure NTP
Write-Host "NTP Configuration on $ESXiHost started..." -ForegroundColor Green
$ESXiHost | add-vmhostntpserver -ntpserver $NTP1  -confirm:$False -ErrorAction SilentlyContinue
$ESXiHost | add-vmhostntpserver -ntpserver $NTP2  -confirm:$False -ErrorAction SilentlyContinue
$ntpservice = $ESXiHost | get-vmhostservice | Where-Object {$_.key -eq "ntpd"} 
Set-vmhostservice -HostService $ntpservice -Policy "on" -confirm:$False | Out-Null
$hosttimesystem = get-view $ESXiHost.ExtensionData.ConfigManager.DateTimeSystem 
$hosttimesystem.UpdateDateTime([DateTime]::UtcNow) 
start-vmhostservice -HostService $ntpservice -confirm:$False | Out-Null
Write-Host "NTP Configuration on $ESXiHost.Name finished..." -ForegroundColor Green

# Report Services with Enabled Incomming Port Exceptions
Write-Host "Services on $ESXiHost.Name with Enabled Incomming Port Exceptions:" -ForegroundColor Green
$ESXiHost| Get-VMHostFirewallException | where {$_.Enabled -eq "True" -and $_.IncomingPorts -ne ""} | Out-Default

$esxcli = Get-EsxCli -VMHost $ESXiHost
Try {
        Write-Host "Configuring Firewall SNMP Strict Exception..." -ForegroundColor Green
        $esxcli.network.firewall.ruleset.set($false,$true,'snmp')
        }

        Catch {
        
            Switch -Wildcard ($_.Exception)
                {
                "*Already use allowed ip list*"
                {Write-Host "...Already use allowed ip list" -ForegroundColor Yellow}

                Default
                { Write-Host $_.Exception -ForegroundColor Red}
                }
            }
Try {
        Write-Host "Configuring Firewall SNMP IP Exception..." -ForegroundColor Green
        $esxcli.network.firewall.ruleset.allowedip.add($SNMP_NET,'snmp') 
        }

        Catch {
        
            Switch -Wildcard ($_.Exception)
                {
                "*Ip address already exist*"
                {Write-Host "...Ip address already exist" -ForegroundColor Yellow}

                Default
                { Write-Host $_.Exception -ForegroundColor Red}
                }
            }



}

