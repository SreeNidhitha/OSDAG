$blobRegex = '"\{(.*body)(.*sig)(.*\bcert\b)(.*\bchain\b).*?\}"'
$onboardingScriptTemplatePath = "./OnboardingScriptTemplate.cmd"
$onboardingScriptBlobPlaceHolder = "{{{blob}}}"

<# 
This value is inserted at build time. See README.md for more details.
#>
$verifiedRootThumbprint = "8F43288AD272F3103B6FB1428485EA3014C0BCFE"

<#
.SYNOPSIS
Parse the blob section from the onboarding script

.DESCRIPTION
The onboarding script purpose is insert the onboarding blob into the registry. This function parse this blob from the onboarding script to start verification.

.PARAMETER onboardingScriptContent
The onboarding script as string (from extension config file)
#>
function Parse-Blob-Content {
    param (
        [Parameter(Mandatory = $true)]
        [string]$onboardingScriptContent
    )
    Write-Log "Attempting to parse onboarding blob from script content"
    
    try {
        $blob = Select-String -InputObject $onboardingScriptContent -Pattern $blobRegex
        
        if ($null -eq $blob) {
            Write-Log "No blob pattern match found in the onboarding script content" -LogLevel Error
            return $null
        }
        
        if ($blob.Matches.Count -ne 1) {
            Write-Log "Found $($blob.Matches.Count) blob matches in the onboarding script, expected exactly 1" -LogLevel Error
            return $null
        }

        Write-Log "Successfully extracted blob from onboarding script"
        return $blob.Matches.Value 
    }
    catch {
        Write-Log "Exception occurred while parsing blob content: $($_.Exception.Message)" -LogLevel Error
        return $null
    }
}

<#
.SYNOPSIS
Verify the signature of a blob wihch came from the onboarding script

.DESCRIPTION
Long description

.PARAMETER blobContent
The package content which contains "body" "sig" "cert" "sha256sig" and "chain"

.NOTES
Due to legacy code, we have to check either Pss abd Pkcs1 padding,
In addition, we must check the signature in reverse order.
We must check sig and sha256sig as well.
!!! On the updated code, we have to verify just PSS padding and dedicated sign field with sha256!!!
#>
function Verify-Signature-And-Certificate {
    param (
        [Parameter(Mandatory = $true)]
        [string]$blobContent
    )
    $json = $blobContent | ConvertFrom-Json
    if ($json.GetType() -eq [string]) {
        $json = $json | ConvertFrom-Json
    }
    
    $body = $json.body
    $cert = $json.cert
    $sig = $json.sig # Legacy sign which we must check as fallback
    $sha256sig = $json.sha256sig 
    $chain = $json.chain

    $isValidSignature = Verify-Signature -content $body -signature $sha256sig -cert $cert
    if ($isValidSignature -eq $false) {
        Write-Log "Signature verification failed on sha256sig, trying sig" -LogLevel Warning
        $isValidSignature = Verify-Signature -content $body -signature $sig -cert $cert
    }

    if ($isValidSignature -eq $false) {
        Write-Log "Signature verification result: $isValidSignature" -LogLevel Error
        return $false
    }

    Write-Log "Signature verification result: $isValidSignature"

    $isValidCertificateChain = Verify-Certificate-Chain -cert $cert -chain $chain
    Write-Log "Certificate chain verification result: $isValidCertificateChain"

    return $isValidSignature -and $isValidCertificateChain  
}

function Verify-Signature {
    param (
        [Parameter(Mandatory = $true)]
        [string]$content,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$signature,
        [Parameter(Mandatory = $true)]
        [string]$cert
    )
    try {
        Write-Log "Verifying JSON signature"
        
        if ([string]::IsNullOrEmpty($signature)) {
            Write-Log "Signature is empty or null, cannot verify" -LogLevel Error
            return $false
        }
        
        $certByteArr = [System.Convert]::FromBase64String($cert)
        Write-Log "Certificate successfully converted from Base64"
        
        $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($certByteArr)
        Write-Log "Successfully retrieved RSA public key"
    
        $contentBytes = [System.Text.Encoding]::UTF8.GetBytes($content)
        Write-Log "Content successfully converted to bytes"
        
        $signatureBytes = [System.Convert]::FromBase64String($signature)
        Write-Log "Signature successfully converted from Base64"    

        [Array]::Reverse($signatureBytes)

        Write-Log "Attempting verification with Pkcs1 padding"
        $isValid = $rsa.VerifyData($contentBytes, $signatureBytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        
        if ($isValid -eq $false) {
            Write-Log "Verification with Pkcs1 padding failed, trying Pss padding" -LogLevel Warning
            $isValid = $rsa.VerifyData($contentBytes, $signatureBytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pss)
        }
        
        Write-Log "Signature verification result: $isValid"
        return $isValid
    }
    catch {
        Write-Log "Error in Verify-Signature: $($_.Exception.message)" -LogLevel Error
        return $false
    }
}

<#
.SYNOPSIS
Verify certificate chain.

.DESCRIPTION
Verify chain, meaning that the certificate is signed by the root certificate

.PARAMETER cert
The certificate in string format.

.PARAMETER chain
The chain, meaning other certificates which sign on our cert.
#>
function Verify-Certificate-Chain {
    param (
        [Parameter(Mandatory = $true)]
        [string]$cert,
        [Parameter(Mandatory = $false)]
        [array]$chain
    )
    $certByteArr = [System.Text.Encoding]::UTF8.GetBytes($cert) 
    $certificate = new-object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(, $certByteArr)
    $chainObj = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Chain
    $chainObj.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::IgnoreNotTimeValid 
    $chainObj.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
    
    Write-Log "Attempting to build certificate chain offline first"
    $isCertValid = $chainObj.Build($certificate)
    if (!$isCertValid) {
        Write-Log "base chain cetificate is not valid because: $($chainObj.ChainStatus.Status); Trying to build chain offline" -LogLevel Warning
    
        foreach ($element in $chain) {
            $elementByteArr = [System.Text.Encoding]::UTF8.GetBytes($element) 
            $elementCertificate = new-object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(, $elementByteArr)
            $null = $chainObj.ChainPolicy.ExtraStore.Add($elementCertificate) # Don't remove unused $null, it is needed to avoid return value stack
            Write-Log "Certificate $($elementCertificate.GetName()) was added to the extraStore"
        }
        $isCertValid = $chainObj.Build($certificate)
    }
    
    $rootCertObj = $chainObj.ChainElements | Where-Object { $_.Certificate.Issuer -eq $_.Certificate.Subject }
    if ($null -eq $rootCertObj -or $null -eq $rootCertObj.Certificate) {
        Write-Log "Root CA certificate could not be found"
        return $false
    }
    $isRootCertValid = Validate-Root-Cert -cert $rootCertObj.Certificate

    Write-Log "Cert valid: $isCertValid; root CA valid: $isRootCertValid"
    return $isRootCertValid -and $isCertValid
}

<#
.SYNOPSIS
Build new onboarding script.

.DESCRIPTION
Create new onboarding script based on template and given signed and verified blob, and save it in the target path.

.PARAMETER Blob
The signed and verified blob content.

.PARAMETER Target
Path to save the new onboarding script.
#>
function Create-OnboardingScript {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Blob,
        [Parameter(Mandatory = $true)]
        [string]$Target
    )
    try {
        $template = Read-file -path $onboardingScriptTemplatePath
        $updatedOnboardingScript = $template.Replace($onboardingScriptBlobPlaceHolder, $Blob)
        
        Out-File -FilePath $Target -InputObject $updatedOnboardingScript -Encoding ASCII
        
        Write-Log "Onboarding script created successfully on $Target"
    } 
    catch {
        ThrowAndWriteLog "Error in Create-OnboardingScript" $_.Exception.Message
    }
}

<#
.SYNOPSIS
Read file content.
#>
function Read-file {
    param (
        [Parameter(Mandatory = $true)]
        [string]$path
    )
    try {
        $content = [System.IO.File]::ReadAllText($path)

        if ([string]::IsNullOrWhiteSpace($content)) {
            ThrowAndWriteLog "Error in Read-file - File is empty"
        }
    
        return $content
    }
    catch {
        ThrowAndWriteLog "Error in Read-file" $_.Exception.Message
    }
}

<#
.SYNOPSIS
Validate that the provided root certificate is identical to the hard-coded root certificate.
.PARAMETER cert
The certificate to validate.
#>
function Validate-Root-Cert {
    param (
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$cert
    )
    if ($cert.Thumbprint -ne $verifiedRootThumbprint) {
        Write-Log "root CA certificate thumbprint is invalid. Found $($cert.Thumbprint)" -LogLevel Error
        return $false
    }

    return $true
}

# SIG # Begin signature block
# MIIoOQYJKoZIhvcNAQcCoIIoKjCCKCYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDEy8TTvxV3kJI2
# XElue8yg16vJzg7t5KxAaWTLXSGkHKCCDYUwggYDMIID66ADAgECAhMzAAAEhJji
# EuB4ozFdAAAAAASEMA0GCSqGSIb3DQEBCwUAMH4xCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25p
# bmcgUENBIDIwMTEwHhcNMjUwNjE5MTgyMTM1WhcNMjYwNjE3MTgyMTM1WjB0MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYDVQQDExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
# AQDtekqMKDnzfsyc1T1QpHfFtr+rkir8ldzLPKmMXbRDouVXAsvBfd6E82tPj4Yz
# aSluGDQoX3NpMKooKeVFjjNRq37yyT/h1QTLMB8dpmsZ/70UM+U/sYxvt1PWWxLj
# MNIXqzB8PjG6i7H2YFgk4YOhfGSekvnzW13dLAtfjD0wiwREPvCNlilRz7XoFde5
# KO01eFiWeteh48qUOqUaAkIznC4XB3sFd1LWUmupXHK05QfJSmnei9qZJBYTt8Zh
# ArGDh7nQn+Y1jOA3oBiCUJ4n1CMaWdDhrgdMuu026oWAbfC3prqkUn8LWp28H+2S
# LetNG5KQZZwvy3Zcn7+PQGl5AgMBAAGjggGCMIIBfjAfBgNVHSUEGDAWBgorBgEE
# AYI3TAgBBggrBgEFBQcDAzAdBgNVHQ4EFgQUBN/0b6Fh6nMdE4FAxYG9kWCpbYUw
# VAYDVR0RBE0wS6RJMEcxLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJh
# dGlvbnMgTGltaXRlZDEWMBQGA1UEBRMNMjMwMDEyKzUwNTM2MjAfBgNVHSMEGDAW
# gBRIbmTlUAXTgqoXNzcitW2oynUClTBUBgNVHR8ETTBLMEmgR6BFhkNodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNDb2RTaWdQQ0EyMDExXzIw
# MTEtMDctMDguY3JsMGEGCCsGAQUFBwEBBFUwUzBRBggrBgEFBQcwAoZFaHR0cDov
# L3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNDb2RTaWdQQ0EyMDEx
# XzIwMTEtMDctMDguY3J0MAwGA1UdEwEB/wQCMAAwDQYJKoZIhvcNAQELBQADggIB
# AGLQps1XU4RTcoDIDLP6QG3NnRE3p/WSMp61Cs8Z+JUv3xJWGtBzYmCINmHVFv6i
# 8pYF/e79FNK6P1oKjduxqHSicBdg8Mj0k8kDFA/0eU26bPBRQUIaiWrhsDOrXWdL
# m7Zmu516oQoUWcINs4jBfjDEVV4bmgQYfe+4/MUJwQJ9h6mfE+kcCP4HlP4ChIQB
# UHoSymakcTBvZw+Qst7sbdt5KnQKkSEN01CzPG1awClCI6zLKf/vKIwnqHw/+Wvc
# Ar7gwKlWNmLwTNi807r9rWsXQep1Q8YMkIuGmZ0a1qCd3GuOkSRznz2/0ojeZVYh
# ZyohCQi1Bs+xfRkv/fy0HfV3mNyO22dFUvHzBZgqE5FbGjmUnrSr1x8lCrK+s4A+
# bOGp2IejOphWoZEPGOco/HEznZ5Lk6w6W+E2Jy3PHoFE0Y8TtkSE4/80Y2lBJhLj
# 27d8ueJ8IdQhSpL/WzTjjnuYH7Dx5o9pWdIGSaFNYuSqOYxrVW7N4AEQVRDZeqDc
# fqPG3O6r5SNsxXbd71DCIQURtUKss53ON+vrlV0rjiKBIdwvMNLQ9zK0jy77owDy
# XXoYkQxakN2uFIBO1UNAvCYXjs4rw3SRmBX9qiZ5ENxcn/pLMkiyb68QdwHUXz+1
# fI6ea3/jjpNPz6Dlc/RMcXIWeMMkhup/XEbwu73U+uz/MIIHejCCBWKgAwIBAgIK
# YQ6Q0gAAAAAAAzANBgkqhkiG9w0BAQsFADCBiDELMAkGA1UEBhMCVVMxEzARBgNV
# BAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jv
# c29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFJvb3QgQ2VydGlm
# aWNhdGUgQXV0aG9yaXR5IDIwMTEwHhcNMTEwNzA4MjA1OTA5WhcNMjYwNzA4MjEw
# OTA5WjB+MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSgwJgYD
# VQQDEx9NaWNyb3NvZnQgQ29kZSBTaWduaW5nIFBDQSAyMDExMIICIjANBgkqhkiG
# 9w0BAQEFAAOCAg8AMIICCgKCAgEAq/D6chAcLq3YbqqCEE00uvK2WCGfQhsqa+la
# UKq4BjgaBEm6f8MMHt03a8YS2AvwOMKZBrDIOdUBFDFC04kNeWSHfpRgJGyvnkmc
# 6Whe0t+bU7IKLMOv2akrrnoJr9eWWcpgGgXpZnboMlImEi/nqwhQz7NEt13YxC4D
# dato88tt8zpcoRb0RrrgOGSsbmQ1eKagYw8t00CT+OPeBw3VXHmlSSnnDb6gE3e+
# lD3v++MrWhAfTVYoonpy4BI6t0le2O3tQ5GD2Xuye4Yb2T6xjF3oiU+EGvKhL1nk
# kDstrjNYxbc+/jLTswM9sbKvkjh+0p2ALPVOVpEhNSXDOW5kf1O6nA+tGSOEy/S6
# A4aN91/w0FK/jJSHvMAhdCVfGCi2zCcoOCWYOUo2z3yxkq4cI6epZuxhH2rhKEmd
# X4jiJV3TIUs+UsS1Vz8kA/DRelsv1SPjcF0PUUZ3s/gA4bysAoJf28AVs70b1FVL
# 5zmhD+kjSbwYuER8ReTBw3J64HLnJN+/RpnF78IcV9uDjexNSTCnq47f7Fufr/zd
# sGbiwZeBe+3W7UvnSSmnEyimp31ngOaKYnhfsi+E11ecXL93KCjx7W3DKI8sj0A3
# T8HhhUSJxAlMxdSlQy90lfdu+HggWCwTXWCVmj5PM4TasIgX3p5O9JawvEagbJjS
# 4NaIjAsCAwEAAaOCAe0wggHpMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBRI
# bmTlUAXTgqoXNzcitW2oynUClTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTAL
# BgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBRyLToCMZBD
# uRQFTuHqp8cx0SOJNDBaBgNVHR8EUzBRME+gTaBLhklodHRwOi8vY3JsLm1pY3Jv
# c29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFf
# MDNfMjIuY3JsMF4GCCsGAQUFBwEBBFIwUDBOBggrBgEFBQcwAoZCaHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFf
# MDNfMjIuY3J0MIGfBgNVHSAEgZcwgZQwgZEGCSsGAQQBgjcuAzCBgzA/BggrBgEF
# BQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9kb2NzL3ByaW1h
# cnljcHMuaHRtMEAGCCsGAQUFBwICMDQeMiAdAEwAZQBnAGEAbABfAHAAbwBsAGkA
# YwB5AF8AcwB0AGEAdABlAG0AZQBuAHQALiAdMA0GCSqGSIb3DQEBCwUAA4ICAQBn
# 8oalmOBUeRou09h0ZyKbC5YR4WOSmUKWfdJ5DJDBZV8uLD74w3LRbYP+vj/oCso7
# v0epo/Np22O/IjWll11lhJB9i0ZQVdgMknzSGksc8zxCi1LQsP1r4z4HLimb5j0b
# pdS1HXeUOeLpZMlEPXh6I/MTfaaQdION9MsmAkYqwooQu6SpBQyb7Wj6aC6VoCo/
# KmtYSWMfCWluWpiW5IP0wI/zRive/DvQvTXvbiWu5a8n7dDd8w6vmSiXmE0OPQvy
# CInWH8MyGOLwxS3OW560STkKxgrCxq2u5bLZ2xWIUUVYODJxJxp/sfQn+N4sOiBp
# mLJZiWhub6e3dMNABQamASooPoI/E01mC8CzTfXhj38cbxV9Rad25UAqZaPDXVJi
# hsMdYzaXht/a8/jyFqGaJ+HNpZfQ7l1jQeNbB5yHPgZ3BtEGsXUfFL5hYbXw3MYb
# BL7fQccOKO7eZS/sl/ahXJbYANahRr1Z85elCUtIEJmAH9AAKcWxm6U/RXceNcbS
# oqKfenoi+kiVH6v7RyOA9Z74v2u3S5fi63V4GuzqN5l5GEv/1rMjaHXmr/r8i+sL
# gOppO6/8MO0ETI7f33VtY5E90Z1WTk+/gFcioXgRMiF670EKsT/7qMykXcGhiJtX
# cVZOSEXAQsmbdlsKgEhr/Xmfwb1tbWrJUnMTDXpQzTGCGgowghoGAgEBMIGVMH4x
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01p
# Y3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMTECEzMAAASEmOIS4HijMV0AAAAA
# BIQwDQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQw
# HAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIB5p
# Qs/2GVXulsixvSj3I/bjCDnApjvwdilAApbg1O02MEIGCisGAQQBgjcCAQwxNDAy
# oBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20wDQYJKoZIhvcNAQEBBQAEggEAQmO3s2ydhlA+Lq8o95rIDVJB8hq/+4RvAQLj
# BojxGzE9RXcmTqa91C3mp7oxw3CUOizy10poKCWdG3s4EFGT7LDBvSVTQTELMXw7
# Epu1du1KYQUnCpadVwV+ewrPBLmyiUF+4FFb54S1GdqGfi17TrdGdygsOT0Efq+U
# AKoHDAtaUAHqwhcsjoIXuxdpTTrpAB/MzuphVkiTQQocmX2V/poX2xI227k/9afT
# /JKJFiSCOB7/mULANkbI4kf2SXv/QEsQBlZsqF9h4C8Q4HQ7KS+5inHOZxX5HE8P
# z7lwMyxCjHM/6AfUsFWouwXuxDWDO4n15eugaStiqQYgNaTObqGCF5QwgheQBgor
# BgEEAYI3AwMBMYIXgDCCF3wGCSqGSIb3DQEHAqCCF20wghdpAgEDMQ8wDQYJYIZI
# AWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGE
# WQoDATAxMA0GCWCGSAFlAwQCAQUABCAsGktFWFKnd7f/V8oXlZffAnI+hPXZT++o
# iZGj0cnDKAIGaKOWZwLpGBMyMDI1MDgzMTA4MTMyOS4zNDlaMASAAgH0oIHRpIHO
# MIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046OTIwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFNlcnZpY2WgghHqMIIHIDCCBQigAwIBAgITMwAAAgkIB+D5XIzmVQAB
# AAACCTANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2Fz
# aGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAx
# MDAeFw0yNTAxMzAxOTQyNTVaFw0yNjA0MjIxOTQyNTVaMIHLMQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1l
# cmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046OTIwMC0w
# NUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2Uw
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDClEow9y4M3f1S9z1xtNEE
# TwWL1vEiiw0oD7SXEdv4sdP0xsVyidv6I2rmEl8PYs9LcZjzsWOHI7dQkRL28GP3
# CXcvY0Zq6nWsHY2QamCZFLF2IlRH6BHx2RkN7ZRDKms7BOo4IGBRlCMkUv9N9/tw
# OzAkpWNsM3b/BQxcwhVgsQqtQ8NEPUuiR+GV5rdQHUT4pjihZTkJwraliz0ZbYpU
# TH5Oki3d3Bpx9qiPriB6hhNfGPjl0PIp23D579rpW6ZmPqPT8j12KX7ySZwNuxs3
# PYvF/w13GsRXkzIbIyLKEPzj9lzmmrF2wjvvUrx9AZw7GLSXk28Dn1XSf62hbkFu
# UGwPFLp3EbRqIVmBZ42wcz5mSIICy3Qs/hwhEYhUndnABgNpD5avALOV7sUfJrHD
# ZXX6f9ggbjIA6j2nhSASIql8F5LsKBw0RPtDuy3j2CPxtTmZozbLK8TMtxDiMCgx
# Tpfg5iYUvyhV4aqaDLwRBsoBRhO/+hwybKnYwXxKeeOrsOwQLnaOE5BmFJYWBOFz
# 3d88LBK9QRBgdEH5CLVh7wkgMIeh96cH5+H0xEvmg6t7uztlXX2SV7xdUYPxA3vj
# jV3EkV7abSHD5HHQZTrd3FqsD/VOYACUVBPrxF+kUrZGXxYInZTprYMYEq6UIG1D
# T4pCVP9DcaCLGIOYEJ1g0wIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFEmL6NHEXTjl
# vfAvQM21dzMWk8rSMB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8G
# A1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# Y3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBs
# BggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0
# LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUy
# MDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUH
# AwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQBcXnxvODwk4h/j
# bUBsnFlFtrSuBBZb7wSZfa5lKRMTNfNlmaAC4bd7Wo0I5hMxsEJUyupHwh4kD5qk
# RZczIc0jIABQQ1xDUBa+WTxrp/UAqC17ijFCePZKYVjNrHf/Bmjz7FaOI41kxueR
# hwLNIcQ2gmBqDR5W4TS2htRJYyZAs7jfJmbDtTcUOMhEl1OWlx/FnvcQbot5VPza
# UwiT6Nie8l6PZjoQsuxiasuSAmxKIQdsHnJ5QokqwdyqXi1FZDtETVvbXfDsofzT
# ta4en2qf48hzEZwUvbkz5smt890nVAK7kz2crrzN3hpnfFuftp/rXLWTvxPQcfWX
# iEuIUd2Gg7eR8QtyKtJDU8+PDwECkzoaJjbGCKqx9ESgFJzzrXNwhhX6Rc8g2EU/
# +63mmqWeCF/kJOFg2eJw7au/abESgq3EazyD1VlL+HaX+MBHGzQmHtvOm3Ql4wVT
# N3Wq8X8bCR68qiF5rFasm4RxF6zajZeSHC/qS5336/4aMDqsV6O86RlPPCYGJOPt
# f2MbKO7XJJeL/UQN0c3uix5RMTo66dbATxPUFEG5Ph4PHzGjUbEO7D35LuEBiiG8
# YrlMROkGl3fBQl9bWbgw9CIUQbwq5cTaExlfEpMdSoydJolUTQD5ELKGz1TJahTi
# dd20wlwi5Bk36XImzsH4Ys15iXRfAjCCB3EwggVZoAMCAQICEzMAAAAVxedrngKb
# SZkAAAAAABUwDQYJKoZIhvcNAQELBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmlj
# YXRlIEF1dGhvcml0eSAyMDEwMB4XDTIxMDkzMDE4MjIyNVoXDTMwMDkzMDE4MzIy
# NVowfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwggIiMA0GCSqGSIb3DQEB
# AQUAA4ICDwAwggIKAoICAQDk4aZM57RyIQt5osvXJHm9DtWC0/3unAcH0qlsTnXI
# yjVX9gF/bErg4r25PhdgM/9cT8dm95VTcVrifkpa/rg2Z4VGIwy1jRPPdzLAEBjo
# YH1qUoNEt6aORmsHFPPFdvWGUNzBRMhxXFExN6AKOG6N7dcP2CZTfDlhAnrEqv1y
# aa8dq6z2Nr41JmTamDu6GnszrYBbfowQHJ1S/rboYiXcag/PXfT+jlPP1uyFVk3v
# 3byNpOORj7I5LFGc6XBpDco2LXCOMcg1KL3jtIckw+DJj361VI/c+gVVmG1oO5pG
# ve2krnopN6zL64NF50ZuyjLVwIYwXE8s4mKyzbnijYjklqwBSru+cakXW2dg3viS
# kR4dPf0gz3N9QZpGdc3EXzTdEonW/aUgfX782Z5F37ZyL9t9X4C626p+Nuw2TPYr
# bqgSUei/BQOj0XOmTTd0lBw0gg/wEPK3Rxjtp+iZfD9M269ewvPV2HM9Q07BMzlM
# jgK8QmguEOqEUUbi0b1qGFphAXPKZ6Je1yh2AuIzGHLXpyDwwvoSCtdjbwzJNmSL
# W6CmgyFdXzB0kZSU2LlQ+QuJYfM2BjUYhEfb3BvR/bLUHMVr9lxSUV0S2yW6r1AF
# emzFER1y7435UsSFF5PAPBXbGjfHCBUYP3irRbb1Hode2o+eFnJpxq57t7c+auIu
# rQIDAQABo4IB3TCCAdkwEgYJKwYBBAGCNxUBBAUCAwEAATAjBgkrBgEEAYI3FQIE
# FgQUKqdS/mTEmr6CkTxGNSnPEP8vBO4wHQYDVR0OBBYEFJ+nFV0AXmJdg/Tl0mWn
# G1M1GelyMFwGA1UdIARVMFMwUQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEW
# M2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5
# Lmh0bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBi
# AEMAQTALBgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV
# 9lbLj+iiXGJo0T2UkFvXzpoYxDBWBgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3Js
# Lm1pY3Jvc29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAx
# MC0wNi0yMy5jcmwwWgYIKwYBBQUHAQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2
# LTIzLmNydDANBgkqhkiG9w0BAQsFAAOCAgEAnVV9/Cqt4SwfZwExJFvhnnJL/Klv
# 6lwUtj5OR2R4sQaTlz0xM7U518JxNj/aZGx80HU5bbsPMeTCj/ts0aGUGCLu6WZn
# OlNN3Zi6th542DYunKmCVgADsAW+iehp4LoJ7nvfam++Kctu2D9IdQHZGN5tggz1
# bSNU5HhTdSRXud2f8449xvNo32X2pFaq95W2KFUn0CS9QKC/GbYSEhFdPSfgQJY4
# rPf5KYnDvBewVIVCs/wMnosZiefwC2qBwoEZQhlSdYo2wh3DYXMuLGt7bj8sCXgU
# 6ZGyqVvfSaN0DLzskYDSPeZKPmY7T7uG+jIa2Zb0j/aRAfbOxnT99kxybxCrdTDF
# NLB62FD+CljdQDzHVG2dY3RILLFORy3BFARxv2T5JL5zbcqOCb2zAVdJVGTZc9d/
# HltEAY5aGZFrDZ+kKNxnGSgkujhLmm77IVRrakURR6nxt67I6IleT53S0Ex2tVdU
# CbFpAUR+fKFhbHP+CrvsQWY9af3LwUFJfn6Tvsv4O+S3Fb+0zj6lMVGEvL8CwYKi
# excdFYmNcP7ntdAoGokLjzbaukz5m/8K6TT4JDVnK+ANuOaMmdbhIurwJ0I9JZTm
# dHRbatGePu1+oDEzfbzL6Xu/OHBE0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZq
# ELQdVTNYs6FwZvKhggNNMIICNQIBATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMx
# EzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoT
# FU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJp
# Y2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjkyMDAtMDVF
# MC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMK
# AQEwBwYFKw4DAhoDFQB8762rPTQd7InDCQdb1kgFKQkCRKCBgzCBgKR+MHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7F3loTAi
# GA8yMDI1MDgzMDIxMDMyOVoYDzIwMjUwODMxMjEwMzI5WjB0MDoGCisGAQQBhFkK
# BAExLDAqMAoCBQDsXeWhAgEAMAcCAQACAiAnMAcCAQACAhLbMAoCBQDsXzchAgEA
# MDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAI
# AgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAGmuVlWfuu9FH/4qFnJ7daiRgyCK
# f5AOzT4KeGxYoX/UdVv5GNYwEWIFC90CK2NbgsQZlAXIaXs/NIZS9cmbBkxdln+2
# QZhEBk3feN79qyRo5vsWOOh9mJVG4wHcqdw+196I3TrZD94fHnQ6+rzVhjPBdnZM
# xxSpMD9nMjww7TdS3U49Kg1eakSIrD+15+WmHOUtrPKU+r4gOeit174mVrEnxeyl
# 9mzydAHLdGpZH225DOyZ5m/8TC0diudZoTzvq5sj24gLNUZW/xOBdHTx3gzy6UcZ
# X4VLS/NWtqs5z9Q7t/NJwTauiHLDmfUbda1wmkFWygjsrqPFzRrdXrw/1R0xggQN
# MIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAgkI
# B+D5XIzmVQABAAACCTANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0G
# CyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCB0KbmV8HEmRXlcdf5zaTCdGCxJ
# LIo3oGUsgtCViSslDjCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIGgbLB7I
# vfQCLmUOUZhjdUqK8bikfB6ZVVdoTjNwhRM+MIGYMIGApH4wfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAIJCAfg+VyM5lUAAQAAAgkwIgQgpZa3k7Ws
# KZpsDsYri8SvyH5E2hBcATF0j9nlUQYM1/owDQYJKoZIhvcNAQELBQAEggIAEZ86
# oiwnESLDdjQzRHyKDpUn/NDwL5sdG01e7gbV9kav8g/ew84N/l5Zk/i+Il3JKu8N
# 7nn00XnMR0/cQjcr9Ltz7QMPJD88EaTMDEtUwgdjpkUq0aWigMTza5cgbZ3s7kmt
# VO/Yli+BhhY4bYXp+udgDKeBkvQr7ph5dYJF2utaVpdkYnO1uZy9G4G4UD2tSAKN
# 0YFIySWzNbx64Vw5ldk0sI7A8RfEddRYPmi87rYTIg6TJ9qIDt9Ltl2H0IzASsTk
# YI+CUbmGT6vutfNl2KsM/dRFucT6II/rcl2WCJeJncT4yvpjqZT4T4Wc2wjROjP4
# aWshtcqZXwh/zR0vW+fdSoifv9fW/0rhS0rk9+3/bYxALISdaJj11sgXZjUPKDaz
# v/nsrC6tNUHQY8qKaCpscoXIQXVoVh1Ett74hKS8lAlETyBsXC8J2mf/tKp9njaY
# TG+IInrHsWh6+/zWgpIgavnN3Fw0cFce9id50vAfJhRX2lc9qwMOKM+dajIKUQdn
# ZQtlkufr9e670kOdacpCtDU961rURRzaa5e7MtIIGx3N6Eok3698A6CdRFBF6JwX
# LdRAAGxzNcqiMxs2JjoAOYtEjIhbaVp96RlxNoSn5Y1A+GxqckBiHU1OetgSQugZ
# cJJ1X05v1ZetRzRjQkwIpw9bW5iWJAgtwTvXgMA=
# SIG # End signature block
