<#
.SYNOPSIS
Generic utilities for the Compute Node extension

.DESCRIPTION
This module is used by the extension script, and must run on PowerShell 2.0 or later. 
    
#>

$ErrorActionPreference = 'stop'
Set-StrictMode -Version latest
$Script:LogFile = $null
$Script:LogBuffer = New-Object System.Collections.Generic.List[string]
$script:PowerShellPaths = @(
    "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
    "C:\Windows\SysWow64\WindowsPowerShell\v1.0\powershell.exe"
)

<#
.Synopsis
	Set the log file parameter which will later be used by Write-Log function
#>
function Set-LogFile
{
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )

    $Script:LogFile = $Path
}

<#
.Synopsis
	Writes log to the log file.
	Also outputs the message to screen.
	Note: Set-LogFile must be invoked before calling this function.
#>
function Write-Log
{
    param(
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [string]$Message,

        [Parameter(Mandatory=$false, Position=1)]
        [ValidateSet("Error","Warning","Information","Detail")]
        [string]$LogLevel = "Information"
    )
	
    if ($null -eq $script:LogFile)
	{
        throw "LogFile is uninitialized. Use Set-LogFile before using this function. callStack: $(Get-PSCallStack)"
    }

    $formattedMessage = '[{0:s}][{1}] {2}' -f ([DateTimeOffset]::Now.ToString('u')), $LogLevel, $Message
    if($LogLevel -ne 'Detail')
    {
        $Script:LogBuffer.Add($formattedMessage)
    }

    Write-Verbose -Verbose "${formattedMessage}"
    if($Script:LogFile)
    {
        try
        {
            $formattedMessage | Out-File $Script:LogFile -Append
        }
        catch
        {
        }
    }
}

<#
.Synopsis
    Writes the Message and Exception to log (using Write-Log) and then throws with the message only
#>
function ThrowAndWriteLog {
    param(
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [string]$Message,
		
        [Parameter(Mandatory=$false, Position=1, ValueFromPipeline=$true)]
        [string]$Exception
    )
	
    Write-Log "$Message $Exception" -LogLevel Error
    throw $Message
}

<#
.Synopsis
    Decrypts the protected settings using the LocalMachine certificate and provided Thumbprint
#>
function Decrypt-ProtectedSettings {
    param(

        [Parameter(Mandatory = $true)]
        [string]$EncryptedProtectedSettings,

        [Parameter(Mandatory = $true)]
        [string]$Thumbprint
    )
    
    Try {
        $certificate = Get-ChildItem "Cert:\LocalMachine\My\$Thumbprint" -ErrorAction Stop

        if (!$certificate) {
            throw "Cannot find the certificate $Thumbprint to decode protected settings"
        }
    }
    catch {
        ThrowAndWriteLog "Failed to find the certificate $Thumbprint to decode protected settings. Exception: $($_)" 
    }

    
    Add-Type -AssemblyName System.Security
    $envelope = New-Object System.Security.Cryptography.Pkcs.EnvelopedCms
    $envelope.Decode([Convert]::FromBase64String($EncryptedProtectedSettings))
    $certificateCollection = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection($certificate)
    $envelope.Decrypt($certificateCollection)
    $decryptedProtectedSettings = [System.Text.Encoding]::UTF8.GetString($envelope.ContentInfo.Content)

    return $decryptedProtectedSettings
}

<#
.Synopsis
    Recursively walks the given object and converts any PSObjects to Hashtables
#>
function ConvertTo-Hashtable
{
    [CmdletBinding()]
    param (
        [AllowNull()]
        [AllowEmptyCollection()]
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [object] $object
    )

    if ($null -eq $object)
    {
        return $null
    }

    switch ($object.GetType()) {
        { $_.FullName -eq 'System.Management.Automation.PSCustomObject' } {
            $hashtable = @{}

            foreach ($p in $object.psobject.properties)
            {
                $hashtable[$p.Name] = ConvertTo-Hashtable $p.Value
            }

            return $hashtable
        }

        { $_.IsArray } {
            for ($i = 0; $i -lt $object.Length; $i++) {
                $object[$i] = ConvertTo-Hashtable $object[$i]
            }

            return ,$object
        }

        default {
            return $object
        }
    }
}

<#
.Synopsis
    Parses the HandlerEnvironment.json file with retries.
	Note: In rare cases a handler might encounter errors when trying to read the HandlerEnvironment.json file, since the Azure Agent might be writing the file at the same time as well
#>
function Get-HandlerEnvironment
{
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()


    $handlerEnvironmentFile = "$PSScriptRoot\HandlerEnvironment.json"
    $retry = 0
    while($true) 
    {
        try
        {
            $jsonEnvContent = Get-Content $handlerEnvironmentFile -Encoding UTF8 | Out-String | ConvertFrom-Json
            if($jsonEnvContent)
            {
                return $jsonEnvContent[0].handlerEnvironment
            }
            else
            {
                throw "$handlerEnvironmentFile is empty"
            }
        }
        catch
        {
            if($retry++ -lt 5)
            {
                $retryInterval = [System.Math]::Pow(2, $retry)
                Start-Sleep -Seconds $retryInterval
            }
            else
            {
                throw
            }
        }
    }
}

<#
.Synopsis
    Parses the latest handler .settings file (in the configuration folder), and decrypts the protected settings if exists.
#>
function Get-HandlerSettings
{
    [CmdletBinding()]
    [OutputType([HashTable])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigFolder
    )

    $settingsFiles = Get-ChildItem -Path $ConfigFolder -Filter '*.settings'
    if (!$settingsFiles)
    {
        throw "Did not find any runtime configuration files"
    }

    $sequenceNumber = [int]($settingsFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1).BaseName
    $handlerSettingsFile = '{0}\{1}.settings' -f $ConfigFolder, $sequenceNumber
    $settings = (Get-Content $handlerSettingsFile -Encoding UTF8 | Out-String | ConvertFrom-Json).runtimeSettings[0].handlerSettings | ConvertTo-Hashtable
    $settings['sequenceNumber'] = $sequenceNumber
    if ($settings.ContainsKey('protectedSettings') -and $settings.ContainsKey('protectedSettingsCertThumbprint') -and $settings['protectedSettings'] -and $settings['protectedSettingsCertThumbprint'])
    {
        $decryptedProtectedSettings = Decrypt-ProtectedSettings -EncryptedProtectedSettings $settings['protectedSettings'] -Thumbprint $settings['protectedSettingsCertThumbprint']
        $settings['protectedSettings'] = $decryptedProtectedSettings | ConvertFrom-Json | ConvertTo-Hashtable
    }
    else
    {
        $settings['protectedSettings'] = $null
    }

    return $settings
}

<#
.Synopsis
    Sets the status of the extension handler
.Description
    Status is reported to a file name <SequenceNumber>.status under the path given by statusFolder in
    the handler's environment.

    These files have the following format:

    [{
        "version": 1.0,
        "timestampUTC": "2013-11-17T16:05:14Z",
        "status" : {
            "status": "<transitioning | error | success | warning>",
            "code" : 0,
            "configurationAppliedTime": "2013-11-17T16:05:14Z",
            "formattedMessage": {
                "Lang": "en-us",
                "Message": "Enable IIS on the VM."
            },
        }
    }]
	
	Also attaches more logs to substatus if there are any warnings/errors
#>
function Set-HandlerStatus
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string] $StatusFolder,

        [Parameter(Mandatory=$true)]
        [int] $SequenceNumber,

        [Parameter(Mandatory=$true)]
        [int] $Code,

        [Parameter(Mandatory=$true)]
        [string] $Message,

        [Parameter(Mandatory=$true)]
        [ValidateSet('transitioning', 'error', 'success', 'warning')]
        [string] $Status
    )

    $statusFile = '{0}\{1}.status' -f $StatusFolder, $SequenceNumber

    Write-Log "Set handler status ($statusFile), Status=$Status, Code=$Code, Message='$Message'"

    $timestampUTC = [DateTimeOffset]::Now.ToString('u')

    $statusObject = @(
        @{  
            status = @{ 
                formattedMessage = @{
                    lang = 'en-US'
                    message = $Message
                }
                status = $Status
                code = $Code
                configurationAppliedTime = $timestampUTC
            }
            version = '1.0'
            timestampUTC = $timestampUTC
        }
    )

    if((($Status -eq 'warning') -or ($Status -eq 'error')) -and ($Script:LogBuffer.Count -gt 0))
    {
        # Attach more logs in substatus if the status is warning or error
        $recentlogs = @($Script:LogBuffer.ToArray() | Select-Object -Last 10) -join "`r`n"
        $statusObject[0].status['substatus'] = @(
            @{
                name = 'executionlog'
                status = $Status
                code = $Code
                formattedMessage = @{
                    lang = 'en-US'
                    message = $recentlogs
                }
            }
        )
    }

    #This will error out when azure agent is reading it while we try to access the file 
    #Add retries if the process cannot access the status file
    $result = $false
    for ($sleepPeriod = 1; $sleepPeriod -le 64; $sleepPeriod = 2 * $sleepPeriod) 
    {
        try
        {
            ConvertTo-Json -InputObject $statusObject -Depth 16 | Set-Content -Encoding UTF8 -Path $statusFile -Force
            $result = $true
            break
        }
        catch
        {
            Write-Log "Error accessing the status file: $statusFile... $_" -LogLevel Warning
            Write-Log "Retry after $sleepPeriod Secs..."
            Start-Sleep -Seconds $sleepPeriod
        }
    }

    if (!$result) {
        throw "Error accessing the status file: $statusFile..."
    }
}

<#
.Synopsis
    Gets the PowerShell path to be used for executing the handler.
#>
function Get-PowerShellPath {
    param ()

    if (Get-Command powershell.exe -ErrorAction SilentlyContinue) {
        Write-Log "'powershell.exe' is available."
        return "powershell.exe"
    }

    foreach ($currentPath in $script:PowerShellPaths) {
        if (Test-Path $currentPath) {
            Write-Log "Valid PowerShell path found: $currentPath"
            return $currentPath
        }
    }

    throw "Error running PowerShell. No valid PowerShell path found."
}

Export-ModuleMember `
    -Function @(
    'Set-LogFile'
    'Write-Log'
    'ThrowAndWriteLog'
    'Get-HandlerEnvironment'
    'Get-HandlerSettings'
    'Set-HandlerStatus'
    'Get-PowerShellPath'
)

# SIG # Begin signature block
# MIIoLAYJKoZIhvcNAQcCoIIoHTCCKBkCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDYgn8uxa+XZHD3
# 4gSUzIgC1jszIcSqy7l35vSlE4QXKKCCDXYwggX0MIID3KADAgECAhMzAAAEhV6Z
# 7A5ZL83XAAAAAASFMA0GCSqGSIb3DQEBCwUAMH4xCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25p
# bmcgUENBIDIwMTEwHhcNMjUwNjE5MTgyMTM3WhcNMjYwNjE3MTgyMTM3WjB0MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYDVQQDExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
# AQDASkh1cpvuUqfbqxele7LCSHEamVNBfFE4uY1FkGsAdUF/vnjpE1dnAD9vMOqy
# 5ZO49ILhP4jiP/P2Pn9ao+5TDtKmcQ+pZdzbG7t43yRXJC3nXvTGQroodPi9USQi
# 9rI+0gwuXRKBII7L+k3kMkKLmFrsWUjzgXVCLYa6ZH7BCALAcJWZTwWPoiT4HpqQ
# hJcYLB7pfetAVCeBEVZD8itKQ6QA5/LQR+9X6dlSj4Vxta4JnpxvgSrkjXCz+tlJ
# 67ABZ551lw23RWU1uyfgCfEFhBfiyPR2WSjskPl9ap6qrf8fNQ1sGYun2p4JdXxe
# UAKf1hVa/3TQXjvPTiRXCnJPAgMBAAGjggFzMIIBbzAfBgNVHSUEGDAWBgorBgEE
# AYI3TAgBBggrBgEFBQcDAzAdBgNVHQ4EFgQUuCZyGiCuLYE0aU7j5TFqY05kko0w
# RQYDVR0RBD4wPKQ6MDgxHjAcBgNVBAsTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEW
# MBQGA1UEBRMNMjMwMDEyKzUwNTM1OTAfBgNVHSMEGDAWgBRIbmTlUAXTgqoXNzci
# tW2oynUClTBUBgNVHR8ETTBLMEmgR6BFhkNodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NybC9NaWNDb2RTaWdQQ0EyMDExXzIwMTEtMDctMDguY3JsMGEG
# CCsGAQUFBwEBBFUwUzBRBggrBgEFBQcwAoZFaHR0cDovL3d3dy5taWNyb3NvZnQu
# Y29tL3BraW9wcy9jZXJ0cy9NaWNDb2RTaWdQQ0EyMDExXzIwMTEtMDctMDguY3J0
# MAwGA1UdEwEB/wQCMAAwDQYJKoZIhvcNAQELBQADggIBACjmqAp2Ci4sTHZci+qk
# tEAKsFk5HNVGKyWR2rFGXsd7cggZ04H5U4SV0fAL6fOE9dLvt4I7HBHLhpGdE5Uj
# Ly4NxLTG2bDAkeAVmxmd2uKWVGKym1aarDxXfv3GCN4mRX+Pn4c+py3S/6Kkt5eS
# DAIIsrzKw3Kh2SW1hCwXX/k1v4b+NH1Fjl+i/xPJspXCFuZB4aC5FLT5fgbRKqns
# WeAdn8DsrYQhT3QXLt6Nv3/dMzv7G/Cdpbdcoul8FYl+t3dmXM+SIClC3l2ae0wO
# lNrQ42yQEycuPU5OoqLT85jsZ7+4CaScfFINlO7l7Y7r/xauqHbSPQ1r3oIC+e71
# 5s2G3ClZa3y99aYx2lnXYe1srcrIx8NAXTViiypXVn9ZGmEkfNcfDiqGQwkml5z9
# nm3pWiBZ69adaBBbAFEjyJG4y0a76bel/4sDCVvaZzLM3TFbxVO9BQrjZRtbJZbk
# C3XArpLqZSfx53SuYdddxPX8pvcqFuEu8wcUeD05t9xNbJ4TtdAECJlEi0vvBxlm
# M5tzFXy2qZeqPMXHSQYqPgZ9jvScZ6NwznFD0+33kbzyhOSz/WuGbAu4cHZG8gKn
# lQVT4uA2Diex9DMs2WHiokNknYlLoUeWXW1QrJLpqO82TLyKTbBM/oZHAdIc0kzo
# STro9b3+vjn2809D0+SOOCVZMIIHejCCBWKgAwIBAgIKYQ6Q0gAAAAAAAzANBgkq
# hkiG9w0BAQsFADCBiDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24x
# EDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjEyMDAGA1UEAxMpTWljcm9zb2Z0IFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5
# IDIwMTEwHhcNMTEwNzA4MjA1OTA5WhcNMjYwNzA4MjEwOTA5WjB+MQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSgwJgYDVQQDEx9NaWNyb3NvZnQg
# Q29kZSBTaWduaW5nIFBDQSAyMDExMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEAq/D6chAcLq3YbqqCEE00uvK2WCGfQhsqa+laUKq4BjgaBEm6f8MMHt03
# a8YS2AvwOMKZBrDIOdUBFDFC04kNeWSHfpRgJGyvnkmc6Whe0t+bU7IKLMOv2akr
# rnoJr9eWWcpgGgXpZnboMlImEi/nqwhQz7NEt13YxC4Ddato88tt8zpcoRb0Rrrg
# OGSsbmQ1eKagYw8t00CT+OPeBw3VXHmlSSnnDb6gE3e+lD3v++MrWhAfTVYoonpy
# 4BI6t0le2O3tQ5GD2Xuye4Yb2T6xjF3oiU+EGvKhL1nkkDstrjNYxbc+/jLTswM9
# sbKvkjh+0p2ALPVOVpEhNSXDOW5kf1O6nA+tGSOEy/S6A4aN91/w0FK/jJSHvMAh
# dCVfGCi2zCcoOCWYOUo2z3yxkq4cI6epZuxhH2rhKEmdX4jiJV3TIUs+UsS1Vz8k
# A/DRelsv1SPjcF0PUUZ3s/gA4bysAoJf28AVs70b1FVL5zmhD+kjSbwYuER8ReTB
# w3J64HLnJN+/RpnF78IcV9uDjexNSTCnq47f7Fufr/zdsGbiwZeBe+3W7UvnSSmn
# Eyimp31ngOaKYnhfsi+E11ecXL93KCjx7W3DKI8sj0A3T8HhhUSJxAlMxdSlQy90
# lfdu+HggWCwTXWCVmj5PM4TasIgX3p5O9JawvEagbJjS4NaIjAsCAwEAAaOCAe0w
# ggHpMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBRIbmTlUAXTgqoXNzcitW2o
# ynUClTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYD
# VR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBRyLToCMZBDuRQFTuHqp8cx0SOJNDBa
# BgNVHR8EUzBRME+gTaBLhklodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2Ny
# bC9wcm9kdWN0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFfMDNfMjIuY3JsMF4GCCsG
# AQUFBwEBBFIwUDBOBggrBgEFBQcwAoZCaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraS9jZXJ0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFfMDNfMjIuY3J0MIGfBgNV
# HSAEgZcwgZQwgZEGCSsGAQQBgjcuAzCBgzA/BggrBgEFBQcCARYzaHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraW9wcy9kb2NzL3ByaW1hcnljcHMuaHRtMEAGCCsG
# AQUFBwICMDQeMiAdAEwAZQBnAGEAbABfAHAAbwBsAGkAYwB5AF8AcwB0AGEAdABl
# AG0AZQBuAHQALiAdMA0GCSqGSIb3DQEBCwUAA4ICAQBn8oalmOBUeRou09h0ZyKb
# C5YR4WOSmUKWfdJ5DJDBZV8uLD74w3LRbYP+vj/oCso7v0epo/Np22O/IjWll11l
# hJB9i0ZQVdgMknzSGksc8zxCi1LQsP1r4z4HLimb5j0bpdS1HXeUOeLpZMlEPXh6
# I/MTfaaQdION9MsmAkYqwooQu6SpBQyb7Wj6aC6VoCo/KmtYSWMfCWluWpiW5IP0
# wI/zRive/DvQvTXvbiWu5a8n7dDd8w6vmSiXmE0OPQvyCInWH8MyGOLwxS3OW560
# STkKxgrCxq2u5bLZ2xWIUUVYODJxJxp/sfQn+N4sOiBpmLJZiWhub6e3dMNABQam
# ASooPoI/E01mC8CzTfXhj38cbxV9Rad25UAqZaPDXVJihsMdYzaXht/a8/jyFqGa
# J+HNpZfQ7l1jQeNbB5yHPgZ3BtEGsXUfFL5hYbXw3MYbBL7fQccOKO7eZS/sl/ah
# XJbYANahRr1Z85elCUtIEJmAH9AAKcWxm6U/RXceNcbSoqKfenoi+kiVH6v7RyOA
# 9Z74v2u3S5fi63V4GuzqN5l5GEv/1rMjaHXmr/r8i+sLgOppO6/8MO0ETI7f33Vt
# Y5E90Z1WTk+/gFcioXgRMiF670EKsT/7qMykXcGhiJtXcVZOSEXAQsmbdlsKgEhr
# /Xmfwb1tbWrJUnMTDXpQzTGCGgwwghoIAgEBMIGVMH4xCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNp
# Z25pbmcgUENBIDIwMTECEzMAAASFXpnsDlkvzdcAAAAABIUwDQYJYIZIAWUDBAIB
# BQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEO
# MAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIIYqh/CdLC+d4BdehaRBRUeJ
# SQ0TA7jA8NGLA5/9i5ltMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8A
# cwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEB
# BQAEggEAKXNgG2iAzEgy2ctqr7JZCWe5aU2UTmzwB/QAlIzOU9gnvR0JLNPl+dPc
# WBytAgUDxck8iY9Oyau5ABnjT0zeExDmWB6QoqeyfXHpRnekMYlS32Gi9/htViNZ
# /8MdzsvgoTbLKRGrzjeSIdiMZ68Zazfcec2uhUZ4aE4PlFUkZsR7uT7FKdSl8/A/
# rhCTmd1aaJGk+k+yVkbDGsWL5pXGHtj/MFThTQEAE5fuu7hDK8hLTmz/ppiwGuye
# yGkH0K/99PmEicpfZGdKDyHzmHq427F29QNh16zcbVUAcXkjNR6m77Lq3bXr3PPZ
# tdyCqNS4/FVyN/GRe3RSM2KNfhmJ66GCF5YwgheSBgorBgEEAYI3AwMBMYIXgjCC
# F34GCSqGSIb3DQEHAqCCF28wghdrAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFRBgsq
# hkiG9w0BCRABBKCCAUAEggE8MIIBOAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFl
# AwQCAQUABCBCKFNiM8LefVpxlt+tO/XF7ZyPRSxLoamci2d9aeKXywIGaKOm3LqY
# GBIyMDI1MDgzMTA4MTMzMS4yMlowBIACAfSggdGkgc4wgcsxCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVy
# aWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjozMzAzLTA1
# RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCC
# Ee0wggcgMIIFCKADAgECAhMzAAACD1eaRxRA5kbmAAEAAAIPMA0GCSqGSIb3DQEB
# CwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQH
# EwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNV
# BAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDEzMDE5NDMw
# NFoXDTI2MDQyMjE5NDMwNFowgcsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNo
# aW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMx
# JzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjozMzAzLTA1RTAtRDk0NzElMCMGA1UE
# AxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZTCCAiIwDQYJKoZIhvcNAQEB
# BQADggIPADCCAgoCggIBAKXoNO6vF/rqjvcbQDbIqjX+di8hMFCx3nQXnZJDOjZx
# Ku34QMQUIOVLFnNYkPu6NDVnV0xsxPpiErslS/DFD4uRBe/aT/e/fHDzEnaaFe7B
# tP6zVY4vT72D0A4QAAzpYaMLMj8tmrf+3MevnqKf9n76j/aygaHIaEowPBaXgngv
# UWfyd22gzVIGJs92qbCY9ekH1C1o/5MI4LW8BoZA52ypdDwB2UrpW6T3Jb23LtLS
# RE/WdeQWx4zfc3MG7/+5tqgkdvVx5g9nhTgQ5cEeL/aDT1ZEv1BYi0eM8YliO4nR
# yTKs4bWSx8BlY/4G7w9cCrizUFr+H+deFcDC7FOGm9oVvhPRs6Ng7+HYs9Ft0Mxw
# x9L1luGrXSFc/pkUdHRFEn6uvkDwgP2XRSChS7+A28KocIyjDP3u52jt5Y4MDstp
# W/zUUcdjDdfkNJNSonqnA/7/SXFq3FqNtIaybbrvOpU2y7NSgXYXM8z5hQjCI6mB
# C++NggGQH4pTBl/a9Eg9aaEATNZkAZOjH/S+Ph4eDHARH1+lOFyxtkZLHHScvngf
# P4vfoonIRWKj6glW9TGbvlgQRJpOHVGcvQOWz3WwHDqa8qs7Y740JtS1/H5xBdhL
# QlxZl5/zXQFb0Gf94i+jDcpzHR1W6oN8hZ9buKZ5MsAr1AAST6hkInNRRO+GHaFh
# AgMBAAGjggFJMIIBRTAdBgNVHQ4EFgQUmdQxDY63ICEtH8wPaq0n2UpE/1kwHwYD
# VR0jBBgwFoAUn6cVXQBeYl2D9OXSZacbUzUZ6XIwXwYDVR0fBFgwVjBUoFKgUIZO
# aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIw
# VGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3JsMGwGCCsGAQUFBwEBBGAwXjBc
# BggrBgEFBQcwAoZQaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0
# cy9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcnQwDAYD
# VR0TAQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAOBgNVHQ8BAf8EBAMC
# B4AwDQYJKoZIhvcNAQELBQADggIBAFOjBujVtQTt9dPL65b2bnyoYRdEEZUwRCIU
# R9K6LV+E3uNL6RKI3RJHkqXcC5Xj3E7GAej34Yid7kymDmfg1Lk9bydYhYaP/yOQ
# Tel0llK8BlqtcPiXjeIw3EOF0FmpUKQBhx0VVmfF3L7bkxFjpF9obCSKeOdg0UDo
# Ngv/VzHDphrixfJXsWA90ybFWl9+c8QMW/iZxXHeO89mh3uCqINxQdvJXWBo0Pc9
# 6PInUwZ8FhsBDGzKctfUVSxYvAqw09EmPKfCXMFP85BvGfOSMuJuLiHh07Bw34fi
# bIO1RKdir1d/hi8WVn6Ymzli3HhT0lULJb9YRG0gSJ5O9NGC8BiP/gyHUXYSV/xx
# 0guDOL17Oph5/F2wEPxWLHfnIwLktOcNSjJVW6VR54MAljz7pgFu1ci3LimEiSKG
# IgezJZXFbZgYboDpRZ6e7BjrP2gE428weWq0PftnIufSHWQKSSnmRwgiEy2nMRw+
# R+qWRsNWiAyhbLzTG6XG3rg/j7VgjORGG3fNM76Ms427WmYG37wRSHsNVy3/fe25
# bk05LHnqNdDVN050UGmBxbwe8mKLyyZDVNA/jYc0gogljlqIyQr0zYejFitDLYyg
# c04/JKw7OveV7/hIN1fru6hsaRQ16uUkrMqlNHllTRJ40C7mgLINvqB21OJo3nSU
# ILqbjixeMIIHcTCCBVmgAwIBAgITMwAAABXF52ueAptJmQAAAAAAFTANBgkqhkiG
# 9w0BAQsFADCBiDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAO
# BgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEy
# MDAGA1UEAxMpTWljcm9zb2Z0IFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5IDIw
# MTAwHhcNMjEwOTMwMTgyMjI1WhcNMzAwOTMwMTgzMjI1WjB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIB
# AOThpkzntHIhC3miy9ckeb0O1YLT/e6cBwfSqWxOdcjKNVf2AX9sSuDivbk+F2Az
# /1xPx2b3lVNxWuJ+Slr+uDZnhUYjDLWNE893MsAQGOhgfWpSg0S3po5GawcU88V2
# 9YZQ3MFEyHFcUTE3oAo4bo3t1w/YJlN8OWECesSq/XJprx2rrPY2vjUmZNqYO7oa
# ezOtgFt+jBAcnVL+tuhiJdxqD89d9P6OU8/W7IVWTe/dvI2k45GPsjksUZzpcGkN
# yjYtcI4xyDUoveO0hyTD4MmPfrVUj9z6BVWYbWg7mka97aSueik3rMvrg0XnRm7K
# MtXAhjBcTyziYrLNueKNiOSWrAFKu75xqRdbZ2De+JKRHh09/SDPc31BmkZ1zcRf
# NN0Sidb9pSB9fvzZnkXftnIv231fgLrbqn427DZM9ituqBJR6L8FA6PRc6ZNN3SU
# HDSCD/AQ8rdHGO2n6Jl8P0zbr17C89XYcz1DTsEzOUyOArxCaC4Q6oRRRuLRvWoY
# WmEBc8pnol7XKHYC4jMYctenIPDC+hIK12NvDMk2ZItboKaDIV1fMHSRlJTYuVD5
# C4lh8zYGNRiER9vcG9H9stQcxWv2XFJRXRLbJbqvUAV6bMURHXLvjflSxIUXk8A8
# FdsaN8cIFRg/eKtFtvUeh17aj54WcmnGrnu3tz5q4i6tAgMBAAGjggHdMIIB2TAS
# BgkrBgEEAYI3FQEEBQIDAQABMCMGCSsGAQQBgjcVAgQWBBQqp1L+ZMSavoKRPEY1
# Kc8Q/y8E7jAdBgNVHQ4EFgQUn6cVXQBeYl2D9OXSZacbUzUZ6XIwXAYDVR0gBFUw
# UzBRBgwrBgEEAYI3TIN9AQEwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMBMGA1UdJQQMMAoG
# CCsGAQUFBwMIMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMAsGA1UdDwQEAwIB
# hjAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFNX2VsuP6KJcYmjRPZSQW9fO
# mhjEMFYGA1UdHwRPME0wS6BJoEeGRWh0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9w
# a2kvY3JsL3Byb2R1Y3RzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNybDBaBggr
# BgEFBQcBAQROMEwwSgYIKwYBBQUHMAKGPmh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2kvY2VydHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3J0MA0GCSqGSIb3
# DQEBCwUAA4ICAQCdVX38Kq3hLB9nATEkW+Geckv8qW/qXBS2Pk5HZHixBpOXPTEz
# tTnXwnE2P9pkbHzQdTltuw8x5MKP+2zRoZQYIu7pZmc6U03dmLq2HnjYNi6cqYJW
# AAOwBb6J6Gngugnue99qb74py27YP0h1AdkY3m2CDPVtI1TkeFN1JFe53Z/zjj3G
# 82jfZfakVqr3lbYoVSfQJL1AoL8ZthISEV09J+BAljis9/kpicO8F7BUhUKz/Aye
# ixmJ5/ALaoHCgRlCGVJ1ijbCHcNhcy4sa3tuPywJeBTpkbKpW99Jo3QMvOyRgNI9
# 5ko+ZjtPu4b6MhrZlvSP9pEB9s7GdP32THJvEKt1MMU0sHrYUP4KWN1APMdUbZ1j
# dEgssU5HLcEUBHG/ZPkkvnNtyo4JvbMBV0lUZNlz138eW0QBjloZkWsNn6Qo3GcZ
# KCS6OEuabvshVGtqRRFHqfG3rsjoiV5PndLQTHa1V1QJsWkBRH58oWFsc/4Ku+xB
# Zj1p/cvBQUl+fpO+y/g75LcVv7TOPqUxUYS8vwLBgqJ7Fx0ViY1w/ue10CgaiQuP
# Ntq6TPmb/wrpNPgkNWcr4A245oyZ1uEi6vAnQj0llOZ0dFtq0Z4+7X6gMTN9vMvp
# e784cETRkPHIqzqKOghif9lwY1NNje6CbaUFEMFxBmoQtB1VM1izoXBm8qGCA1Aw
# ggI4AgEBMIH5oYHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046MzMwMy0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WiIwoBATAHBgUrDgMCGgMVAF60
# jOPYL8yR2IjTcTI2wK1I4x1aoIGDMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNV
# BAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jv
# c29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAg
# UENBIDIwMTAwDQYJKoZIhvcNAQELBQACBQDsXfYZMCIYDzIwMjUwODMwMjIxMzQ1
# WhgPMjAyNTA4MzEyMjEzNDVaMHcwPQYKKwYBBAGEWQoEATEvMC0wCgIFAOxd9hkC
# AQAwCgIBAAICBnkCAf8wBwIBAAICE4kwCgIFAOxfR5kCAQAwNgYKKwYBBAGEWQoE
# AjEoMCYwDAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkq
# hkiG9w0BAQsFAAOCAQEARyvGfnxfaZE5xOHtuSc8Ilf1QkfofZq5Pu8nOaCBtQK9
# jnze2BXvaG7yr6BvpW8Xx5z2HF4PqoBwSr9nqYeVpieO+Ou7M5LHqr6zAwnUNbln
# O2o1rg5QWoZajZEKIFSMWg6HWVfFmJoE+oL+dEWeK7mmGTAcoccvWpYv7MszhIms
# BJQA3HJ4MhI2qs8wo7mnQhmdV1g4WlNWrxtz2VpjmTNiJHHneQNIxNElKMmrILOs
# DCB+KFU6CjrftsK0QaHYRIeIAB+bMrWBCPtm4ewt1gFf4kRI4Cz5VcDKRVOkbxQd
# gsAr76RijD/9QImtKXb8h9Q74MYmq2dzS2Y1zT4s9jGCBA0wggQJAgEBMIGTMHwx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1p
# Y3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACD1eaRxRA5kbmAAEAAAIP
# MA0GCWCGSAFlAwQCAQUAoIIBSjAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQw
# LwYJKoZIhvcNAQkEMSIEIB8VxdLWfxt1FPSKl/JeHabX2N/IVmeXxigyO1vMyRHM
# MIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB5DCBvQQg3Ud3lSYqebsVbvE/eeIax8cm
# 3jFHxe74zGBddzSKqfgwgZgwgYCkfjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0Eg
# MjAxMAITMwAAAg9XmkcUQOZG5gABAAACDzAiBCAX7TpxupykNymx/D6ub0wpOES/
# vBJ+v23SohUMZ+H05zANBgkqhkiG9w0BAQsFAASCAgB1lJKTaXz1PEJgkq6Zzkd9
# oGB5P5IevaZju4uv4EeWr0EHcNQTG/uS0+LP/eVFUQEAzGUzY72JwxPztsVQZT9z
# j1+xZc6oTy0eSHbMi5ZJS2RN2uJ+4CVaJ9+cLBfO7FVqa8swnzbH66rLyFO4BUxh
# 2xnjCuSbw/gc1XCrWcpuBSKXWWqlAIXPV+VpQHoFwlebxkpSQ2ZTwPqXn0vBsY3F
# lM62mNLtFWADEi8AwiGwicd9LX6BBkFx8fpGuwWnfNL/743k4q5Lt+U957u+l5H6
# NAccPu7lYnlOVdY2QU22VghHk+CK4RHlDYOZ2nwMY2VCC4bWgHwIX+MGBbsrgqE6
# g6WEehMgVCK3bVRuY4iVDyhy9MkOqZT1NuzvLgkepZFmMUbSLfctV7AN9MmEvgrn
# 8CUmfs5p11rWsDQ7grJd4fCbYPiez/JRIoie31FWtw+KXasL942emSGoMQwT5FeF
# maGq9kzmupDGEw4CeqEQMloI7C3F//BN4BOFdCKHPOLzSGBWxvj5LNSKQEunpzTM
# aCmI00qNLJBhwWMJYdJJMP4hpYnvH2z+iI3xx57vzc3Ijwi99VBlrItJBkGBg7gK
# lCoOV/lHcp3C5/La/2IWGS5TbL/N32EzYem9dmUeCwRVg1AMlMgykSkg/uzYM2uT
# qPYrT7u3J+rEDPJAF/hQ0Q==
# SIG # End signature block
