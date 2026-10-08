param(
    [int]$port = 8080
)
$prefix = "http://localhost:$port/"
$root = $PSScriptRoot

if (-not $root) {
    $root = Get-Location
}

function Get-EnvConfig {
    param([string]$rootDir)
    $apiKey = $env:GEMINI_API_KEY
    $model = if ($env:GEMINI_MODEL) { $env:GEMINI_MODEL } else { "gemini-3.8-flash" }

    $envPath = Join-Path $rootDir ".env"
    if (Test-Path $envPath) {
        $lines = [System.IO.File]::ReadAllLines($envPath)
        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ($trimmed -and -not $trimmed.StartsWith("#") -and $trimmed.Contains("=")) {
                $idx = $trimmed.IndexOf("=")
                $key = $trimmed.Substring(0, $idx).Trim()
                $val = $trimmed.Substring($idx + 1).Trim().Trim('"').Trim("'")
                if ($key -eq "GEMINI_API_KEY" -and $val) { $apiKey = $val }
                if ($key -eq "GEMINI_MODEL" -and $val) { $model = $val }
            }
        }
    }

    return @{
        geminiApiKey = if ($apiKey) { $apiKey } else { "" }
        geminiModel = if ($model) { $model } else { "gemini-3.8-flash" }
        hasKey = [bool]$apiKey
    }
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)

try {
    $listener.Start()
    $initialConfig = Get-EnvConfig -rootDir $root
    Write-Host "Local server running at: $prefix"
    Write-Host "Serving files from: $root"
    if ($initialConfig.hasKey) {
        Write-Host "Google Gemini API key linked successfully from .env (Model: $($initialConfig.geminiModel))"
    } else {
        Write-Host "No GEMINI_API_KEY found in .env yet. Add your key to .env to activate auto-linking."
    }
} catch {
    Write-Error "Failed to start HttpListener on $prefix. $_"
    exit 1
}

$mimeTypes = @{
    ".html" = "text/html; charset=utf-8"
    ".htm"  = "text/html; charset=utf-8"
    ".css"  = "text/css; charset=utf-8"
    ".js"   = "application/javascript; charset=utf-8"
    ".json" = "application/json; charset=utf-8"
    ".png"  = "image/png"
    ".jpg"  = "image/jpeg"
    ".jpeg" = "image/jpeg"
    ".gif"  = "image/gif"
    ".svg"  = "image/svg+xml"
    ".ico"  = "image/x-icon"
    ".pdf"  = "application/pdf"
    ".woff" = "font/woff"
    ".woff2"= "font/woff2"
    ".ttf"  = "font/ttf"
}

while ($listener.IsListening) {
    try {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        $rawUrl = $request.RawUrl
        $path = $rawUrl.Split('?')[0]

        # 1. Dynamic /api/config endpoint
        if ($path -eq "/api/config") {
            $config = Get-EnvConfig -rootDir $root
            $json = $config | ConvertTo-Json
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json; charset=utf-8"
            $response.ContentLength64 = $bytes.Length
            $response.StatusCode = 200
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
            $response.OutputStream.Close()
            continue
        }

        # 2. Server-side Gemini Proxy endpoint (eliminates browser CORS & network blocks)
        if ($path -eq "/api/gemini-generate") {
            $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
            $reqBody = $reader.ReadToEnd()
            $clientData = $reqBody | ConvertFrom-Json

            $config = Get-EnvConfig -rootDir $root
            $apiKey = if ($clientData.apiKey) { $clientData.apiKey } else { $config.geminiApiKey }
            $preferredModel = if ($clientData.model) { $clientData.model } else { $config.geminiModel }

            $modelList = @($preferredModel, "gemini-3.8-flash") | 
                         Where-Object { $_ } | 
                         Select-Object -Unique
            $resultPayload = $null
            $lastErr = ""

            foreach ($m in $modelList) {
                try {
                    $url = "https://generativelanguage.googleapis.com/v1beta/models/${m}:generateContent?key=" + [System.Uri]::EscapeDataString($apiKey)
                    $temp = if ($null -ne $clientData.temperature) { [double]$clientData.temperature } else { 0.1 }
                    $maxTokens = if ($clientData.maxTokens) { [int]$clientData.maxTokens } else { 4096 }
                    $postData = @{
                        contents = @(
                            @{ parts = @( @{ text = $clientData.prompt } ) }
                        )
                        generationConfig = @{
                            temperature = $temp
                            maxOutputTokens = $maxTokens
                            responseMimeType = "application/json"
                        }
                    } | ConvertTo-Json -Depth 6

                    $geminiResp = Invoke-RestMethod -Uri $url -Method Post -Body $postData -ContentType "application/json" -TimeoutSec 35
                    $rawText = $geminiResp.candidates[0].content.parts[0].text

                    # Clean markdown code blocks and extract pure JSON
                    $cleanText = $rawText
                    if ($rawText -match '(?s)(\{.*\})') {
                        $cleanText = $matches[1]
                    } else {
                        $cleanText = [regex]::Replace($rawText, '^```(?:json)?\s*', '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                        $cleanText = [regex]::Replace($cleanText, '```\s*$', '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Trim()
                    }

                    $parsedData = $null
                    try {
                        $parsedData = $cleanText | ConvertFrom-Json
                    } catch {
                        # Attempt recovery if output was truncated mid-sentence
                        $lastBrace = $cleanText.LastIndexOf('}')
                        while ($lastBrace -gt 0) {
                            $candidate = $cleanText.Substring(0, $lastBrace + 1)
                            $openB = ($candidate.ToCharArray() | Where-Object { $_ -eq '[' }).Count
                            $closeB = ($candidate.ToCharArray() | Where-Object { $_ -eq ']' }).Count
                            $openC = ($candidate.ToCharArray() | Where-Object { $_ -eq '{' }).Count
                            $closeC = ($candidate.ToCharArray() | Where-Object { $_ -eq '}' }).Count
                            $suffix = (']' * [Math]::Max(0, $openB - $closeB)) + ('}' * [Math]::Max(0, $openC - $closeC))
                            try {
                                $recovered = ($candidate + $suffix) | ConvertFrom-Json
                                if ($recovered) {
                                    $parsedData = $recovered
                                    Write-Host "[Gemini Proxy] Recovered truncated JSON"
                                    break
                                }
                            } catch {}
                            $lastBrace = $cleanText.LastIndexOf('}', $lastBrace - 1)
                        }
                    }

                    if (-not $parsedData) {
                        throw "Failed to extract valid JSON from model output."
                    }

                    $resultPayload = @{
                        success = $true
                        model = $m
                        data = $parsedData
                    }
                    Write-Host "[Gemini Proxy] Success with model: $m ($($parsedData.shortlist.Count) items)"
                    break
                } catch {
                    $lastErr = $_.Exception.Message
                    Write-Host "[Gemini Proxy] Model $m error: $lastErr, attempting fallback..."
                }
            }

            if (-not $resultPayload) {
                $resultPayload = @{
                    success = $false
                    error = "Gemini generation failed: $lastErr"
                }
            }

            $respJson = $resultPayload | ConvertTo-Json -Depth 6
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($respJson)
            $response.ContentType = "application/json; charset=utf-8"
            $response.ContentLength64 = $bytes.Length
            $response.StatusCode = 200
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
            $response.OutputStream.Close()
            continue
        }

        if ($path -eq "/" -or $path -eq "") {
            $path = "/index.html"
        }

        # URL decode and sanitize
        $decodedPath = [System.Uri]::UnescapeDataString($path).TrimStart('/')
        $decodedPath = $decodedPath.Replace('/', '\')
        $filePath = Join-Path $root $decodedPath

        if (Test-Path $filePath -PathType Leaf) {
            $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
            $contentType = if ($mimeTypes.ContainsKey($ext)) { $mimeTypes[$ext] } else { "application/octet-stream" }

            $bytes = [System.IO.File]::ReadAllBytes($filePath)
            $response.ContentType = $contentType
            $response.ContentLength64 = $bytes.Length
            $response.StatusCode = 200
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
        } else {
            $response.StatusCode = 404
            $notFoundBytes = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found: $path")
            $response.ContentType = "text/plain; charset=utf-8"
            $response.ContentLength64 = $notFoundBytes.Length
            $response.OutputStream.Write($notFoundBytes, 0, $notFoundBytes.Length)
        }
        $response.OutputStream.Close()
    } catch {
        # Catch individual request errors without killing the server
    }
}
