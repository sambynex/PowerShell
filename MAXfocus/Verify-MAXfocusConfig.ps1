﻿[CmdletBinding(SupportsShouldProcess=$false, 
	PositionalBinding=$false,
	HelpUri = 'http://klemmestad.com/2014/12/22/automate-maxfocus-with-powershell/',
	ConfirmImpact='Medium')]
[OutputType([String])]
<#
.Synopsis
   Compares existing configuration of a MAXfocus monitoring agent against
   default settings stored in this script. Can add missing default checks
   automatically.
.DESCRIPTION
   The script is to be uploaded to your dashboard account as a user script.
   It can run both as a script check and as a scheduled task. You select
   check types to verify on a agent by giving the script parameters.
.EXAMPLE
   Verify-MAXfocusConfig -Apply -All
.EXAMPLE
   Verify-MAXfocusConfig -Apply -WinServiceCheck All
.EXAMPLE
   Verify-MAXfocusConfig -Apply -Performance -SMART -ServerInterval 15 -All
.OUTPUTS
   Correct XML configuration files that will reconfigure an MAXfocus agent
   upon agent restart.
.LINK
   http://klemmestad.com/2014/12/22/automate-maxfocus-with-powershell/
.LINK
   https://www.maxfocus.com/remote-management/automated-maintenance
.FUNCTIONALITY
   When the script finds that checks has to be added it will create valid XML
   entries and add them to agent configuration files. It uses Windows scheduled
   tasks to restart agent after the script completes.
#>

## SETTINGS
# A few settings are handled as parameters 
param (	
	# Accept all default check values in one go
    [Parameter(Mandatory=$false)]
	[switch]$All = $false,

    [Parameter(Mandatory=$false)]
	[switch]$Apply = $false, # -Apply will write new checks to configfiles and reload agent
	
	# -ReportMode will report missing checks, but not fail the script
    [Parameter(Mandatory=$false)]
    [ValidateSet("On", "Off")]
	[string]$ReportMode = "On",

	# Set to $false if you do not want performance checks
    [Parameter(Mandatory=$false)]
	[switch]$Performance = $false, 
	
	# This is useful on a Fault History report. Otherwise useless.
    [Parameter(Mandatory=$false)]
	[switch]$PingCheck = $false,
	
	# Detect SQL servers
    [Parameter(Mandatory=$false)]
	[switch]$MSSQL = $false, 
	
	# Enable physical disk check if SMART status is available
    [Parameter(Mandatory=$false)]
	[switch]$SMART = $false, 
	
	# Configure a basic backup check if a compatible product is recognized
    [Parameter(Mandatory=$false)]
	[switch]$Backup = $false, 
	
	# Configure an Antivirus check if a compatible product is recognized
    [Parameter(Mandatory=$false)]
	[switch]$Antivirus = $false, 
	
	# Configure default log checks
    [Parameter(Mandatory=$false)]
	[switch]$LogChecks = $false, 
	
	# Freespace as number+unit, i.e 10%, 5GB or 500MB
    [Parameter(Mandatory=$false)]
	[ValidatePattern('\d+(%|MB|GB)$')]
	[string]$DriveSpaceCheck = $null, 
	
	 # "All" or "DefaultOnly". 
	[Parameter(Mandatory=$false)]
    [ValidateSet("All", "Default")]
	[string]$WinServiceCheck = "",
	
	# percentage as integer
	[Parameter(Mandatory=$false)]
    [ValidateScript({$_ -ge 1 -and $_ -le 100})]
	[int]$DiskSpaceChange, 

	# 5 or 15 minutes
	[Parameter(Mandatory=$false)]
    [ValidateSet("5", "15")]
	[string]$ServerInterval = "5", 

	# 30 or 60 minutes
	[Parameter(Mandatory=$false)]
    [ValidateSet("30", "60")]
	[string]$PCInterval = "30", 

	# When DSC check should run in whole hours. Minutes not supported by agent.
	[Parameter(Mandatory=$false)]
    [ValidateScript({$_ -ge 0 -and $_ -le 23})]
	[string]$DSCHour = "8", 
	
	# Used to source this script for its functions
    [Parameter(Mandatory=$false)]
	[switch]$Library = $false 
)

# Convert Reportmode to Boolean
If ($ReportMode -eq 'On') { 
	[bool]$ReportMode = $true 
} Else {
	[bool]$ReportMode = $false 
}

Set-StrictMode -Version 2

## VARIUS FUNCTIONS
# 
function New-MAXfocusCheck (
	[string]$checktype, 
	[string]$option1,
	[string]$option2,
	[string]$option3,
	[string]$option4,
	[string]$option5,
	[string]$option6) {
	
	Switch ($checktype) {
		"DriveSpaceCheck" {
			$object = "" | Select driveletter,freespace,spaceunits
			$checkset = "247"
			$object.driveletter = $option1
			$object.freespace = $FreeSpace
			$object.spaceunits = $SpaceUnits
		}
		"DiskSpaceChange" {
			$object = "" | Select driveletter,threshold
			$checkset = "DSC"
			$object.driveletter = $option1
			$object.threshold = $DiskSpaceChange
		}
		"WinServiceCheck" {
			$object = "" | Select servicename,servicekeyname,failcount,startpendingok,restart,consecutiverestartcount,cumulativerestartcount
			$checkset = "247"
			$object.servicename = $option1
			$object.servicekeyname = $option2
			$object.failcount = 1 # How many consecutive failures before check fails
			$object.startpendingok = 0 # Is Startpending OK, 1 0 Yes, 0 = No
			$object.restart = 1 # Restart = 1 (Restart any stopped service as default)
			$object.consecutiverestartcount = 2 # ConsecutiveRestartCount = 2 (Fail if service doesnt run after 2 tries)
			$object.cumulativerestartcount = "4|24"  # Cumulative Restart Count = 4 in 24 hours
		}
		"PerfCounterCheck" {
			$object = "" | Select type,instance,threshold1,threshold2,threshold3,threshold4
			$checkset = "247"
			Switch ($option1) {
				"Queue" {
					$object.type = 1
					If ($option2) {
						$object.threshold1 = $option2
					} Else {
						$object.threshold1 = 2 # Recommended threshold by Microsoft for physical servers.
					}
				}
				"CPU" {
					$object.type = 2
					If ($option2) {
						$object.threshold1 = $option2
					} Else {
						$object.threshold1 = 99 # We are talking ALERTS here. We are not doing this for fun.
					}
				}
				"RAM" {
					$object.type = 3
					$object.instance = 2 # Fails if committed memory is more than twice that of physical RAM
					$object.threshold1 = 10 # Fails if average available RAM is less than 10 MB
					$object.threshold2 = 5000 # Fails if average pages/sec > 5000
					$object.threshold3 = 99 # % Page file usage
					If ($option2) {			# Nonpaged pool
						$object.threshold4 = $option2
					} Else {
						$object.threshold4 = 128
					}
				}
				"Net" {
					$object.type = 4
					$object.instance = $option2
					$object.threshold1 = 80 # We don't want alerts unless there really are problems 
				}
				"Disk" {
					$object.type = 5
					$object.instance = $option2
					If ($option3) {			
						$object.threshold1 = $option3  # Read queue
						$object.threshold2 = $option3  # Write queue
					} Else {
						$object.threshold1 = 4  # Read queue
						$object.threshold2 = 4  # Write queue
					}
					$object.threshold3 = 100 # Disk time, and again we are talking ALERTS
				}
			}
		}
		"PingCheck" {
			$object = "" | Select name,pinghost,failcount
			$checkset = "247"
			$object.name = $option1
			$object.pinghost = $option2
		}
		"BackupCheck" {
			$object = "" | Select BackupProduct,checkdays,partial,count
			$checkset = "DSC"
			$object.backupproduct = $option1
			$object.checkdays = "MTWTFSS"
			$object.partial = 0
			If ($option2) {
				$object.count = $option2
			} Else {
				$object.count = 99 # Dont know jobcount, make check fail 
			}
		}
		"AVUpdateCheck" {
			$object = "" | Select AVProduct,checkdays
			$checkset = "DSC"
			$object.avproduct = $option1
			$object.checkdays = "MTWTFSS"
		}
		"CriticalEvents" {
			$object = "" | Select eventlog,mode,option
			$checkset = "DSC"
			$object.eventlog = $option1
			If ($option2) {
				$object.mode = $option2
			} Else {
				$object.mode = 0 # Report mode
			}
			$object.option = 0
	  	}
		"EventLogCheck" {
			$object = "" | Select uid,log,flags,ids,source,contains,exclude,ignoreexclusions
			$checkset = "DSC"
			$object.uid = $option1
			$object.log = $option2
			$object.flags = $option3
			$object.source = $option4
			If($option5) {
				$object.ids = $option5
			} Else {
				$object.ids = "*"
			}
			$object.contains = ""
			$object.exclude = ""
			$object.ignoreexclusions = "false"
	   }
	   "VulnerabilityCheck" {
	   		$object = "" | Select schedule1,schedule2,devtype,mode,autoapproval,scandelaytime,failureemails,rebootdevice,rebootcriteria
			$checkset = "DSC"
			$object.schedule1 = ""
			$object.schedule2 = "2|0|{0}|0|{1}|0" -f $option1, $option2
			If ($AgentMode -eq "Server") {
				$object.devtype = 2
			} Else {
				$object.devtype = 1
			}
			$object.mode = 0
			$object.autoapproval = "2|2|2|2|2,2|2|2|2|2"
			$object.scandelaytime = ""
			$object.failureemails = 1
			$object.rebootdevice = 0
			$object.rebootcriteria = "0|1"
	   }
       "PhysDiskCheck" {
            $object = "" | Select volcheck
			$checkset = "DSC"
			$object.volcheck = 1
       }
	}
	
	$XmlCheck = $XmlConfig[$checkset].CreateElement($checktype)
	
	# Modified and uid are attributes, not properties. Do not set uid for new checks.
	# Let the agent deal with that. 
	$XmlCheck.SetAttribute('modified', '1')

	Foreach ($property in $object|Get-Member -MemberType NoteProperty) {
		$xmlProperty = $XmlConfig[$checkset].CreateElement($property.Name)
		$propertyValue = $object.($property.Name)
		# Is this a number?
		If ([bool]($propertyValue -as [int]) -or $propertyValue -eq "0") { 
			# If its a number we just dump it in there
			$xmlProperty.set_InnerText($propertyValue)
		} ElseIf ($propertyValue) { 
			# If it is text we encode it in CDATA
			$rs = $xmlProperty.AppendChild($XmlConfig[$checkset].CreateCDataSection($propertyValue))
		}
		# Add Property to Check element
		$rs = $xmlCheck.AppendChild($xmlProperty)
	}
	$rs = $XmlConfig[$checkset].checks.AppendChild($XmlCheck)
	$Script:NewChecks += $XmlCheck
	$Script:ConfigChanged = $true

}

function Get-XmlPropertyValue ($xmlProperty) {
	If ($XmlProperty -is [System.Xml.XmlElement]) {
		Return $XmlProperty.InnerText
	} Else {
		Return $XmlProperty
	}
}


function Get-MAXfocusCheckList ([string]$checktype, [string]$property, [string]$value, [bool]$ExactMatch = $true ) {
	$return = @()
	$ChecksToFilter = @()
	$ChecksToFilter = $XmlConfig.Values | % {$_.SelectNodes("//{0}" -f $checktype)}
	If (!($ChecksToFilter)) { Return }
	If ($value) {
		Foreach ($XmlCheck in $ChecksToFilter) {
			$XmlValue = Get-XmlPropertyValue $XmlCheck.$property
			If ($ExactMatch) { 
				If ($XmlValue -eq $value) { $return += $XmlCheck }
			} Else {
				If ($XmlValue -match $value) { $return += $XmlCheck }
			}
		}
	} Else {
		Return $ChecksToFilter
	}
	Return $return
}

function Remove-MAXfocusChecks ([array]$ChecksToRemove) {
	If (!($ChecksToRemove.Count -gt 0)) { Return }
	ForEach ($XmlCheck in $ChecksToRemove) {
		$XmlCheck.ParentNode.RemoveChild($XmlCheck)
		$Script:RemoveChecks += $XmlCheck
	}
	$Script:ConfigChanged = $true
}

function Get-MAXfocusCheck ([System.Xml.XmlElement]$XmlCheck) {
	$ChecksToFilter = @()
	$ChecksToFilter = Get-MAXfocusCheckList $XmlCheck.LocalName
	If ($ChecksToFilter.Count -eq 0) { Return $false }
	Foreach ($ExistingCheck in $ChecksToFilter) {
		$Match = $True
		Foreach ($ChildNode in $XmlCheck.ChildNodes) {
			If ($ChildNode.LocalName -eq "uid") { Continue }
			$property = $ChildNode.LocalName
			$ExistingValue = Get-XmlPropertyValue $ExistingCheck.$property
			If ($ChildNode.Innertext -ne $ExistingValue) {
				$Match = $false
				Break
			}
			If ($Match) {
				Return $ExistingCheck
			}
		}
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
function Format-Output($ArrayOfChecks) {
	$Result = @()
	Foreach ($CheckItem in $ArrayOfChecks){
		Switch ($CheckItem.LocalName)	{
			{"DriveSpaceCheck","DiskSpaceChange" -contains $_ } {
				$Result += $CheckItem.LocalName + " " + $CheckItem.driveletter.InnerText }
			"WinServicecheck" {
				$Result += $CheckItem.LocalName + " " + $CheckItem.servicename.InnerText }
			"PerfCounterCheck" { 
				Switch ($CheckItem.type) {
					"1" { $Result += $CheckItem.LocalName + " Processor Queue Length"}
					"2" { $Result += $CheckItem.LocalName + " Average CPU Usage"}
					"3" { $Result += $CheckItem.LocalName + " Memory Usage"}
					"4" { $Result += $CheckItem.LocalName + " Network Interface " + $CheckItem.instance.InnerText}
					"5" { $Result += $CheckItem.LocalName + " Physical Disk " + $CheckItem.instance.InnerText}
				}}
			{"PingCheck","AVUpdateCheck","BackupCheck","FileSizeCheck" -contains $CheckItem.LocalName } {
				$Result += $CheckItem.LocalName + " " + $CheckItem.name.InnerText }
			"EventLogCheck" {
				$Result += $CheckItem.LocalName + " " + $CheckItem.log.InnerText }
			"CriticalEvents" {
				switch ($CheckItem.mode) { 
					0 { $Result += $CheckItem.LocalName + " " + $CheckItem.eventlog.InnerText + " (Report)" }
					1 { $Result += $CheckItem.LocalName + " " + $CheckItem.eventlog.InnerText + " (Alert)" }}}
			default { 
				$Result += $CheckItem.LocalName }

		}
		
	}
	$Result += "" # Add blank line
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

function Get-TMScanType {
	$tmlisten = Get-WmiObject Win32_Service | where { $_.Name -eq "tmlisten" }
	$TrendDir = Split-Path $tmlisten.PathName.Replace( '"',"") -Parent
	$SmartPath = "{0}\*icrc`$oth.*" -f $TrendDir
	$ConvPath = "{0}\*lpt`$vpn.*" -f $TrendDir
	$SmartScan = Test-Path $SmartPath
	$ConvScan = Test-Path $ConvPath
	
	If (($SmartScan) -and ($ConvScan)) {
		$SmartFile = Get-Item $SmartPath | Sort LastAccessTime -Descending | Select -First 1
		$ConvFile = Get-Item $ConvPath | Sort LastAccessTime -Descending | Select -First 1
		If ($SmartFile.LastAccessTime -gt $ConvFile.LastAccessTime) {
			$ConvScan = $false
		} Else {
			$SmartScan = $false
		}
	}
	
	If ($SmartScan) {
		Return "Smart"
	} ElseIf ($ConvScan) {
		Return "Conventional"
	} Else {
		Return $false
	}
}

Function Is-SMARTavailable () {
    $PrevErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    Try {
        $Result = Get-WmiObject MSStorageDriver_FailurePredictStatus -Namespace root\wmi
    } Catch {
        $ErrorActionPreference = $PrevErrorAction
        Return $False
    }
    $ErrorActionPreference = $PrevErrorAction
    Return $True
}

## Exit if sourced as Library
If ($Library) { Exit 0 }

# Force the script to output something to STDOUT, else errors may cause script timeout.
Write-Host " "

If ($All)
{
	## DEFAULT CHECKS
	$Performance = $true # Set to $false if you do not want performance checks
	$PingCheck = $false # This is useful on a Fault History report. Otherwise useless.
	$MSSQL = $true # Detect SQL servers
	$SMART = $true # Enable physical disk check if SMART status is available
	$Antivirus = $true # Configure an Antivirus check if a compatible product is recognized
	$DriveSpaceCheck = "10%" # Freespace as number+unit, i.e 10%, 5GB or 500MB
	$WinServiceCheck = "All" # "All" or "Default". 
	$DiskSpaceChange = 10 # percentage as integer
	$Backup = $true # Try to configure Backup Monitoring
	$LogChecks = $true # Configure default eventlog checks
	$ReportMode = $true
}

$DefaultLogChecks = @(
	@{ "log" = "Application|Application Hangs"; # Application log | Human readable name
	   "flags" = 32512;
	   "ids" = "*";
	   "source" = "Application Hang" }
	@{ "log" = "System|NTFS Errors";
	   "flags" = 32513;
	   "ids" = "*";
	   "source" = "Ntfs*" }
	@{ "log" = "System|BSOD Stop Errors";
	   "flags" = 32513;
	   "ids" = "1003";
	   "source" = "System" }
)	   

$DefaultCriticalEvents = @(
	@{ "eventlog" = "Directory Service";
	   "mode" = 1 }
	@{ "eventlog" = "File Replication Service";
	   "mode" = 1 }
	@{ "eventlog" = "HardwareEvents";
	   "mode" = 1 }
	@{ "eventlog" = "System";
	   "mode" = 0 }
	@{ "eventlog" = "Application";
	   "mode" = 0 }
)

$DoNotMonitorServices = @( # Services you do not wish to monitor, regardless
	"wuauserv", # Windows Update Service. Does not run continously.
	"gupdate", "gupdatem", # Google Update Services. Does not always run.
	"AdobeARMservice", # Another service you may not want to monitor
	"Windows Agent Maintenance Service", # Clean up after N-Able
	"Windows Agent Service",
	"RSMWebServer"
)
$AlwaysMonitorServices = @( # Services that always are to be monitored if present and autorun
	"wecsvc" # Windows Event Collector
)
	

## SETUP ENVIRONMENT
# Find "Advanced Monitoring Agent" service and use path to locate files
$gfimaxagent = Get-WmiObject Win32_Service | Where-Object { $_.Name -eq 'Advanced Monitoring Agent' }
$gfimaxexe = $gfimaxagent.PathName
$gfimaxpath = Split-Path $gfimaxagent.PathName.Replace('"',"") -Parent

# XML Document objects
$XmlConfig = @{}
$AgentConfig = New-Object -TypeName XML
$DeviceConfig = New-Object -TypeName XML

# XML Document Pathnames
$XmlFile = @{}
$AgentFile = $gfimaxpath + "\agentconfig.xml"
$DeviceFile = $gfimaxpath + "\Config.xml"
$LastChangeFile = $gfimaxpath + "\LastChange.log"

# We need an array of hashes to remember which checks to add
$NewChecks = @()
$RemoveChecks = @()
$oldChecks = @()

# The prefix to the config files we need to read
$Sets = @("247", "DSC")

# An internal counter for new checks since we store them in a hashtable
[int]$uid = 1

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
		Write-Host "Changes Applied."
		If (Test-Path $LastChangeFile) {
			# Print last change to STDOUT
			Write-Host "------------------------------------------------------"
			Get-Content $LastChangeFile
			Write-Host "------------------------------------------------------"
		}
	Exit 0 # SUCCESS
	}
}


ForEach ($Set in $Sets) {
	$XmlConfig[$Set]  = New-Object -TypeName XML
	$XmlFile[$Set] = $gfimaxpath + "\{0}_Config.xml" -f $Set
	If  (Test-Path $XmlFile[$Set]) { 
		$XmlConfig[$Set].Load($XmlFile[$Set])
		$XmlConfig[$Set].DocumentElement.SetAttribute("modified","1")
	} Else {
		# File does not exist. Create a new, emtpy XML document
		$XmlConfig[$Set]  = New-Object -TypeName XML
		$decl = $XmlConfig[$Set].CreateXmlDeclaration("1.0", "ISO-8859-1", $null)
		$rootNode = $XmlConfig[$Set].CreateElement("checks")
		$result = $XmlConfig[$Set].InsertBefore($decl, $XmlConfig[$Set].DocumentElement)
		$result = $XmlConfig[$Set].AppendChild($rootNode)
		
		# Mark checks as modified. We will onøy write this to disk if we have modified anything
		$result = $rootNode.SetAttribute("modified", "1")
	}

} 


# Read agent config
$AgentConfig.Load($AgentFile)

# Read autodetected machine info
$DeviceConfig.Load($DeviceFile)

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


# Check for new services that we'd like to monitor'

## DRIVESPACECHECK
If ($DriveSpaceCheck) {
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
	
	# Get current fixed drives from WMI
	$DetectedDrives = GET-WMIOBJECT -query "SELECT * from win32_logicaldisk where DriveType = '3'" | select -Expandproperty DeviceID
	
	# Add any disk not currently in CurrentDiskSpaceChecks
	foreach ($Disk in $DetectedDrives) {
		If (($Disk -ne $env:SystemDrive) -and ($AgentMode -eq "workstation")){
			# Workstations are only monitoring %SystemDrive%
			Continue
		}
		$DriveLetter = $Disk + "\"
		$oldChecks = Get-MAXfocusCheckList DriveSpaceCheck driveletter $DriveLetter
		If (!($oldChecks)) {
			New-MAXfocusCheck DriveSpaceCheck $DriveLetter
		}
	}
}

## Disk Health Status
If (($SMART) -and (Is-SMARTavailable)) {
    $oldChecks = Get-MAXfocusCheckList PhysDiskCheck
	If (!($oldChecks)) {
		New-MAXfocusCheck PhysDiskCheck
	}
}


## DISKSPACECHANGE
#  We only use this on servers
If (($DiskSpaceChange) -and ($AgentMode -eq "server")) {
		
	# Get current fixed drives from WMI
	$DetectedDrives = GET-WMIOBJECT -query "SELECT * from win32_logicaldisk where DriveType = '3'" | select -ExpandProperty DeviceID

	# Add any disk not currently in CurrentDiskSpaceChecks
	foreach ($Disk in $DetectedDrives) {
		$DriveLetter = $Disk + "\"
		$oldChecks = Get-MAXfocusCheckList DiskSpaceChange driveletter $DriveLetter
		If (!($oldChecks)) {
			New-MAXfocusCheck DiskSpaceChange $DriveLetter
		}
	}
}

## WINSERVICECHECK
#  By default we only monitor services on servers

If (("All", "Default" -contains $WinServiceCheck) -and ($AgentMode -eq "server")) {
	# We really dont want to keep annoying services in our setup
	Foreach ($service in $DoNotMonitorServices) {
		$oldChecks = Get-MAXfocusCheckList WinServiceCheck servicekeyname $service
		If ($oldChecks) {
			Remove-MAXfocusChecks $oldChecks
		}
	}
	# An array to store names of services to monitor
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
	} Else { 
	  	# Add all services configured to autostart if pathname is outside %SYSTEMROOT%
		# if the service is currently running
		$autorunsvc = Get-WmiObject Win32_Service | 
		Where-Object { $_.StartMode -eq 'Auto' -and $_.PathName -notmatch ($env:systemroot -replace "\\", "\\") -and $_.State -eq "Running"} | select Displayname,Name
		Foreach ($service in $autorunsvc) {
			$ServicesToMonitor += $service
		}

		# Add all services located in %SYSTEMROOT% only if listed in services.ini
		$autorunsvc = Get-WmiObject Win32_Service | 
		Where-Object { $_.StartMode -eq 'Auto' -and $_.PathName -match ($env:systemroot -replace "\\", "\\") } | select Displayname,Name
		Foreach ($service in $autorunsvc) {
			If (($servicesContent["SERVICES"][$service.Name] -eq "1") -or ($AlwaysMonitorServices -contains $service.Name)) {
				$ServicesToMonitor += $service
			}
		}
	}

	# Ignore Web Protection Agent
	$DoNotMonitorServices += "WebMonAgent"
	## SERVICES TO ADD
	Foreach ($service in $ServicesToMonitor) {
		If ($DoNotMonitorServices -notcontains $service.Name) {
			$oldChecks = Get-MAXfocusCheckList WinServiceCheck servicekeyname $service.Name
			If (!($oldChecks)) {
				New-MAXfocusCheck WinServiceCheck $service.DisplayName $service.Name
			}
		}
	}

}

## Detect any databases and add relevant checks
If ($MSSQL) {
	
	# Get any SQL services registered on device
	$SqlInstances = @(Get-SQLInstance)

	If ($SqlInstances.count -gt 0) {
		# Load SQL server management assembly
		#[System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.SMO') | out-null 
	
		Foreach ($Instance in $SqlInstances){
			$sqlService = Get-WmiObject Win32_Service | where { $_.DisplayName -match $instance.SQLInstance -and $_.PathName -match "sqlservr.exe" -and $_.StartMode -eq 'Auto'}
			$oldChecks = Get-MAXfocusCheckList WinServiceCheck servicekeyname $sqlService.Name
			If (!($oldChecks)) {
				New-MAXfocusCheck WinServiceCheck $sqlService.DisplayName $sqlService.Name
			}
		}
	}
}



If ($Performance -and ($AgentMode -eq "server")) { # Performance monitoring is only available on servers
	$ThisDevice = Get-WmiObject Win32_ComputerSystem
	
	## Processor Queue
	If ($ThisDevice.Model -notmatch "^virtual|^vmware") {
		# We are on a physical machine
		$oldChecks = Get-MAXfocusCheckList PerfCounterCheck type 1
		If (!($oldChecks)) {
			New-MAXfocusCheck PerfCounterCheck Queue
		}
	}
	
	## CPU
	$oldChecks = Get-MAXfocusCheckList PerfCounterCheck type 2
	If (!($oldChecks)) {
		New-MAXfocusCheck PerfCounterCheck CPU
	}
	
	## RAM
	[int]$nonpagedpool = 128
	If ([System.IntPtr]::Size -gt 4) { # 64-bit
		[int]$TotalMemoryInMB = $ThisDevice.TotalPhysicalMemory / 1MB
		[int]$nonpagedpool = $nonpagedpool / 1024 * $TotalMemoryInMB
	}

	$oldChecks = Get-MAXfocusCheckList PerfCounterCheck type 2
	If (!($oldChecks)) {
		New-MAXfocusCheck PerfCounterCheck RAM $nonpagedpool
	}
	
	## Net
	#  Not on Hyper-V
	If ($ThisDevice.Model -notmatch "^virtual") {
		$NetConnections = Get-WmiObject Win32_PerfRawData_Tcpip_Networkinterface | where {$_.BytesTotalPersec -gt 0} | Select -ExpandProperty Name
		$oldChecks = Get-MAXfocusCheckList PerfCounterCheck Type 4
		If (!($oldChecks)) {
			Foreach ($Adapter in $NetConnections) {
				New-MAXfocusCheck PerfCounterCheck Net $Adapter
			}
		}
	}
	## Disk
	# Needs physical disks
	$PhysicalDisks =  $DeviceConfig.configuration.physicaldisks | select -ExpandProperty name | where {$_ -ne "_Total"}

	$oldChecks = Get-MAXfocusCheckList PerfCounterCheck Type 5
	If (!($oldChecks)) {
		Foreach	($Disk in $PhysicalDisks ) {
			New-MAXfocusCheck PerfCounterCheck Disk $Disk
		}
	}
}

if($PingCheck -and ($AgentMode -eq "server")) { # Pingcheck only supported on servers
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
	If ($trace -is [Net.IPAddress]) {
		$oldChecks = Get-MAXfocusCheckList PingCheck pinghost $trace
		If (!($oldChecks)) {
			New-MAXfocusCheck PingCheck 'Router Next Hop' $trace
		}
	}
	
}

If ($Backup) {
	$oldChecks = Get-MAXfocusCheckList BackupCheck
	If (!($oldChecks)) {
		$DetectedBackups = $DeviceConfig.configuration.backups | Select -ExpandProperty name -ErrorAction SilentlyContinue
		Foreach ($BackupProduct in $DetectedBackups){
			$JobCount = 1
			$AddCheck = $true
			Switch ($BackupProduct) {
				"Backup Exec" {
					$JobCount = 99 # Make sure unconfigured checks fail
					$bengine =  Get-WmiObject win32_service | where { $_.PathName -match "bengine.exe" -and $_.DisplayName -match "Backup Exec"}
					If (!($bengine)){
						# Only add backup exec check if job engine is present
						 $AddCheck = $false
					}
				}
				"Managed Online Backup" {
					$MOBsessionFile = "$env:programdata\Managed Online Backup\Backup Manager\SessionReport.xml"
					[xml]$MOBsessions = Get-Content $MOBsessionFile

					$MOBplugins = @()
					ForEach ($Session in $MOBsessions.SessionStatistics.Session){
						If ($MOBplugins -notcontains $Session.plugin){
							$MOBplugins += $Session.plugin
						}
					}
					$JobCount = $MOBplugins.Count
				} 
				"Veeam" {
					Add-PSSnapin VeeamPSSnapin -ErrorAction SilentlyContinue
					If ((Get-PSSnapin "*Veeam*" -ErrorAction SilentlyContinue) -eq $null){ 
						Write-Host "Unable to load Veeam snapin, you must run this on your Veeam backup server, and the Powershell snapin must be installed.`n`n"
					} Else {
						$JobCount = (Get-VBRJob|select Name).Count
					}
				}
				"AppAssure v5" {
					# Accept Default Jobcount, but add check
				}
				Default {
					# Don't add any checks
					 $AddCheck = $false
				}
			}
			If ($AddCheck) { 
				# We cannot know how many jobs or which days. Better a 
				# failed check that someone investigates than no check at all
				New-MAXfocusCheck BackupCheck $BackupProduct $JobCount
			}
		}
	}
}

If ($Antivirus) {
	$oldChecks = Get-MAXfocusCheckList AVUpdateCheck
	If (!($oldChecks)) {
		$DetectedAntiviruses = $DeviceConfig.configuration.antiviruses | Select -ExpandProperty name -ErrorAction SilentlyContinue
		If (($DetectedAntiviruses) -and ($DetectedAntiviruses -notcontains "Managed Antivirus")) {
			Foreach ($AVProduct in $DetectedAntiviruses) {
				$AddCheck = $true
				Switch -regex ($AVProduct) {
					'Windows Defender' { $AddCheck = $false }
					'Trend.+Conventional Scan' {
						If (Get-TMScanType -ne "Conventional") { $AddCheck = $false }	
					}
					'Trend.+Smart Scan' {
						If (Get-TMScanType -ne "Smart") { $AddCheck = $false }
					}
				}
				If ($AddCheck) {
					# Only add a single AV check. Break after adding.
					New-MAXfocusCheck AVUpdateCheck $AVProduct
					Break
				}
			}
		}
	}
}


If ($LogChecks -and $AgentMode -eq "server") {
	# Get next Eventlog check UID from settings.ini
	Try {
		$rs = $settingsContent["TEST_EVENTLOG"]["NEXTUID"]
	} Catch {
		$settingsContent["TEST_EVENTLOG"] = @{ "NEXTUID" = "1" }
	}
	[int]$NextUid = $settingsContent["TEST_EVENTLOG"]["NEXTUID"]
	If ($NextUid -lt 1) { $NextUid = 1 }
	ForEach ($Check in $DefaultLogChecks) {
		$oldChecks = Get-MAXfocusCheckList EventLogCheck log $Check.log
		If (!($oldChecks)) {
			New-MAXfocusCheck EventLogCheck $NextUid $Check.log $Check.flags $Check.source $Check.ids
			$NextUid++
		}
	}
	# Save updated Eventlog test UID back to settings.ini
	$settingsContent["TEST_EVENTLOG"]["NEXTUID"] = $NextUid
	
	# Get Windows Eventlog names on this device
	$LogNames = Get-WmiObject win32_nteventlogfile | select -ExpandProperty logfilename
	ForEach ($Check in $DefaultCriticalEvents) {
		# If this device doesn't have a targeted eventlog, skip the check
		If($LogNames -notcontains $Check.eventlog) { Continue }
		
		If ($Check["eventlog"] -eq "HardwareEvents") {
			#This guy is special. We need to check if there are any events
			$HardwareEvents = Get-WmiObject Win32_NTEventLogFile | where { $_.LogFileName -eq "HardwareEvents" }
			If ($HardwareEvents.NumberOfRecords -eq 0) {
				Continue
			}
		}
		# Add check if missing
		$oldChecks = Get-MAXfocusCheckList CriticalEvents eventlog $Check.eventlog
		If (!($oldChecks)) {
			New-MAXfocusCheck CriticalEvents $Check.eventlog $Check.mode
		}
	}
}


If ($ConfigChanged) {
	If ($Apply) {
		
		# Update last runtime to prevent changes too often
		[int]$currenttime = $(get-date -UFormat %s) -replace ",","." # Handle decimal comma 
		$settingsContent["DAILYSAFETYCHECK"]["RUNTIME"] = $currenttime
		
		# Clear lastcheckday to make DSC run immediately
		$settingsContent["DAILYSAFETYCHECK"]["LASTCHECKDAY"] = "0"
		
				
		# Save all relevant config files
		ForEach ($Set in $Sets) {
			$XmlConfig[$Set].Save($XmlFile[$Set])
		}
		Out-IniFile $settingsContent $IniFile
		
		# Restart monitoring agent with a scheduled task with 2 minutes delay.
		# Register a new task if it does not exist, set a new trigger if it does.
		Import-Module PSScheduledJob
		$JobTime = (Get-Date).AddMinutes(2)
		$JobTrigger = New-JobTrigger -Once -At $JobTime.ToShortTimeString()
		$JobOption = New-ScheduledJobOption -StartIfOnBattery -RunElevated 
		$RegisteredJob = Get-ScheduledJob -Name RestartAdvancedMonitoringAgent -ErrorAction SilentlyContinue
		If ($RegisteredJob) {
			Set-ScheduledJob $RegisteredJob -Trigger $JobTrigger
		} Else {
			Register-ScheduledJob -Name RestartAdvancedMonitoringAgent -ScriptBlock { Restart-Service 'Advanced Monitoring Agent' } -Trigger $JobTrigger -ScheduledJobOption $JobOption
		}		
		# Write output to $LastChangeFile
		# Overwrite file with first command
		"Last Change applied {0}:" -f $(Get-Date) | Out-File $LastChangeFile
		"------------------------------------------------------" | Out-File -Append $LastChangeFile
		If ($RemoveChecks.Count -gt 0) {
			"`nRemoved the following checks to configuration file:" | Out-File -Append $LastChangeFile
			Format-Output $RemoveChecks | Out-File -Append $LastChangeFile
		}
		If ($NewChecks.Count -gt 0) {
			"`nAdded the following checks to configuration file:" | Out-File -Append $LastChangeFile
			Format-Output $NewChecks | Out-File -Append $LastChangeFile
		}
		If ($ReportMode) {
			Exit 0 # Needed changes have been reported, but do not fail the check
		} Else {
			Exit 1001 # Internal status code: Changes made
		}
	} Else {
		Write-Host "Recommended changes:"

		If ($RemoveChecks.Count -gt 0) {
			Write-Host "Checks to be removed:"
			Format-Output $RemoveChecks 
		}
		If ($NewChecks.Count -gt 0) {
			Write-Host "Checks to be added:"
			Format-Output $NewChecks 
		}
		If (Test-Path $LastChangeFile) {
			# Print last change to STDOUT
			Write-Host "------------------------------------------------------"
			Get-Content $LastChangeFile
			Write-Host "------------------------------------------------------"
		}
		If ($ReportMode) {
			Exit 0 # Needed changes have been reported, but do not fail the check
		} Else {
			Exit 1000 # Internal status code: Suggested changes, but nothing has been touched
		}
	}
} Else {
	# We have nothing to do. This Device has passed the test!
	Write-Host "Current Configuration Verified  - OK:"
	If ($Performance) 		{ Write-Host "Performance Monitoring checks verified: OK"}
	If ($DriveSpaceCheck) 	{ Write-Host "Disk usage monitored on all harddrives: OK"}
	If ($WinServiceCheck) 	{ Write-Host "All Windows services are now monitored: OK"}
	If ($DiskSpaceChange) 	{ Write-Host "Disk space change harddrives monitored: OK"}
	If ($PingCheck) 		{ Write-Host "Pingcheck Router Next Hop check tested: OK"}
	If ($SqlInstances.count -gt 0) { Write-Host "SQL Server installed:"; $SqlInstances }
	If ($SMART) 			{ Write-Host "Physical Disk Health monitoring tested: OK"}
	If ($Backup) 			{ Write-Host "Unmonitored Backup Products not found: OK"}
	If ($Antivirus) 		{ Write-Host "Unmonitored Antivirus checks verified: OK"}
	Write-Host "All checks verified. Nothing has been changed."
	If (Test-Path $LastChangeFile) {
		# Print last change to STDOUT
		Write-Host "------------------------------------------------------"
		Get-Content $LastChangeFile
		Write-Host "------------------------------------------------------"
	}
	# Try to make Windows autostart monitoring agent if it fails
	# Try to read the FailureActions property of Advanced Monitoring Agent
	# If it does not exist, create it with sc.exe
	$FailureActions = Get-ItemProperty "HKLM:\System\CurrentControlSet\Services\Advanced Monitoring Agent" FailureActions -ErrorAction SilentlyContinue
	If (!($FailureActions)) {
		# Reset count every 24 hours, restart service after twice the 247Interval minutes
		[int]$restartdelay = 120000 * $247Interval 
		$servicename = $gfimaxagent.Name
		sc.exe failure "$servicename" reset=86400 actions= restart/$restartdelay
	}
	Exit 0 # SUCCESS
}

