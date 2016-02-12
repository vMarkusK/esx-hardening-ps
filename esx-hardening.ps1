#############################################################################  
# ESXi Hardening Script 
# Written by Markus Kraus
# Version 1.1, 02.2016  
#  
# https://mycloudrevolution.wordpress.com/ 
#  
# Changelog:  
# 2016.01 ver 1.0 Base Release  
# 2016.02 ver 1.1   
#  
#  
##############################################################################  

## Preparation
# Load Snapin (if not already loaded)
if (!(Get-PSSnapin -name VMware.VimAutomation.Core -ErrorAction:SilentlyContinue)) {
	if (!(Add-PSSnapin -PassThru VMware.VimAutomation.Core)) {
		# Error out if loading fails
		write-host "`nFATAL ERROR: Cannot load the VIMAutomation Core Snapin. Is the PowerCLI installed?`n"
		exit
	}
}

## Global
$mgmtServices = @("sshClient","webAccess")
## Inputs
# Menue
$MenueForegroundcolor = "Black"
Write-Host `n"ESXi Hardening Module" -ForeGroundColor $MenueForegroundcolor
Write-Host `n"Type 'q' or hit enter to drop to shell"`n
Write-Host -NoNewLine "<" -foregroundcolor $MenueForegroundcolor
Write-Host -NoNewLine "ESXi or vCenter Connection?"
Write-Host -NoNewLine ">" -foregroundcolor $MenueForegroundcolor
Write-Host -NoNewLine "["
Write-Host -NoNewLine "A" -foregroundcolor $MenueForegroundcolor
Write-Host -NoNewLine "]"

Write-Host -NoNewLine `t`n "A1 - " -foregroundcolor $MenueForegroundcolor
Write-host -NoNewLine "vCenter"
Write-Host -NoNewLine `t`n "A2 - " -foregroundcolor $MenueForegroundcolor
Write-host -NoNewLine "ESXi"

$sel = Read-Host "Which option?"

# Connections
[System.Reflection.Assembly]::LoadWithPartialName('Microsoft.VisualBasic') | Out-Null
Switch ($sel) {
    "A1" {
	$vCenter = [Microsoft.VisualBasic.Interaction]::InputBox("vCenter Host FQDN or IP", "Host", "vCenter.test.lab")
	$HostExclude = [Microsoft.VisualBasic.Interaction]::InputBox("ESXi Hosts to exclude", "WildCard", "esx01") 
	# Start vCenter Connection
	Write-Host "Starting to Process vCenter Connection to " $vCenter " ..."-ForegroundColor Magenta
	$OpenConnection = $global:DefaultVIServers | where { $_.Name -eq $vCenter }
	if($OpenConnection.IsConnected) {
		Write-Host "vCenter is Already Connected..." -ForegroundColor Yellow
		$VIConnection = $OpenConnection
	} else {
		Write-Host "Connecting vCenter..."
		$VIConnection = Connect-VIServer -Server $vCenter
	}

	if (-not $VIConnection.IsConnected) {
		Write-Error "Error: vCenter Connection Failed"
    	Exit
	}
	# End vCenter Connection

	$ESXiHostList = Get-VMHost | Where-Object {$_.Name -notmatch $HostExclude}
	}
    "A2" {
	$ESXiHost = [Microsoft.VisualBasic.Interaction]::InputBox("ESXi Host FQDN or IP", "Host", "esx01.test.lab") 
	$trash = Connect-VIServer $ESXiHost
	$ESXiHostList = Get-VMHost
	}
}

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

        $SSHenaled = $Variable.Config.SSH.Enabled
        Write-Host "Enabling SSH: $SSHenaled" -ForegroundColor DarkGray
        $SSHTimeout = $Variable.Config.SSH.Timeout
        Write-Host "SSH Tmeout: $SSHTimeout" -ForegroundColor DarkGray

        $SyslogEnaled = $Variable.Config.Syslog.Enabled
        Write-Host "Enabling Syslog: $SyslogEnaled" -ForegroundColor DarkGray
        $SyslogServer = $Variable.Config.Syslog.Server
        Write-Host "Syslog Server: $SyslogServer" -ForegroundColor DarkGray


        $SNMP_NET = ($Variable.Config.Variable | Where-Object {$_.Name -eq "SNMP_NET"}).Value
        Write-Host "Firewall SNMP Network: $SNMP_NET" -ForegroundColor DarkGray
        $MGMT_NET = ($Variable.Config.Variable | Where-Object {$_.Name -eq "MGMT_NET"}).Value
        Write-Host "Firewall MGMT Network (SSH, vSphere Client): $MGMT_NET" -ForegroundColor DarkGray
    }


## Execute
foreach ($ESXiHost in $ESXiHostList){
    # Configure NTP
    Write-Host "NTP Configuration on $ESXiHost started..." -ForegroundColor Green
    $ESXiHost | Add-vmhostntpserver -ntpserver $NTP1  -confirm:$False -ErrorAction SilentlyContinue
    $ESXiHost | Add-vmhostntpserver -ntpserver $NTP2  -confirm:$False -ErrorAction SilentlyContinue
    $ntpservice = $ESXiHost | get-vmhostservice | Where-Object {$_.key -eq "ntpd"} 
    Set-vmhostservice -HostService $ntpservice -Policy "on" -confirm:$False | Out-Null
    $hosttimesystem = get-view $ESXiHost.ExtensionData.ConfigManager.DateTimeSystem 
    $hosttimesystem.UpdateDateTime([DateTime]::UtcNow) 
    start-vmhostservice -HostService $ntpservice -confirm:$False | Out-Null
    Write-Host "NTP Configuration on $ESXiHost finished..." -ForegroundColor Green

    # Report Services with Enabled Incomming Port Exceptions
    Write-Host "Services on $ESXiHost with Enabled Incomming Port Exceptions:" -ForegroundColor Green
    $ESXiHost| Get-VMHostFirewallException | where {$_.Enabled -eq "True" -and $_.IncomingPorts -ne ""} | Out-Default

    $esxcli = Get-EsxCli -VMHost $ESXiHost
    # SNMP
    Try {
        Write-Host "Configuring Firewall SNMP Strict Exception on $ESXiHost started..." -ForegroundColor Green
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
        Write-Host "Configuring Firewall SNMP IP Exception on $ESXiHost started..." -ForegroundColor Green
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
    # mgmtServices
    foreach ($mgmtService in $mgmtServices){
        Try {
            Write-Host "Configuring Firewall $mgmtService Strict Exception on $ESXiHost started..." -ForegroundColor Green
            $esxcli.network.firewall.ruleset.set($false,$true,$mgmtService)
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
            Write-Host "Configuring Firewall $mgmtService IP Exception on $ESXiHost started..." -ForegroundColor Green
            $esxcli.network.firewall.ruleset.allowedip.add($MGMT_NET,$mgmtService) 
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
# SSH Service
    if ($SSHenaled -eq "True"){
        #Enable SSH and disable SSH Warning
        Write-Host "Configuring SSH Service on $ESXiHost started..." -ForegroundColor Green
        $SSHService = $ESXiHost | Get-VMHostService | where {$_.Key -eq 'TSM-SSH'} 
        Start-VMHostService -HostService $SSHService -Confirm:$false | Out-Null
        Set-VMHostService -HostService $SSHService -Policy Automatic | Out-Null
        Get-AdvancedSetting -Entity $ESXiHost.name -Name UserVars.SuppressShellWarning | Set-AdvancedSetting -Value 1 -Confirm:$false | Out-Null
        Get-AdvancedSetting -Entity $ESXiHost.name -Name UserVars.ESXiShellInteractiveTimeOut | Set-AdvancedSetting -Value $SSHTimeout -Confirm:$fals | Out-Null
        Get-AdvancedSetting -Entity $ESXiHost.name -Name UserVars.ESXiShellTimeOut | Set-AdvancedSetting -Value $SSHTimeout -Confirm:$fals | Out-Null
        }
        else{
        #Disabling SSH and Enabling SSH Warning
        Write-Host "Configuring SSH Service on $ESXiHost started..." -ForegroundColor Green
        $SSHService = $ESXiHost | Get-VMHostService | where {$_.Key -eq 'TSM-SSH'} 
        Stop-VMHostService -HostService $SSHService -Confirm:$false | Out-Null
        Set-VMHostService -HostService $SSHService -Policy Off | Out-Null
        Get-AdvancedSetting -Entity $ESXiHost.name -Name UserVars.SuppressShellWarning | Set-AdvancedSetting -Value 0 -Confirm:$false | Out-Null
        }
# Syslog Servcice
    if ($Syslogenaled -eq "True"){
        #Enabling Syslog and Configuring
        Write-Host "Configuring Syslog Service on $ESXiHost started..." -ForegroundColor Green
        $ESXiHost | Get-VMHostFirewallException |?{$_.Name -eq 'syslog'} | Set-VMHostFirewallException -Enabled:$true | Out-Null
        Get-AdvancedSetting -Entity $ESXiHost.name -Name Syslog.global.logHost | Set-AdvancedSetting -Value $SyslogServer -Confirm:$false | Out-Null
        }
        else{
        #Disabling Syslog
        Write-Host "Disabling Syslog Service on $ESXiHost started..." -ForegroundColor Green
        $ESXiHost | Get-VMHostFirewallException |?{$_.Name -eq 'syslog'} | Set-VMHostFirewallException -Enabled:$false | Out-Null
        Get-AdvancedSetting -Entity $ESXiHost.name -Name Syslog.global.logHost | Set-AdvancedSetting -Value "" -Confirm:$false | Out-Null
        }
    
}
Disconnect-VIServer -Force -Confirm:$false

