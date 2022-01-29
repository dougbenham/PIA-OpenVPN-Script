# OpenVPN starts its scripts with an entirely different set of environment variables, we need to restore the regular ones
if (-not $env:Username) {
    $PSPath = (Get-Process -Id $PID | Select-Object -ExpandProperty Path)
    Start-Process $PSPath -ArgumentList $MyInvocation.InvocationName -UseNewEnvironment
    Exit
}

Install-Module PsIni

function Parse-JWTtoken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $token
    )
 
    # Validate as per https://tools.ietf.org/html/rfc7519
    # Access and ID tokens are fine, Refresh tokens will not work
    if (!$token.StartsWith("eyJ")) { Write-Error "Invalid token" -ErrorAction Stop }
 
    # Header
    $tokenheader = $token.Split(".")[0].Replace('-', '+').Replace('_', '/')
    # Fix padding as needed, keep adding "=" until string length modulus 4 reaches 0
    while ($tokenheader.Length % 4) { Write-Verbose "Invalid length for a Base-64 char array or string, adding ="; $tokenheader += "=" }
    Write-Verbose "Base64 encoded (padded) header:"
    Write-Verbose $tokenheader
    # Convert from Base64 encoded string to PSObject all at once
    Write-Verbose "Decoded header:"
    $tokenheader = [System.Text.Encoding]::ASCII.GetString([system.convert]::FromBase64String($tokenheader)) | ConvertFrom-Json
    Write-Verbose $tokenheader | fl
 
    # Payload
    if ($token.Contains(".")) {
        $tokenPayload = $token.Split(".")[1].Replace('-', '+').Replace('_', '/')
        # Fix padding as needed, keep adding "=" until string length modulus 4 reaches 0
        while ($tokenPayload.Length % 4) { Write-Verbose "Invalid length for a Base-64 char array or string, adding ="; $tokenPayload += "=" }
        Write-Verbose "Base64 encoded (padded) payoad:"
        Write-Verbose $tokenPayload
        # Convert to Byte array
        $tokenByteArray = [System.Convert]::FromBase64String($tokenPayload)
        # Convert to string array
        $tokenArray = [System.Text.Encoding]::ASCII.GetString($tokenByteArray)
        Write-Verbose "Decoded array in JSON format:"
        Write-Verbose $tokenArray
        # Convert from JSON to PSObject
        $tokobj = $tokenArray | ConvertFrom-Json
        Write-Verbose "Decoded Payload:"
    }
    
    return @{
        Header  = $tokenheader
        Payload = $tokobj
    }
}

$Adapter = Get-NetIPConfiguration | Where-Object { $_.NetProfile?.Name?.StartsWith("OpenVPN TAP") }
if (-not $Adapter) { 
    Write-Error "Cannot find Adapter for OpenVPN TAP"
    Return
}

$Interface = $Adapter.IPv4Address.IPAddress
$PIA_GATEWAY = ((($Interface -split '\.') | Select-Object -First 3) -join '.') + ".1"

Write-Host "Interface: $Interface"
Write-Host "Gateway: $PIA_GATEWAY"

$Pass = Get-Content "Pass.txt"
$PIA_USER = $Pass | Select-Object -First 1
$PIA_PASS = $Pass | Select-Object -Skip 1 -First 1
$Json = (curl -s -u "$($PIA_USER):$($PIA_PASS)" "https://www.privateinternetaccess.com/gtoken/generateToken") | ConvertFrom-Json
$PIA_TOKEN = $Json.token

$Json = (curl -ks --interface $Interface -m 5 -G --data-urlencode "token=${PIA_TOKEN}" "https://$($PIA_GATEWAY):19999/getSignature") | ConvertFrom-Json
$PIA_PAYLOAD = $Json.payload
$PIA_SIGNATURE = $Json.signature

$Jwt = Parse-JWTtoken $PIA_PAYLOAD
$PIA_PORT = $Jwt.Header.port
Write-Host "Port: $PIA_PORT"

$Initialized = $false

While ($true) {
    $Json = (curl -ks --interface $Interface -m 5 -G --data-urlencode "payload=${PIA_PAYLOAD}" --data-urlencode "signature=${PIA_SIGNATURE}" "https://$($PIA_GATEWAY):19999/bindPort") | ConvertFrom-Json
    $Json | Format-List
    if ($Json.status -ne "OK") {
        Exit
    }

    if (-not $Initialized) {
        Stop-Process -Name "qbittorrent" -Force -ErrorAction SilentlyContinue
        
        Write-Host "Setting qBittorrent incoming port."
        $Ini = Get-IniContent "$env:APPDATA\qBittorrent\qBittorrent.Ini"
        $Ini["BitTorrent"]["Session\Port"] = $PIA_PORT # support for older versions
        $Ini["Preferences"]["Connection\PortRangeMin"] = $PIA_PORT # support for newer versions
        $Ini | Out-IniFile "$env:APPDATA\qBittorrent\qBittorrent.Ini" -Force

        Start-Process "$env:ProgramFiles\qBittorrent\qbittorrent.exe" -WorkingDirectory "$env:ProgramFiles\qBittorrent\" -UseNewEnvironment

        $Initialized = $true
    }

    Write-Host "Renewing in 14 minutes.."
    Start-Sleep (60 * 14)
    Write-Host "Renewing.."
}