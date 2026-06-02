param(
    [switch]$Once,
    [switch]$NoEmail,
    [switch]$TestEmail,
    [switch]$ShowDebug
)

$ErrorActionPreference = "Stop"

function Import-DotEnv {
    param([string]$Path = ".env")

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#") -or -not $trimmed.Contains("=")) {
            continue
        }

        $key, $value = $trimmed.Split("=", 2)
        $key = $key.Trim()
        $value = $value.Trim().Trim('"').Trim("'")
        if (-not [Environment]::GetEnvironmentVariable($key, "Process")) {
            [Environment]::SetEnvironmentVariable($key, $value, "Process")
        }
    }
}

function Get-Setting {
    param(
        [string]$Name,
        [string]$Default = ""
    )

    $value = [Environment]::GetEnvironmentVariable($Name, "Process")
    if ($value) {
        return $value
    }
    return $Default
}

function ConvertTo-PageText {
    param([string]$Html)

    $text = [regex]::Replace($Html, "(?is)<script[^>]*>.*?</script>", " ")
    $text = [regex]::Replace($text, "(?is)<style[^>]*>.*?</style>", " ")
    $text = [regex]::Replace($text, "(?s)<[^>]+>", " ")
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    $text = [regex]::Replace($text, "\s+", " ")
    return $text.Trim()
}

function Get-Excerpt {
    param(
        [string]$Text,
        [int]$Start,
        [int]$Length = 280
    )

    $half = [int]($Length / 2)
    $left = [Math]::Max(0, $Start - $half)
    $right = [Math]::Min($Text.Length, $Start + $half)
    $excerpt = $Text.Substring($left, $right - $left).Trim()
    if ($left -gt 0) {
        $excerpt = "..." + $excerpt
    }
    if ($right -lt $Text.Length) {
        $excerpt = $excerpt + "..."
    }
    return $excerpt
}

function Get-Matches {
    param(
        [string]$Html,
        [string[]]$TargetTerms,
        [string[]]$NegativeTerms
    )

    $text = ConvertTo-PageText -Html $Html
    $lowered = $text.ToLowerInvariant()

    foreach ($term in $NegativeTerms) {
        if ($term -and $lowered.Contains($term.ToLowerInvariant())) {
            return @()
        }
    }

    $matches = New-Object System.Collections.Generic.List[string]
    foreach ($term in $TargetTerms) {
        if (-not $term) {
            continue
        }

        $escaped = [regex]::Escape($term.ToLowerInvariant())
        foreach ($hit in [regex]::Matches($lowered, $escaped)) {
            $excerpt = Get-Excerpt -Text $text -Start $hit.Index
            $excerptLower = $excerpt.ToLowerInvariant()
            if ($excerptLower.Contains("sold out") -and -not $excerptLower.Contains("resale")) {
                continue
            }
            if (-not $matches.Contains($excerpt)) {
                $matches.Add($excerpt)
            }
        }
    }

    return $matches.ToArray()
}

function Get-EventMetadata {
    param([string]$Html)

    $eventIdMatch = [regex]::Match($Html, 'event:\{id:"([^"]+)"')
    $eventDateIdMatch = [regex]::Match($Html, '\{a\.id="([^"]+)"')
    $eventTicketsMatch = [regex]::Match($Html, 'eventTickets:"((?:\\.|[^"\\])*)"')

    if (-not $eventIdMatch.Success) {
        throw "Could not find Humanitix event id in page response."
    }
    if (-not $eventDateIdMatch.Success) {
        throw "Could not find Humanitix event date id in page response."
    }
    if (-not $eventTicketsMatch.Success) {
        throw "Could not find Humanitix event ticket metadata in page response."
    }

    $eventTicketsJson = [regex]::Unescape($eventTicketsMatch.Groups[1].Value)
    $eventTickets = $eventTicketsJson | ConvertFrom-Json

    return [pscustomobject]@{
        EventId = $eventIdMatch.Groups[1].Value
        EventDateId = $eventDateIdMatch.Groups[1].Value
        EventTickets = $eventTickets
    }
}

function Test-TicketMatchesTarget {
    param(
        [object]$Ticket,
        [string[]]$TargetTerms
    )

    $names = New-Object System.Collections.Generic.List[string]
    if ($Ticket.name) {
        $names.Add([string]$Ticket.name)
    }
    if ($Ticket.ticketsIncluded) {
        foreach ($included in $Ticket.ticketsIncluded) {
            if ($included.name) {
                $names.Add([string]$included.name)
            }
        }
    }

    foreach ($name in $names) {
        foreach ($term in $TargetTerms) {
            if ($term -and $name.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return $true
            }
        }
    }

    return $false
}

function Get-TargetTickets {
    param(
        [object[]]$EventTickets,
        [string[]]$TargetTerms
    )

    $seen = @{}
    $targetTickets = New-Object System.Collections.Generic.List[object]

    foreach ($group in $EventTickets) {
        foreach ($ticket in $group.tickets) {
            if (-not (Test-TicketMatchesTarget -Ticket $ticket -TargetTerms $TargetTerms)) {
                continue
            }

            $key = [string]$ticket.typeId
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $targetTickets.Add($ticket)
            }
        }
    }

    return $targetTickets.ToArray()
}

function Get-ResaleListingsForTicket {
    param(
        [string]$EventId,
        [string]$EventDateId,
        [object]$Ticket,
        [string]$ResaleUrl
    )

    $resaleItemType = "single"
    if ($Ticket.type -eq "package") {
        $resaleItemType = "package"
    }

    $input = @{
        eventId = $EventId
        eventDateId = $EventDateId
        ticketTypeId = [string]$Ticket.typeId
        resaleItemType = $resaleItemType
        limit = 6
        skip = 0
    } | ConvertTo-Json -Compress

    $encodedInput = [System.Uri]::EscapeDataString($input)
    $apiUrl = "https://events.humanitix.com/trpc/events.getResaleTicketsForEvent?input=$encodedInput"
    $response = Invoke-WebRequest `
        -Uri $apiUrl `
        -UseBasicParsing `
        -Headers @{
            "content-type" = "application/json"
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/125.0 Safari/537.36"
            "Referer" = $ResaleUrl
        } `
        -TimeoutSec 20

    $payload = $response.Content | ConvertFrom-Json
    return @($payload.result.data)
}

function Find-ResaleMatches {
    param(
        [string]$Html,
        [string[]]$TargetTerms,
        [string]$ResaleUrl,
        [bool]$ShowDebug
    )

    $metadata = Get-EventMetadata -Html $Html
    $targetTickets = @(Get-TargetTickets -EventTickets $metadata.EventTickets -TargetTerms $TargetTerms)
    $matches = New-Object System.Collections.Generic.List[object]

    if ($ShowDebug) {
        Write-Host "Debug: found $($targetTickets.Count) ticket types matching target terms."
    }

    foreach ($ticket in $targetTickets) {
        try {
            $listings = @(Get-ResaleListingsForTicket `
                -EventId $metadata.EventId `
                -EventDateId $metadata.EventDateId `
                -Ticket $ticket `
                -ResaleUrl $ResaleUrl)
        }
        catch {
            Write-Warning "Resale API check failed for '$($ticket.name)': $_"
            continue
        }

        if ($ShowDebug) {
            Write-Host "Debug: $($ticket.name) -> $($listings.Count) resale listing(s)."
        }

        foreach ($listing in $listings) {
            if (-not $listing) {
                continue
            }

            $matches.Add([pscustomobject]@{
                ResaleId = [string]$listing.resaleId
                Name = [string]$listing.name
                ListedPrice = [string]$listing.listedPrice
                ChargeNote = [string]$listing.chargeNote
                TicketTypeId = [string]$ticket.typeId
                TicketName = [string]$ticket.name
            })
        }
    }

    return $matches.ToArray()
}

function Get-PreviousSignature {
    param([string]$StateFile)

    if (-not (Test-Path -LiteralPath $StateFile)) {
        return ""
    }

    try {
        $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
        return [string]$state.signature
    }
    catch {
        return ""
    }
}

function Save-Signature {
    param(
        [string]$StateFile,
        [string]$Signature
    )

    [pscustomobject]@{
        signature = $Signature
        updated_at = [DateTimeOffset]::UtcNow.ToString("o")
    } | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Send-AlertEmail {
    param(
        [string]$Subject,
        [string]$Body
    )

    $smtpHost = Get-Setting -Name "SMTP_HOST"
    $smtpPort = [int](Get-Setting -Name "SMTP_PORT" -Default "587")
    $smtpUsername = Get-Setting -Name "SMTP_USERNAME"
    $smtpPassword = Get-Setting -Name "SMTP_PASSWORD"
    $smtpEnableSsl = (Get-Setting -Name "SMTP_ENABLE_SSL" -Default "true").ToLowerInvariant() -ne "false"
    $emailFrom = Get-Setting -Name "EMAIL_FROM"
    $emailTo = Get-Setting -Name "EMAIL_TO"

    $missing = @()
    if (-not $smtpHost) { $missing += "SMTP_HOST" }
    if (-not $smtpUsername) { $missing += "SMTP_USERNAME" }
    if (-not $smtpPassword) { $missing += "SMTP_PASSWORD" }
    if (-not $emailFrom) { $missing += "EMAIL_FROM" }
    if (-not $emailTo) { $missing += "EMAIL_TO" }
    if ($missing.Count -gt 0) {
        throw "Missing required email settings: $($missing -join ', ')"
    }

    $message = [System.Net.Mail.MailMessage]::new($emailFrom, $emailTo, $Subject, $Body)
    $client = [System.Net.Mail.SmtpClient]::new($smtpHost, $smtpPort)
    $client.EnableSsl = $smtpEnableSsl
    $client.Credentials = [System.Net.NetworkCredential]::new($smtpUsername, $smtpPassword)

    try {
        $client.Send($message)
    }
    finally {
        $message.Dispose()
        $client.Dispose()
    }
}

function Invoke-Check {
    param(
        [string]$ResaleUrl,
        [string[]]$TargetTerms,
        [string[]]$NegativeTerms,
        [string]$StateFile,
        [bool]$Notify,
        [bool]$ShowDebug
    )

    $response = Invoke-WebRequest `
        -Uri $ResaleUrl `
        -UseBasicParsing `
        -Headers @{
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/125.0 Safari/537.36"
            "Accept-Language" = "en-US,en;q=0.9"
        } `
        -TimeoutSec 20

    $matches = @(Find-ResaleMatches `
        -Html $response.Content `
        -TargetTerms $TargetTerms `
        -ResaleUrl $ResaleUrl `
        -ShowDebug $ShowDebug)
    $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"

    if ($matches.Count -eq 0) {
        Write-Host "[$now] No matching resale listing found for: $($TargetTerms -join ', ')"
        Save-Signature -StateFile $StateFile -Signature ""
        return $false
    }

    $signature = ($matches | ForEach-Object { "$($_.ResaleId)|$($_.Name)|$($_.ListedPrice)" }) -join "`n"
    $previousSignature = Get-PreviousSignature -StateFile $StateFile
    if ($signature -eq $previousSignature) {
        Write-Host "[$now] Matching listing is still present; alert already sent."
        return $true
    }

    $detailLines = $matches | ForEach-Object {
        $price = if ($_.ListedPrice) { "`$$($_.ListedPrice)" } else { "price not shown" }
        "- $($_.Name) ($price)"
    }
    $detail = $detailLines -join "`n"
    if ($detail.Length -gt 1200) {
        $detail = $detail.Substring(0, 1200)
    }

    $subject = "Pikes Peak resale alert"
    $message = "Pikes Peak alert: matching resale tickets may be available now.`n$ResaleUrl`n`nMatches:`n$detail"
    if ($Notify) {
        Send-AlertEmail -Subject $subject -Body $message
        Write-Host "[$now] Matching listing found. Email sent."
    }
    else {
        Write-Host "[$now] Matching listing found. Email disabled for this run."
        Write-Host $message
    }

    Save-Signature -StateFile $StateFile -Signature $signature
    return $true
}

Import-DotEnv

$resaleUrl = Get-Setting -Name "RESALE_URL" -Default "https://events.humanitix.com/2026-pikes-peak-international-hill-climb/us/resale"
$targetTerms = (Get-Setting -Name "TARGET_TERMS" -Default "Devils Playground,Devil's Playground,Devils Playground Carpool,Devils Playground Single Motorcycle,Devils Playground Double Motorcycle").Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$negativeTerms = (Get-Setting -Name "NEGATIVE_TERMS" -Default "no tickets available,no resale tickets available,there are no tickets available,currently no tickets,nothing available").Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$pollMinSeconds = [Math]::Max(5, [int](Get-Setting -Name "POLL_MIN_SECONDS" -Default (Get-Setting -Name "POLL_SECONDS" -Default "30")))
$pollMaxSeconds = [Math]::Max($pollMinSeconds, [int](Get-Setting -Name "POLL_MAX_SECONDS" -Default "120"))
$stateFile = Get-Setting -Name "STATE_FILE" -Default ".pikes_resale_state.json"

if ($TestEmail) {
    Send-AlertEmail `
        -Subject "Pikes Peak watcher test" `
        -Body "Pikes Peak watcher test: email delivery is configured correctly."
    Write-Host "Test email sent."
    exit 0
}

while ($true) {
    try {
        Invoke-Check `
            -ResaleUrl $resaleUrl `
            -TargetTerms $targetTerms `
            -NegativeTerms $negativeTerms `
            -StateFile $stateFile `
            -Notify (-not $NoEmail) `
            -ShowDebug $ShowDebug | Out-Null
    }
    catch {
        $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"
        Write-Warning "[$now] Check failed: $_"
    }

    if ($Once) {
        exit 0
    }
    $sleepSeconds = Get-Random -Minimum $pollMinSeconds -Maximum ($pollMaxSeconds + 1)
    if ($ShowDebug) {
        Write-Host "Debug: sleeping $sleepSeconds second(s) before next check."
    }
    Start-Sleep -Seconds $sleepSeconds
}
