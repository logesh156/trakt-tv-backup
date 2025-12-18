<#
.SYNOPSIS
    Trakt.tv All-in-One Backup Script (PowerShell Version)

.DESCRIPTION
    1. Self-Authenticating: Run it once to generate tokens interactively via Device Flow.
    2. Auto-Refreshing: Automatically refreshes expired tokens and updates secrets file.
    3. Complete Backup: Downloads Watchlist, Ratings, Collection, Watched, History, Lists (and items), Comments, Social, and Settings.
    4. Zips output to a file in the script directory.

.EXAMPLE
    .\trakt_backup.ps1
    Runs with default hardcoded API keys.
#>

param (
    [string]$ClientId = "YOUR_CLIENT_ID_HERE",
    [string]$ClientSecret = "YOUR_CLIENT_SECRET_HERE"
)

# --- SETUP VARIABLES ---
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Get-Location } # Fallback for some environments
$SecretsFile = Join-Path $ScriptDir "trakt_secrets.json"
$Global:Tokens = $null

# --- HELPER FUNCTIONS ---

function Save-Secrets {
    param ($Access, $Refresh)
    $Data = @{
        client_id     = $ClientId
        client_secret = $ClientSecret
        access_token  = $Access
        refresh_token = $Refresh
    }
    $Data | ConvertTo-Json -Depth 2 | Set-Content -Path $SecretsFile
    $Global:Tokens = $Data
}

function Get-DeviceToken {
    Write-Host "Requesting Device Code..." -ForegroundColor Cyan

    $Body = @{ client_id = $ClientId }
    $Response = Invoke-RestMethod -Uri "https://api.trakt.tv/oauth/device/code" -Method Post -Body ($Body | ConvertTo-Json) -ContentType "application/json"

    Write-Host "`n================================================================" -ForegroundColor Yellow
    Write-Host "PLEASE AUTHORIZE THIS SCRIPT:" -ForegroundColor Yellow
    Write-Host "1. Visit this URL: $($Response.verification_url)" -ForegroundColor White
    Write-Host "2. Enter this code: $($Response.user_code)" -ForegroundColor Green
    Write-Host "================================================================`n"

    $PollUrl = "https://api.trakt.tv/oauth/device/token"
    $PollBody = @{
        code          = $Response.device_code
        client_id     = $ClientId
        client_secret = $ClientSecret
    }
    
    $Interval = $Response.interval
    
    while ($true) {
        Write-Host "Waiting for authorization (checking every $Interval s)..." -NoNewline
        Start-Sleep -Seconds $Interval
        
        try {
            $TokenResponse = Invoke-RestMethod -Uri $PollUrl -Method Post -Body ($PollBody | ConvertTo-Json) -ContentType "application/json" -ErrorAction Stop
            Write-Host "`nSuccess!" -ForegroundColor Green
            return $TokenResponse
        }
        catch {
            $StatusCode = $_.Exception.Response.StatusCode.value__
            if ($StatusCode -eq 400) { 
                # 400 means "Pending" in this flow, just continue loop
                continue 
            }
            else {
                Write-Error "`nError polling for token: $_"
                exit
            }
        }
    }
}

function Refresh-AccessToken {
    Write-Host "Token expired (401). Refreshing..." -ForegroundColor Yellow
    
    if (-not $Global:Tokens.refresh_token) { return $false }

    $Body = @{
        refresh_token = $Global:Tokens.refresh_token
        client_id     = $ClientId
        client_secret = $ClientSecret
        redirect_uri  = "urn:ietf:wg:oauth:2.0:oob"
        grant_type    = "refresh_token"
    }

    try {
        $Response = Invoke-RestMethod -Uri "https://api.trakt.tv/oauth/token" -Method Post -Body ($Body | ConvertTo-Json) -ContentType "application/json" -ErrorAction Stop
        Save-Secrets -Access $Response.access_token -Refresh $Response.refresh_token
        return $true
    }
    catch {
        Write-Error "Failed to refresh token: $_"
        return $false
    }
}

function Fetch-TraktData {
    param (
        [string]$EndpointPath,
        [string]$FileName,
        [string]$TempDir
    )

    $Page = 1
    $Limit = 100
    $AllData = @()
    $RetryAuth = $true

    Write-Host "Backing up: $EndpointPath..." -NoNewline

    do {
        # Loop for handling 401 Retries
        while ($true) {
            $Separator = if ($EndpointPath -match "\?") { "&" } else { "?" }
            
            # Smart URL Handling:
            # If path starts with 'sync/' or 'users/settings', use absolute path. 
            # Otherwise default to 'users/me/' context.
            if ($EndpointPath -match "^(sync|users/settings)") {
                $Url = "https://api.trakt.tv/$EndpointPath$($Separator)page=$Page&limit=$Limit"
            } else {
                $Url = "https://api.trakt.tv/users/me/$EndpointPath$($Separator)page=$Page&limit=$Limit"
            }

            $Headers = @{
                "Authorization"     = "Bearer $($Global:Tokens.access_token)"
                "Content-Type"      = "application/json"
                "trakt-api-key"     = $ClientId
                "trakt-api-version" = "2"
            }

            try {
                $Response = Invoke-WebRequest -Uri $Url -Headers $Headers -Method Get -ErrorAction Stop
                
                $JsonContent = $Response.Content | ConvertFrom-Json
                if ($JsonContent) {
                    $AllData += $JsonContent
                }

                $PageCount = 1
                if ($Response.Headers["X-Pagination-Page-Count"]) {
                    $PageCount = [int]$Response.Headers["X-Pagination-Page-Count"]
                }
                
                break 
            }
            catch {
                $Ex = $_.Exception
                $StatusCode = 0
                if ($Ex.Response) { $StatusCode = [int]$Ex.Response.StatusCode }

                if ($StatusCode -eq 401 -and $RetryAuth) {
                    $RetryAuth = $false 
                    if (Refresh-AccessToken) {
                        continue 
                    }
                    else {
                        Write-Host " [Fatal Auth Error]" -ForegroundColor Red
                        return $null
                    }
                }
                elseif ($StatusCode -eq 404) {
                    break 
                }
                else {
                    Write-Host " [HTTP $StatusCode Error]" -ForegroundColor Red
                    return $null
                }
            }
        }
        
        $Page++
    } while ($Page -le $PageCount)

    # Save to temp file
    if ($AllData.Count -gt 0) {
        $OutFile = Join-Path $TempDir $FileName
        $AllData | ConvertTo-Json -Depth 10 | Set-Content -Path $OutFile -Encoding UTF8
        Write-Host " Done ($($AllData.Count) items)" -ForegroundColor Green
    } else {
        Write-Host " Empty" -ForegroundColor Gray
    }

    # Return data for further processing (e.g., looping through lists)
    return ,$AllData
}

# --- MAIN EXECUTION ---

# 1. Load or Generate Secrets
if (-not (Test-Path $SecretsFile)) {
    Write-Host "No secrets file found ($SecretsFile). Starting initial setup..." -ForegroundColor Cyan
    $TokenData = Get-DeviceToken
    Save-Secrets -Access $TokenData.access_token -Refresh $TokenData.refresh_token
} else {
    $Global:Tokens = Get-Content $SecretsFile | ConvertFrom-Json
}

# 2. Prepare Temp Directory
$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$BackupName = "trakt_backup_$Timestamp"
$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) $BackupName

if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir | Out-Null }

try {
    # 3. Run Backups
    
    # --- CORE USER DATA ---
    Fetch-TraktData "users/settings" "account_settings.json" $TempDir | Out-Null
    Fetch-TraktData "comments" "user_comments.json" $TempDir | Out-Null

    # --- WATCHLIST ---
    Fetch-TraktData "watchlist/movies" "watchlist_movies.json" $TempDir | Out-Null
    Fetch-TraktData "watchlist/shows" "watchlist_shows.json" $TempDir | Out-Null
    Fetch-TraktData "watchlist/episodes" "watchlist_episodes.json" $TempDir | Out-Null
    Fetch-TraktData "watchlist/seasons" "watchlist_seasons.json" $TempDir | Out-Null

    # --- RATINGS ---
    Fetch-TraktData "ratings/movies" "ratings_movies.json" $TempDir | Out-Null
    Fetch-TraktData "ratings/shows" "ratings_shows.json" $TempDir | Out-Null
    Fetch-TraktData "ratings/episodes" "ratings_episodes.json" $TempDir | Out-Null
    Fetch-TraktData "ratings/seasons" "ratings_seasons.json" $TempDir | Out-Null

    # --- COLLECTION ---
    Fetch-TraktData "collection/movies" "collection_movies.json" $TempDir | Out-Null
    Fetch-TraktData "collection/shows" "collection_shows.json" $TempDir | Out-Null

    # --- WATCHED ---
    Fetch-TraktData "watched/movies" "watched_movies.json" $TempDir | Out-Null
    Fetch-TraktData "watched/shows" "watched_shows.json" $TempDir | Out-Null

    # --- HISTORY ---
    Fetch-TraktData "history/movies" "history_movies.json" $TempDir | Out-Null
    Fetch-TraktData "history/shows" "history_shows.json" $TempDir | Out-Null
    Fetch-TraktData "history/episodes" "history_episodes.json" $TempDir | Out-Null

    # --- SOCIAL ---
    Fetch-TraktData "friends" "social_friends.json" $TempDir | Out-Null
    Fetch-TraktData "following" "social_following.json" $TempDir | Out-Null
    Fetch-TraktData "followers" "social_followers.json" $TempDir | Out-Null

    # --- LIKES ---
    Fetch-TraktData "likes/comments" "likes_comments.json" $TempDir | Out-Null
    Fetch-TraktData "likes/lists" "likes_lists.json" $TempDir | Out-Null

    # --- SYNC (PLAYBACK) ---
    Fetch-TraktData "sync/playback" "sync_playback.json" $TempDir | Out-Null

    # --- LISTS & LIST ITEMS ---
    $Lists = Fetch-TraktData "lists" "custom_lists.json" $TempDir
    
    if ($Lists) {
        Write-Host "`nBacking up contents of $($Lists.Count) Custom Lists:" -ForegroundColor Cyan
        foreach ($List in $Lists) {
            # Sanitize filename
            $SafeName = $List.name -replace '[\\/*?:"<>|]', "_"
            $Slug = $List.ids.slug
            # We don't pipe to Out-Null here so we can see progress per list
            Fetch-TraktData "lists/$Slug/items" "list_items_$($SafeName).json" $TempDir | Out-Null
        }
        Write-Host "" # Newline
    }

    # 4. Zip and Cleanup
    $ZipPath = Join-Path $ScriptDir "$BackupName.zip"
    Write-Host "`nCompressing backup to $ZipPath..." -ForegroundColor Cyan
    
    Compress-Archive -Path "$TempDir\*" -DestinationPath $ZipPath -Force
    
    Write-Host "Backup Complete!" -ForegroundColor Green
}
finally {
    # Cleanup temp folder
    if (Test-Path $TempDir) { Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue }
}
