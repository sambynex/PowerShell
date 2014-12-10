<#
.DESCRIPTION
	Detect missing checks automatically.
	Add or report according to script settings.
   
.AUTHOR
   Hugo L. Klemmestad <hugo@klemmestad.com>
.DATE
   23.05.2014
#>



## SETTINGS
# A few settings are handled as parameters 
param (	
	[switch]$All = $false,
	[switch]$ReUid = $false, # For when this script as messed up your monitoring configuration
	[switch]$Apply = $false, # -Apply will write new checks to configfiles and reload agent
	[switch]$Replace = $false, # Automated task only: -Replace will dump any existing checks if -Apply is used
	[switch]$ReportMode = $true, # -ReportMode will report missing checks, but not fail the script
	[switch]$Performance = $false, # Set to $false if you do not want performance checks
	[switch]$PingCheck = $false, # This is useful on a Fault History report. Otherwise useless.
	[switch]$MSSQL = $false, # Detect SQL servers
	[switch]$SMART = $false, # Enable physical disk check if SMART status is available
	[switch]$Backup = $false, # Configure a basic backup check if a compatible product is recognized
	[switch]$Antivirus = $false, # Configure an Antivirus check if a compatible product is recognized	
	[switch]$LogChecks = $false, # Configure default log checks
	[string]$DriveSpaceCheck = $null, # Freespace as number+unit, i.e 10%, 5GB or 500MB
	[string]$WinServiceCheck = "", # "All" or "DefaultOnly". 
	[string]$DiskSpaceChange = $null, # percentage as integer
	[string]$ServerInterval = "5", # 5 or 15 minutes
	[string]$PCInterval = "30", # 30 or 60 minutes
	[string]$DSCHour = "8", # When DSC check should run in whole hours. Minutes not supported by agent.
	[string]$WeekDay = "7" # When configuration should be updated.
)

If ($All)
{
	## DEFAULT CHECKS
	$Performance = $false # Set to $false if you do not want performance checks
	$PingCheck = $false # This is useful on a Fault History report. Otherwise useless.
	$MSSQL = $true # Detect SQL servers
	$SMART = $true # Enable physical disk check if SMART status is available
	$Antivirus = $true # Configure an Antivirus check if a compatible product is recognized
	$DriveSpaceCheck = "10%" # Freespace as number+unit, i.e 10%, 5GB or 500MB
	$WinServiceCheck = "All" # "All" or "Default". 
	$DiskSpaceChange = 10 # percentage as integer
	$Backup = $false # Try to configure Backup Monitoring
	$LogChecks = $false # Configure default eventlog checks
}

# Force the script to output something to STDOUT, else errors may cause script timeout.
Write-Host " "

$DefaultLogChecks = @(
	@{ "checktype" = "EventLogCheck";
	   "uid" = "";
	   "log" = "Application|Application Hangs"; # Application log | Human readable name
	   "flags" = 32512;
	   "ids" = "*";
	   "source" = "Application Hang";
	   "contains" = "";
	   "exclude" = "";
	   "ignoreexclusions" = "" }
	@{ "checktype" = "EventLogCheck";
	   "uid" = "";
	   "log" = "System|NTFS Errors";
	   "flags" = 32513;
	   "ids" = "*";
	   "source" = "Ntfs*";
	   "contains" = "";
	   "exclude" = "";
	   "ignoreexclusions" = "" }
	@{ "checktype" = "EventLogCheck";
	   "uid" = "";
	   "log" = "System|BSOD Stop Errors";
	   "flags" = 32513;
	   "ids" = "1003";
	   "source" = "System";
	   "contains" = "";
	   "exclude" = "";
	   "ignoreexclusions" = "" }
)	   

$DefaultCriticalEvents = @(
	@{ "checktype" = "CriticalEvents";
	   "eventlog" = "Directory Service";
	   "mode" = 1;
	   "option" = 0 }
	@{ "checktype" = "CriticalEvents";
	   "eventlog" = "File Replication Service";
	   "mode" = 1;
	   "option" = 0 }
	@{ "checktype" = "CriticalEvents";
	   "eventlog" = "HardwareEvents";
	   "mode" = 1;
	   "option" = 0 }
	@{ "checktype" = "CriticalEvents";
	   "eventlog" = "System";
	   "mode" = 0;
	   "option" = 0 }
	@{ "checktype" = "CriticalEvents";
	   "eventlog" = "Application";
	   "mode" = 0;
	   "option" = 0 }
)

$DefaultPerfChecks = @(
	@{ "checktype" = "PerfCounterCheck";
	   "type" = "1"; # Processor Queue Length
	   "threshold1" = "2" } # Recommended threshold by Microsoft for physical servers.
	@{ "checktype" = "PerfCounterCheck";
	   "type" = "2"; # Average CPU Usage
	   "threshold1" = "100" } # We are talking ALERTS here. We are not doing this for fun.
	@{ "checktype" = "PerfCounterCheck";
	   "type" = "3"; # Memory
	   "instance" = "2" ; # Fails if committed memory is more than twice that of physical RAM
	   "threshold1" = "10" ; # Fails if average available RAM is less than 10 MB
	   "threshold2" = "5000"; # Fails if average pages/sec > 5000
	   "threshold3" = "100"; # % Page file usage
	   "threshold4" = "128" } # Nonpaged pool will be double this on 64-bit systems
	@{ "checktype" = "PerfCounterCheck";
	   "type" = "4"; # Network interfaces
	   "instance" = ""; # Must be populated from system
	   "threshold1" = "80"; } # We don't want alerts unless there really are problems 
	@{ "checktype" = "PerfCounterCheck";
	   "type" = "5"; # Harddisk checks
	   "instance" = ""; # Must be populated from system
	   "threshold1" = "2"; # Read queue
	   "threshold2" = "2"; # Write queue
	   "threshold3" = "100" } # Disk time, and again we are talking ALERTS
)

$DoNotMonitorServices = @( # Services you do not wish to monitor, regardless
	"wuauserv", # Windows Update Service. Does not run continously.
	"gpupdate", # Google Update Service. Does not always run.
	"AdobeARMservice" # Another service you may not want to monitor
)
$AlwaysMonitorServices = @( # Services that always are to be monitored if present and autorun
	"wecsvc" # Windows Event Collector
)
	

## VARIUS FUNCTIONS
# Return an array of values from an array of XML Object
function Get-GFIMAXChecks ($xmlArray, $property) {
	$returnArray = @()
	foreach ($element in $xmlArray){
		If ($element.$property -is [System.Xml.XmlElement]){
			$returnArray += $element.$property.InnerText
		} Else{
			$returnArray += $element.$property
		}
	}
	If ($returnArray) {
		Return $returnArray
	}
}


# Downloaded from 
# http://blogs.technet.com/b/heyscriptingguy/archive/2011/08/20/use-powershell-to-work-with-any-ini-file.aspx
# modified to use ordered list by me
function Get-IniContent ($filePath) {
    $ini = New-Object System.Collections.Specialized.OrderedDictionary
    switch -regex -file $FilePath
    {
        "^\[(.+)\]" # Section
        {
			$section = $matches[1]
            $ini[$section] = New-Object System.Collections.Specialized.OrderedDictionary
            $CommentCount = 0
        }
        "^(;.*)$" # Comment
        {
            $value = $matches[1]
            $CommentCount = $CommentCount + 1
            $name = "Comment" + $CommentCount
            $ini[$section][$name] = $value
        } 
        "(.+?)\s*=(.*)" # Key
        {
            $name,$value = $matches[1..2]
            $ini[$section][$name] = $value
        }
    }
    return $ini
}
# Downloaded from 
# http://blogs.technet.com/b/heyscriptingguy/archive/2011/08/20/use-powershell-to-work-with-any-ini-file.aspx
# Modified to force overwrite by me
function Out-IniFile($InputObject, $FilePath) {
    $outFile = New-Item -ItemType file -Path $Filepath -Force
    foreach ($i in $InputObject.keys)
    {
        if ("Hashtable","OrderedDictionary" -notcontains $($InputObject[$i].GetType().Name))
        {
            #No Sections
            Add-Content -Path $outFile -Value "$i=$($InputObject[$i])"
        } else {
            #Sections
            Add-Content -Path $outFile -Value "[$i]"
            Foreach ($j in ($InputObject[$i].keys | Sort-Object))
            {
                if ($j -match "^Comment[\d]+") {
                    Add-Content -Path $outFile -Value "$($InputObject[$i][$j])"
                } else {
                    Add-Content -Path $outFile -Value "$j=$($InputObject[$i][$j])" 
                }

            }
            Add-Content -Path $outFile -Value ""
        }
    }
}

# Small function to give missing checks output some structure
function Format-Output($CheckTable) {
	$Result = @()
	Foreach ($CheckItem in $CheckTable){
		Switch ($CheckItem.checktype)	{
			{"DriveSpaceCheck","DiskSpaceChange" -contains $_ } {
				$Result += $CheckItem.checktype + "  " + $CheckItem.driveletter }
			"WinServicecheck" {
				$Result += $CheckItem.checktype + " " + $CheckItem.servicename }
			"PerfCounterCheck" { 
				Switch ($CheckItem.type) {
					"1" { $Result += $CheckItem.checktype + " Processor Queue Length"}
					"2" { $Result += $CheckItem.checktype + " Average CPU Usage"}
					"3" { $Result += $CheckItem.checktype + " Memory Usage"}
					"4" { $Result += $CheckItem.checktype + " Network Interface " + $CheckItem.instance}
					"5" { $Result += $CheckItem.checktype + " Physical Disk " + $CheckItem.instance}
				}}
			{"PingCheck","AVUpdateCheck","BackupCheck","FileSizeCheck" -contains $_ } {
				$Result += $CheckItem.checktype + " " + $CheckItem.name }
			"EventLogCheck" {
				$Result += $CheckItem.checktype + " " + $CheckItem.log }
			"CriticalEvents" {
				switch ($CheckItem.mode) { 
					0 { $Result += $CheckItem.checktype + " " + $CheckItem.eventlog + " (Report)" }
					1 { $Result += $CheckItem.checktype + " " + $CheckItem.eventlog + " (Alert)" }}}
			default { 
				$Result += $CheckItem.checktype }

		}
		
	}
	$Result
}

## Adopted from https://gallery.technet.microsoft.com/scriptcenter/Get-SQLInstance-9a3245a0
## I changed it to check both 32 and 64 bit
Function Get-SQLInstance {
	$Computer = $env:COMPUTERNAME
	Try { 
	    $reg = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey('LocalMachine', $Computer) 
	    $baseKeys = "SOFTWARE\\Microsoft\\Microsoft SQL Server",
	    "SOFTWARE\\Wow6432Node\\Microsoft\\Microsoft SQL Server"
		ForEach ($basekey in $baseKeys)
		{
		    If ($reg.OpenSubKey($basekey)) {
		        $regPath = $basekey
		    } Else {
		        Continue
		    }
		    $regKey= $reg.OpenSubKey("$regPath")
		    If ($regKey.GetSubKeyNames() -contains "Instance Names") {
		        $regKey= $reg.OpenSubKey("$regpath\\Instance Names\\SQL" ) 
		        $instances = @($regkey.GetValueNames())
		    } ElseIf ($regKey.GetValueNames() -contains 'InstalledInstances') {
		        $isCluster = $False
		        $instances = $regKey.GetValue('InstalledInstances')
		    } Else {
		        Continue
		    }
		    If ($instances.count -gt 0) { 
		        ForEach ($instance in $instances) {
		            $nodes = New-Object System.Collections.Arraylist
		            $clusterName = $Null
		            $isCluster = $False
		            $instanceValue = $regKey.GetValue($instance)
		            $instanceReg = $reg.OpenSubKey("$regpath\\$instanceValue")
		            If ($instanceReg.GetSubKeyNames() -contains "Cluster") {
		                $isCluster = $True
		                $instanceRegCluster = $instanceReg.OpenSubKey('Cluster')
		                $clusterName = $instanceRegCluster.GetValue('ClusterName')
		                $clusterReg = $reg.OpenSubKey("Cluster\\Nodes")                            
		                $clusterReg.GetSubKeyNames() | ForEach {
		                    $null = $nodes.Add($clusterReg.OpenSubKey($_).GetValue('NodeName'))
		                }
		            }
		            $instanceRegSetup = $instanceReg.OpenSubKey("Setup")
		            Try {
		                $edition = $instanceRegSetup.GetValue('Edition')
		            } Catch {
		                $edition = $Null
		            }
		            Try {
		                $ErrorActionPreference = 'Stop'
		                #Get from filename to determine version
		                $servicesReg = $reg.OpenSubKey("SYSTEM\\CurrentControlSet\\Services")
		                $serviceKey = $servicesReg.GetSubKeyNames() | Where {
		                    $_ -match "$instance"
		                } | Select -First 1
		                $service = $servicesReg.OpenSubKey($serviceKey).GetValue('ImagePath')
		                $file = $service -replace '^.*(\w:\\.*\\sqlservr.exe).*','$1'
		                $version = (Get-Item ("\\$Computer\$($file -replace ":","$")")).VersionInfo.ProductVersion
		            } Catch {
		                #Use potentially less accurate version from registry
		                $Version = $instanceRegSetup.GetValue('Version')
		            } Finally {
		                $ErrorActionPreference = 'Continue'
		            }
		            New-Object PSObject -Property @{
		                Computername = $Computer
		                SQLInstance = $instance
		                Edition = $edition
						BitVersion = {Switch -regex ($basekey) {
							"Wow6432Node" { '32-bit' }
							Default { '64-bit' }
						}}.InvokeReturnAsIs()
		                Version = $version
		                Caption = {Switch -Regex ($version) {
		                    "^14" {'SQL Server 2014';Break}
		                    "^11" {'SQL Server 2012';Break}
		                    "^10\.5" {'SQL Server 2008 R2';Break}
		                    "^10" {'SQL Server 2008';Break}
		                    "^9"  {'SQL Server 2005';Break}
		                    "^8"  {'SQL Server 2000';Break}
		                    Default {'Unknown'}
		                }}.InvokeReturnAsIs()
		                isCluster = $isCluster
		                isClusterNode = ($nodes -contains $Computer)
		                ClusterName = $clusterName
		                ClusterNodes = ($nodes -ne $Computer)
		                FullName = {
		                    If ($Instance -eq 'MSSQLSERVER') {
		                        $Computer
		                    } Else {
		                        "$($Computer)\$($instance)"
		                    }
		                }.InvokeReturnAsIs()
						FullRecoveryModel = ""
		            }
		        }
		    }
		}
	} Catch { 
	    Write-Warning ("{0}: {1}" -f $Computer,$_.Exception.Message)
	}
}

## SETUP ENVIRONMENT
# Find "Advanced Monitoring Agent" service and use path to locate files
$gfimaxagent = Get-WmiObject Win32_Service | Where-Object { $_.Name -eq 'Advanced Monitoring Agent' }
$gfimaxexe = $gfimaxagent.PathName
$gfimaxpath = Split-Path $gfimaxagent.PathName.Replace('"',"") -Parent

# XML Document objects
$247_config = New-Object -TypeName XML
$DSC_config = New-Object -TypeName XML
$ST_Config = New-Object -TypeName XML
$AgentConfig = New-Object -TypeName XML
$DeviceConfig = New-Object -TypeName XML

# XML Document Pathnames
$247file = $gfimaxpath + "\247_Config.xml"
$DSCfile = $gfimaxpath + "\DSC_Config.xml"
$STfile = $gfimaxpath + "\ST_Config.xml"
$AgentFile = $gfimaxpath + "\agentconfig.xml"
$DeviceFile = $gfimaxpath + "\Config.xml"

$IniFile = $gfimaxpath + "\settings.ini"
$ConfigChanged = $false
$settingsChanged = $false

# Read ini-files
$settingsContent = Get-IniContent($IniFile)
$servicesContent = Get-IniContent($gfimaxpath + "\services.ini")

# First of all, check if it is safe to make any changes
If ($Apply) {
	# Make sure a failure to aquire settings correctly will disable changes
	$Apply = $false
	If ($settingsContent["DAILYSAFETYCHECK"]["RUNTIME"]) { # This setting must exist
		$lastRuntime = $settingsContent["DAILYSAFETYCHECK"]["RUNTIME"]
		[int]$currenttime = $((Get-Date).touniversaltime() | get-date -UFormat %s) -replace ",","." # Handle decimal comma 
		$timeSinceLastRun = $currenttime - $lastRuntime
		If($lastRuntime -eq 0 -or $timeSinceLastRun -gt 360){
			# If we have never been run or it is at least 6 minutes ago
			# enable changes again
			$Apply = $true
		}
	}
	If (!($Apply)) {
		Write-Host "CHANGES APPLIED - Verifying changes:"
	}
}


# Read configuration of checks. Create them if they do not exist yet.
If (Test-Path $247file) { 
	$247_Config.Load($247file)
	$247_Config.DocumentElement.SetAttribute("modified","1")
} Else { 
	$decl = $247_Config.CreateXmlDeclaration("1.0", "ISO-8859-1", $null)
	$rootNode = $247_Config.CreateElement("checks")
	$result = $rootNode.SetAttribute("modified", "1")
	$result = $247_Config.InsertBefore($decl, $247_Config.DocumentElement)
	$result = $247_Config.AppendChild($rootNode)
	$uid = 1
}

If (Test-Path $DSCfile) { 
	$DSC_Config.Load($DSCfile)
	$DSC_Config.DocumentElement.SetAttribute("modified","1")
} Else { 
	$decl = $DSC_config.CreateXmlDeclaration("1.0", "ISO-8859-1", $null)
	$rootNode = $DSC_Config.CreateElement("checks")
	$result = $rootNode.SetAttribute("modified", "1")
	$result = $DSC_config.InsertBefore($decl, $DSC_config.DocumentElement)
	$result = $DSC_config.AppendChild($rootNode)
}

# Read agent config
$AgentConfig.Load($AgentFile)

# Read autodetected machine info
$DeviceConfig.Load($DeviceFile)

# Get next available UID from INI file
# $uid = [int]$settingsContent["GENERAL"]["NEXTCHECKUID"]
# Ini file cannot be trusted if script checks are being used
If (Test-Path $STfile) {
	$ST_Config.Load($STfile)
}

$MaxUid = get-gfimaxchecks @($($247_Config.checks.ChildNodes | select uid) + $($DSC_Config.checks.ChildNodes| select uid) + $($ST_Config.checks.ChildNodes| select uid)) "uid" | measure -Maximum
$InUseUid = $MaxUid.Maximum + 1

$SettingsUid = $settingsContent["GENERAL"]["NEXTCHECKUID"]

If($SettingsUid -gt $InUseUid) {
	[int]$uid = $SettingsUid
} Else {
	[int]$uid = $InUseUid
}

If ($ReUid) {
	# So, we have messed up your configuration files? We will try to fix them...
	ForEach ($Check in @($247_Config.checks.ChildNodes + $DSC_Config.checks.ChildNodes)){
		$Check.SetAttribute("uid",$uid)
		$uid++
	}
}

# The UID problems caused trouble with web protection check. But it can be fixed.
#$WebProtection = @($247_Config.checks.wpcategorycounternotificationcheck)
#If ($WebProtection.Count -gt 1)
#{
#	$MinUid = (Get-GFIMAXChecks ($WebProtection | select uid) "uid" | Measure -Minimum).minimum
#	$WrongCheck = $247_Config.checks.SelectSingleNode("wpcategorycounternotificationcheck[@uid=$MinUid]")
#	$null = $247_Config.checks.RemoveChild($WrongCheck)
#	$ConfigChanged = $true
#}


# Check Agent mode, workstation or server
$AgentMode = $AgentConfig.agentconfiguration.agentmode

# Set interval according to $AgentMode
If ($AgentMode = "server") { $247Interval = $ServerInterval }
Else { $247Interval = $PCInterval }

# Check if INI file is correct
If ($settingsContent["247CHECK"]["ACTIVE"] -ne "1") {
	$settingsContent["247CHECK"]["ACTIVE"] = "1"
	$ConfigChanged = $true
	$settingsChanged = $true
}

If ($settingsContent["247CHECK"]["INTERVAL"] -ne $247Interval) {
	$settingsContent["247CHECK"]["INTERVAL"] = $247Interval
	$ConfigChanged = $true
	$settingsChanged = $true
}

If ($settingsContent["DAILYSAFETYCHECK"]["ACTIVE"] -ne "1") {
	$settingsContent["DAILYSAFETYCHECK"]["ACTIVE"] = "1"
	$ConfigChanged = $true
	$settingsChanged = $true
}

If ($settingsContent["DAILYSAFETYCHECK"]["HOUR"] -ne $DSCHour) {
	$settingsContent["DAILYSAFETYCHECK"]["HOUR"] = $DSCHour
	$ConfigChanged = $true
	$settingsChanged = $true
}


# We need an array of hashes to remember which checks to add
$New247Checks = @()
$NewDSCChecks = @()

# Check for new services that we'd like to monitor'

## DISKSPACECHECK
If ($DriveSpaceCheck) {
	If ($Replace){
		Foreach ($xmlCheck in $247_config.checks.DriveSpaceCheck) {
		 	$null = $247_Config.checks.RemoveChild($xmlCheck) 
		}
	}
	# Process parameters that need processing
	$SpaceMatch = "^([0-9]+)([gmb%]+)"
	$Spacetype = $DriveSpaceCheck -replace $SpaceMatch,'$2'
	$FreeSpace = $DriveSpaceCheck -replace $SpaceMatch,'$1'

	Switch ($Spacetype.ToUpper().Substring(0,1)) { # SpaceUnits: 0 = Bytes, 1 = MBytes, 2 = GBytes, 3 = Percent
		"B" { $SpaceUnits = 0 }
		"M" { $SpaceUnits = 1 }
		"G" { $SpaceUnits = 2 }
		"%" { $SpaceUnits = 3 }
	}
	$CurrentDiskSpaceChecks = Get-GFIMAXChecks $247_Config.checks.DriveSpaceCheck "DriveLetter"
	# Get current fixed drives from WMI
	$DetectedDrives = get-gfimaxchecks (GET-WMIOBJECT -query "SELECT * from win32_logicaldisk where DriveType = '3'" | select DeviceID) "DeviceID"

	# Add any disk not currently in CurrentDiskSpaceChecks
	foreach ($Disk in $DetectedDrives) {
#		$WrongCheck = $247_Config.checks.SelectSingleNode("DriveSpaceCheck[driveletter=""$Disk""]|DriveSpaceCheck[DriveLetter=""$Disk""]")
#		If ($WrongCheck)
#		{
#			$null = $247_Config.checks.RemoveChild($WrongCheck)
#			$ConfigChanged = $true
#		}
		If (($Disk -ne $env:SystemDrive) -and ($AgentMode -eq "workstation")){
			# Workstations are only monitoring %SystemDrive%
			Continue
		}
		$DriveLetter = $Disk + "\"
		If (!($CurrentDiskSpaceChecks -Contains $DriveLetter)){
			$New247Checks += @{ "checktype" = "DriveSpaceCheck";
				"driveletter" = $DriveLetter;
				"freespace" = $FreeSpace;
				"spaceunits" = $SpaceUnits }
		}
	}
}


## DISKSPACECHANGE
#  We only use this on servers
If (($DiskSpaceChange) -and ($AgentMode -eq "server")) {
	
	If ($Replace){
		Foreach ($xmlCheck in $DSC_config.checks.DiskSpaceChange) {
		 	$null = $DSC_Config.checks.RemoveChild($xmlCheck) 
		}
	}
	$CurrentDiskSpaceChange = Get-GFIMAXChecks $DSC_Config.checks.DiskSpaceChange "DriveLetter"
	# Get current fixed drives from WM
	$DetectedDrives = get-gfimaxchecks (GET-WMIOBJECT -query "SELECT * from win32_logicaldisk where DriveType = '3'" | select DeviceID) "DeviceID"

	# Add any disk not currently in CurrentDiskSpaceChecks
	foreach ($Disk in $DetectedDrives) {
#		$WrongCheck = $DSC_Config.checks.SelectSingleNode("DiskSpaceChange[driveletter=""$Disk""]|DiskSpaceChange[DriveLetter=""$Disk""]")
#		If ($WrongCheck)
#		{
#			$null = $DSC_Config.checks.RemoveChild($WrongCheck)
#			$ConfigChanged = $true
#		}
		$DriveLetter = $Disk + "\"
		If (!($CurrentDiskSpaceChange -Contains $DriveLetter)){
			$NewDSCChecks += @{ "checktype" = "DiskSpaceChange";
				"driveletter" = $DriveLetter;
				"Threshold" = $DiskSpaceChange } 
		}
	}

}

## WINSERVICECHECK
#  By default we only monitor services on servers
# First extract all servicenames from current configuration
$MonitoredServices = @()
$MonitoredServices = Get-GFIMAXChecks $247_Config.checks.winservicecheck "servicekeyname"

#If (($MonitoredServices.count

If (("All", "Default" -contains $WinServiceCheck) -and ($AgentMode -eq "server")) {
	If ($Replace){
		Foreach ($xmlCheck in $247_config.checks.WinServiceCheck) {
		 	$null = $247_Config.checks.RemoveChild($xmlCheck) 
		}
		$MonitoredServices = @()
	}
	# An array to store names of services to monitor
	$ServicesToAdd = @()
	$ServicesToMonitor = @()

	## SERVICES TO MONITOR
	If ($WinServiceCheck -eq "Default") { # Only add services that are listed in services.ini

		# Get all currently installed services with autostart enabled from WMI
		$autorunsvc = Get-WmiObject Win32_Service |  
		Where-Object { $_.StartMode -eq 'Auto' } | select Displayname,Name
		
		Foreach ($service in $autorunsvc) {
			If (($servicesContent["SERVICES"][$service.Name] -eq "1") -or ($AlwaysMonitorServices -contains $service.Name)) {
				$ServicesToMonitor += $service.Name
			}
		}
	} 
	Else{ 
	  	# Add all services configured to autostart if pathname is outside %SYSTEMROOT%
		# if the service is currently running
		$autorunsvc = Get-WmiObject Win32_Service | 
		Where-Object { $_.StartMode -eq 'Auto' -and $_.PathName -notmatch ($env:systemroot -replace "\\", "\\") -and $_.State -eq "Running"} | select Displayname,Name
		Foreach ($service in $autorunsvc) {
			If ($DoNotMonitorServices -notcontains $service.Name){
				$ServicesToMonitor += $service.Name
			}
		}

		# Add all services located in %SYSTEMROOT% only if listed in services.ini
		$autorunsvc = Get-WmiObject Win32_Service | 
		Where-Object { $_.StartMode -eq 'Auto' -and $_.PathName -match ($env:systemroot -replace "\\", "\\") } | select Displayname,Name
		Foreach ($service in $autorunsvc) {
			If (($servicesContent["SERVICES"][$service.Name] -eq "1") -or ($AlwaysMonitorServices -contains $service.Name)) {
				$ServicesToMonitor += $service.Name
			}
		}
	}

	## SERVICES TO ADD
	Foreach ($service in $ServicesToMonitor){
		If (!($MonitoredServices -contains $service)){
			$ServicesToAdd += $service
		}
	}

	# Get a complete list of all Displaynames of services
	$autorunsvc = Get-WmiObject Win32_Service | select Displayname,Name
	Foreach ($NewService in $ServicesToAdd){
		$New247Checks += @{ "checktype" = "WinServiceCheck"; 
						 "servicename" = ($autorunsvc | Where-Object { $_.Name -eq $NewService }).DisplayName;
						 "servicekeyname" = $NewService;
						 "failcount" = 1; # How many consecutive failures before check fails
						 "startpendingok" = 0; # Is Startpending OK, 1 0 Yes, 0 = No
						 "restart" = 1; # Restart = 1 (Restart any stopped service as default)
						 "consecutiverestartcount" = 2; # ConsecutiveRestartCount = 2 (Fail if service doesnt run after 2 tries)
						 "cumulativerestartcount" = "4|24" } # Cumulative Restart Count = 4 in 24 hours
	}
}

## Detect any databases and add relevant checks
If ($MSSQL) {
	If ($Replace) {
		Foreach ($xmlCheck in $DSC_config.checks.FileSizeCheck) {
		 	$null = $DSC_Config.checks.RemoveChild($xmlCheck) 
		}
	}	
	
	# Get any SQL services registered on device
	$Instances = @(Get-SQLInstance)

	# Load SQL server management assembly
	If ($Instances.count -gt 0) {[System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.SMO') | out-null }
	
	# Get current service and filechecks
	$CurrentFileSizeChecks = Get-GFIMAXChecks $DSC_Config.checks.FileSizeCheck "include"
	
	# Loop through any services found, add service checks and locate files
	Foreach ($Instance in $Instances){
		$sqlService = Get-WmiObject Win32_Service | where { $_.DisplayName -match $instance.SQLInstance -and $_.PathName -match "sqlservr.exe"}
		If ((!($MonitoredServices -Contains $sqlService.Name)) -and (!($WinServiceCheck))){
			$New247Checks += @{ "checktype" = "WinServiceCheck"; 
						 "servicename" = $sqlService.DisplayName;
						 "servicekeyname" = $sqlService.Name;
						 "failcount" = 1; # How many consecutive failures before check fails
						 "startpendingok" = 0; # Is Startpending OK, 1 0 Yes, 0 = No
						 "restart" = 1; # Restart = 1 (Restart any stopped service as default)
						 "consecutiverestartcount" = 2; # ConsecutiveRestartCount = 2 (Fail if service doesnt run after 2 tries)
						 "cumulativerestartcount" = "4|24" } # Cumulative Restart Count = 4 in 24 hours
		}
		
		
		
		# Create a managment handle for this instance
		$sqlhandle = New-Object ('Microsoft.SqlServer.Management.Smo.Server') $Instance.FullName
		Try {
			# Retrieve any databases on instance
			$dbs = $sqlhandle.Databases 
			Foreach ($db in $dbs) {
				# Loop through logfiles and retain directory
				$locations = @()
				$logfiles = $db.LogFiles | select -ExpandProperty Filename
				If ($logfile.Count -gt 0) {
					Foreach ($logfile in $logfiles) {
						$parent = Split-Path -Parent $logfile
						If ($locations -notcontains $parent) { $locations += $parent }
					}
					Foreach ($location in $locations) {
						If (!($CurrentFileSizeChecks -Contains "0|" + $location + "|*.ldf")) {
								$NewDSCChecks += @{	"checktype" = "FileSizeCheck";
									"Name" = $instance;
									"Threshold" = "5"; "Units" = "3|0";
										# Units: 0 = Bytes, 1 = KBytes, 2 = MBytes, 3 = GBytes
										# Units, element 2: 0 = Greater Than, 1 = Less Than
									"Include" = "0|" + $location + "|*.ldf";
										# First element: 1 = Include subfolders, 0 = This folder only
										# Second element: Folder where files are located
										# Third element: File pattern
									"Exclude" = "" }# Same syntax as Include 
						}
					}
				}
				# Retrive RecoveryModel and save name if it isn't Simple
				If ($db.RecoveryModel -ne "Simple") {
					$Instance.FullRecoveryModel += $db.Name + " "
				}
			}
		} Catch {
			Write-Host ("SQL Server Detection: Access to {0} Failed" -F $Instance.FullName)
		}
	}
}



If ($Performance -and ($AgentMode -eq "server")) { # Performance monitoring is only available on servers
	If ($Replace){
		Foreach ($xmlCheck in $247_config.checks.PerfCounterCheck) {
		 	$null = $247_Config.checks.RemoveChild($xmlCheck) 
		}
	}
	Foreach ($Check in $DefaultPerfChecks){
		Switch ($Check.get_Item("type")){
			1 { $CurrentPerfChecks = Get-GFIMAXChecks $247_Config.checks.PerfCounterCheck "type"
				If(!($CurrentPerfChecks -Contains $Check.get_Item("type"))){
					$ThisDevice = Get-WmiObject Win32_ComputerSystem
					If ($ThisDevice.Model -match "^virtual|^vmware") {
						$Check.Item("threshold1") = $([int]$Check.get_Item("threshold1") * 3).ToString()
					}
					$New247Checks += $Check
				}
			}
			2 {	$CurrentPerfChecks = Get-GFIMAXChecks $247_Config.checks.PerfCounterCheck "type"
				If(!($CurrentPerfChecks -Contains $Check.get_Item("type"))){
					$New247Checks += $Check
				}
			}
			3 {	$CurrentPerfChecks = Get-GFIMAXChecks $247_Config.checks.PerfCounterCheck "type"
				If(!($CurrentPerfChecks -Contains $Check.get_Item("type"))){
					if ([System.IntPtr]::Size -gt 4) { # 64-bit
						[int]$nonpagedpool32bit = $Check.Item("threshold4")
						[int]$TotalMemory = (Get-WmiObject Win32_ComputerSystem).TotalPhysicalMemory /(1024*1024)
						[int]$nonpagedpool64bit = $Check.get_Item("threshold4")/4096*$TotalMemory
						If ($nonpagedpool64bit -gt $nonpagedpool32bit*2 ) { 	$Check.Item("threshold4") = $nonpagedpool64bit.ToString() } Else{ 	$Check.Item("threshold4") = $nonpagedpool32bit*2  }

					}
					$New247Checks += $Check
				}
			}
			4 { # Needs network interfaces
				# Don't bother on Hyper-V. The network adapters may change on a new node.
				$ThisDevice = Get-WmiObject Win32_ComputerSystem
				If ($ThisDevice.Model -notmatch "^virtual") {
					$CurrentPerfChecks = Get-GFIMAXChecks $247_Config.checks.SelectNodes("PerfCounterCheck[type=4]|PerfCounterCheck[Type=4]") "Instance"
					$NetConnections = Get-GFIMAXChecks $DeviceConfig.configuration.networkadapters "name"

					Foreach ($Adapter in $NetConnections | where {$_ -notmatch "isatap" -and $_ -notmatch "Teredo"}){
						If (!($CurrentPerfChecks -Contains $Adapter)){
							$tmpCheck = New-Object -TypeName Hashtable
							Foreach ($key in $Check.Keys) { $tmpCheck.Item($key) = $Check.get_Item($key) }
							$tmpCheck.Item("instance") = $Adapter
							$New247Checks += $tmpCheck
						}
					}
				}
			}
			5 { # Needs physical disks
				## DISKPERFORMANCECHECK
				$CurrentPerfChecks = Get-GFIMAXChecks $247_Config.checks.SelectNodes("PerfCounterCheck[type=5]|PerfCounterCheck[Type=5]") "Instance"
				$PhysicalDisks = Get-GFIMAXChecks $DeviceConfig.SelectNodes("//configuration/physicaldisks") "name"

				Foreach	($Disk in $PhysicalDisks | where {$_ -ne "_Total"}){
					If (!($CurrentPerfChecks -Contains $Disk)){
						$tmpCheck = New-Object -TypeName Hashtable
						Foreach ($key in $Check.Keys) { $tmpCheck.Item($key) = $Check.get_Item($key) }
						$tmpCheck.Item("instance") = $Disk
						$New247Checks += $tmpCheck

					}
				}
			}
		}
	}
}

if($PingCheck -and ($AgentMode -eq "server")) { # Pingcheck only supported on servers
	If ($Replace) {
		Foreach ($xmlCheck in $DSC_config.checks.PingCheck) {
		 	$null = $DSC_Config.checks.RemoveChild($xmlCheck) 
		}
	}	
	
	$CurrentPingChecks = Get-GFIMAXChecks $247_Config.checks.PingCheck "name"
	# Get the two closest IP addresses counted from device
	$trace = @()
	$trace = Invoke-Expression "tracert -d -w 10 -h 2 8.8.8.8" |
           Foreach-Object {
               if ($_ -like "*ms*" ) {
                   $chunks = $_ -split "  " | Where-Object { $_ }
                   $ip = $chunks[-1]
				   $ip = @($ip)[0].Trim() -as [IPAddress] 
				   $ip
           }
	}
	# If the firewall does not answer to ICMP we wont have an array
	If ($trace.Count -gt 1)	{ $trace = $trace[1]}
	
	If (($trace -is [Net.IPAddress]) -and ($CurrentPingChecks -notcontains "Router Next Hop")){ # Add first IP outside default gw, effectively monitoring default gw
		$New247Checks += @{ "checktype" = "PingCheck";
							"name" = "Router Next Hop";
							"pinghost" = $trace;
							"failcount" = 1 }
	}
	

}

If ($Backup) {
	If ($Replace){
		Foreach ($xmlCheck in $DSC_config.checks.BackupCheck) {
		 	$null = $DSC_Config.checks.RemoveChild($xmlCheck) 
		}
	}	
	
	$CurrentBackupChecks = Get-GFIMAXChecks $DSC_Config.checks.BackupCheck "BackupProduct"
	$DetectedBackups = Get-GFIMAXChecks $DeviceConfig.configuration.backups "name"
	Foreach ($BackupProduct in $DetectedBackups){
		If (!($CurrentBackupChecks)){
			$JobCount = 99
			If($BackupProduct -match "Backup Exec"){
				$bengine =  Get-WmiObject win32_service | where { $_.PathName -match "bengine.exe" -and $_.DisplayName -match "Backup Exec"}
				If (!($bengine)){
					# Only add backup exec check if job engine is present
					Continue
				}
			} ElseIf ($BackupProduct -match "Managed Online Backup"){
				$MOBsessionFile = "$env:programdata\Managed Online Backup\Backup Manager\SessionReport.xml"
				[xml]$MOBsessions = Get-Content $MOBsessionFile

				$MOBplugins = @()
				ForEach ($Session in $MOBsessions.SessionStatistics.Session){
					If ($MOBplugins -notcontains $Session.plugin){
						$MOBplugins += $Session.plugin
					}
				}
				$JobCount = $MOBplugins.Count
			} ElseIf ($BackupProduct -match "Veeam"){
				Add-PSSnapin VeeamPSSnapin -ErrorAction SilentlyContinue
				If ((Get-PSSnapin "*Veeam*" -ErrorAction SilentlyContinue) -eq $null){ 
					Write-Host "Unable to load Veeam snapin, you must run this on your Veeam backup server, and the Powershell snapin must be installed.`n`n"
				} Else{
					$JobCount = (Get-VBRJob|select Name).Count
				}
			}
			
			# We cannot know how many jobs or which days. Better a 
			# failed check that someone investigates than no check at all
			$NewDSCChecks += @{ "checktype" = "BackupCheck";
								"BackupProduct" = $BackupProduct;
								"checkdays" = "MTWTFSS"; # Every day by default
								"partial" = 0;
								"count" = $JobCount; } # If this is still 99, this should get your attention...
								
		}
	}
}

If ($Antivirus) {
	If ($Replace){
		Foreach ($xmlCheck in $DSC_config.checks.AVUpdateCheck) {
		 	$null = $DSC_Config.checks.RemoveChild($xmlCheck) 
		}
	}	
	
	$CurrentAntivirusChecks = Get-GFIMAXChecks $DSC_Config.checks.AVUpdateCheck "AVProduct"
	$DetectedAntiviruses = Get-GFIMAXChecks $DeviceConfig.configuration.antiviruses "name"
	Foreach ($AVProduct in $DetectedAntiviruses){
		If (!($CurrentAntivirusChecks)){

			$NewDSCChecks += @{ "checktype" = "AVUpdateCheck";
								"AVProduct" = $AVProduct;
								"checkdays" = "MTWTFSS" } # Every day by default
								
		}
	}
}

$LogChecks = $true
If ($LogChecks) {
	$oldchecks = $DSC_config.checks.CriticalEvents
	If ($oldchecks.count -gt 0) {
		Foreach ($xmlCheck in ($oldchecks)) {
		 	$null = $DSC_Config.checks.RemoveChild($xmlCheck) 
		}
		Write-Host "Removed Critical Events"
		$ConfigChanged = $true
	}
	$oldchecks = $DSC_config.checks.EventLogCheck|where { $_.log.innertext -match "Application Hangs" -or $_.log.innertext -match "NTFS Errors" -or $_.log.innertext -match "BSOD Stop Errors" }
	If ($oldchecks.count -gt 0) {
		Foreach ($xmlCheck in ($oldchecks)) {
		 	$null = $DSC_Config.checks.RemoveChild($xmlCheck) 
		}
		Write-Host "Cleaned Eventlog checks"
		$ConfigChanged = $true
	}
	# Get next Eventlog check UID from settings.ini
	[int]$NextUid = $settingsContent["TEST_EVENTLOG"]["NEXTUID"]
	If ($NextUid -lt 1) { $NextUid = 1 }
	ForEach ($Check in $DefaultLogChecks) {
	Break
		$oldCheck = $DSC_config.checks.SelectSingleNode("EventLogCheck[log='{0}']" -f $Check["log"])
		If ($oldCheck) {
			If(($oldCheck.source.InnerText -eq $Check["source"]) -and ($oldCheck.flags -eq $Check["flags"])-and (($oldCheck.ids.InnerText -eq $Check["ids"]) -or ($oldCheck.ids -eq $Check["ids"]))) { 
				Continue  # check identical, skip
			}
			$Check["uid"] = $oldCheck.SelectSingleNode("uid").Innertext
			$oldCheck.ParentNode.RemoveChild($oldCheck)
		} Else {
			$Check["uid"] = $NextUid
			$NextUid++
		}
		$NewDSCChecks += $Check
	}
	# Save updated Eventlog test UID back to settings.ini
	$settingsContent["TEST_EVENTLOG"]["NEXTUID"] = $NextUid
	$LogNames = Get-GFIMAXChecks (Get-WmiObject win32_nteventlogfile|select logfilename) "logfilename"
	ForEach ($Check in $DefaultCriticalEvents) {
	Break
		If($LogNames -notcontains $Check["eventlog"]) { Continue }
		$oldCheck = $DSC_config.checks.SelectSingleNode("CriticalEvents[eventlog='{0}']" -f $Check["eventlog"])
		If ($oldCheck) {
			If(($oldCheck.mode -eq $Check["mode"]) -and ($oldCheck.option -eq $Check["option"])) { 
				Continue  # check already exist
			}
			$oldCheck.ParentNode.RemoveChild($oldCheck)
		} 
		If ($Check["eventlog"] -eq "HardwareEvents") {
			#This guy is special. We need to check if there are any events
			$HardwareEvents = Get-WmiObject Win32_NTEventLogFile | where { $_.LogFileName -eq "HardwareEvents" }
			If ($HardwareEvents.NumberOfRecords -eq 0) {
				Continue
			}
		}
		$NewDSCChecks += $Check
	}
}


If($New247Checks[0]) {
	Foreach ($Check in $New247Checks){
		$xmlCheck = $247_Config.CreateElement($Check.get_Item("checktype"))
		$xmlCheck.SetAttribute('modified', '1')
		$xmlCheck.SetAttribute('uid', $uid)
		$uid++ # Increase unique ID identifier to keep it unique
		
		Foreach ($property in $Check.Keys){
		 	If ($property -ne "checktype") {
				$xmlProperty = $247_Config.CreateElement($property)
				$propertyValue = $Check.get_Item($property)
				If ([bool]($propertyValue -as [int]) -or $propertyValue -eq "0") { # Is this a number? # If its a number we just dump it in there
					$xmlProperty.set_InnerText($propertyValue)
				} Else{ # If it is text we encode it in CDATA
					$rs = $xmlProperty.AppendChild($247_Config.CreateCDataSection($propertyValue))
				}
				# Add Property to Check element
				$rs = $xmlCheck.AppendChild($xmlProperty)
			}
		}
		# Add Check to file in check section
		$rs = $247_Config.checks.AppendChild($xmlCheck)

	}
	$247_Config.checks.SetAttribute("modified", "1")
	$ConfigChanged = $true
}

If($NewDSCChecks[0]) {
	Foreach ($Check in $NewDSCChecks){
		$xmlCheck = $DSC_Config.CreateElement($Check.get_Item("checktype"))
		$xmlCheck.SetAttribute('modified', '1')
		$xmlCheck.SetAttribute('uid', $uid)
		$uid++ # Increase unique ID identifier to keep it unique
		
		Foreach ($property in $Check.Keys){
		 	If ($property -ne "checktype") {
				$xmlProperty = $DSC_Config.CreateElement($property)
				$propertyValue = $Check.get_Item($property)
				If ([bool]($propertyValue -as [int]) -or $propertyValue -eq "0") { # Is this a number? # If its a number we just dump it in there
					$xmlProperty.set_InnerText($propertyValue)
				} Else{ # If it is text we encode it in CDATA
					$rs = $xmlProperty.AppendChild($DSC_Config.CreateCDataSection($propertyValue))
				}
				# Add Property to Check element
				$rs = $xmlCheck.AppendChild($xmlProperty)
			}
		}
		# Add Check to file in check section
		$rs = $DSC_Config.checks.AppendChild($xmlCheck)
	}
	$DSC_Config.checks.SetAttribute("modified", "1")
	$ConfigChanged = $true
}

If($ConfigChanged) { 
	$Today = (Get-Date).DayOfWeek.value__
	If (($Apply) -and ($Today -eq $WeekDay)) {
		# Update last runtime to prevent changes too often
		[int]$currenttime = $(get-date -UFormat %s) -replace ",","." # Handle decimal comma 
		$settingsContent["DAILYSAFETYCHECK"]["RUNTIME"] = $currenttime
		
		# Clear lastcheckday to make DSC run immediately
		$settingsContent["DAILYSAFETYCHECK"]["LASTCHECKDAY"] = "0"
		
		# Save updated NEXTCHECKUID
		$settingsContent["GENERAL"]["NEXTCHECKUID"] = $uid
		
		# Stop agent before writing new config files
		Stop-Service $gfimaxagent.Name
		
		# Save all config files
		$247_Config.Save($247file)
		$DSC_Config.Save($DSCfile)
		Out-IniFile $settingsContent $IniFile
		
		# Start monitoring agent again
		Start-Service $gfimaxagent.Name
		
		# Write output to Dashboard
		Write-Host "CHANGES APPLIED:"
		If ($New247Checks) {
			Write-Host "Added the following 24/7 checks to configuration file:"
			Format-Output $New247Checks 
		}
		If ($NewDSCChecks) {
			Write-Host "Added the following Daily Safety checks to configuration file:"
			Format-Output $NewDSCChecks 
		}
		If ($settingsChanged) { Write-host "Updated INI-file with updated settings."}
		If ($ReportMode){
			Exit 0 # Changes have been reported, but do not fail the check
		} Else {
			Exit 1001 # Internal status code:Changed made
		}
	} Else {
		Write-Host "SUGGESTED CHANGES:"
		If ($New247Checks) {
			Write-Host "`n-- 24/7 check(s):"
			Format-Output $New247Checks 
		}
		If ($NewDSCChecks) {
			Write-Host "`n-- Daily Safety check(s):"
			Format-Output $NewDSCChecks 
		}
		If ($settingsChanged) { Write-host "`n-- Update INI-file with default settings."}
		If ($ReportMode){
			Exit 0 # Needed changes have been reported, but do not fail the check
		} Else {
			Exit 1000 # Internal status code: Suggested changes, but nothing has been touched
		}
	}
} Else {
	# We have nothing to do. This Device has passed the test!
	Write-Host "CHECKS VERIFIED - Result:"
	If ($Performance) 		{ Write-Host "Performance Monitoring checks verified: OK"}
	If ($DriveSpaceCheck) 	{ Write-Host "Disk usage monitored on all harddrives: OK"}
	If ($WinServiceCheck) 	{ Write-Host "All Windows services are now monitored: OK"}
	If ($DiskSpaceChange) 	{ Write-Host "Disk space change harddrives monitored: OK"}
	If ($PingCheck) 		{ Write-Host "Pingcheck Router Next Hop check tested: OK"}
	If ($MSSQL) 			{ Write-Host "SQL Server installed:"; $Instances }
	If ($SMART) 			{ Write-Host "Physical Disk Health monitoring tested: OK"}
	If ($Backup) 			{ Write-Host "Unmonitored Backup Products not found: OK"}
	If ($Antivirus) 		{ Write-Host "Unmonitored Antivirus checks verified: OK"}
	Write-Host "All checks verified. Nothing has been changed."
	Exit 0 # SUCCESS
}
