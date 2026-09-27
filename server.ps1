# Kontur offline host. Serves the game and proxies scene turns to llama-server.
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$app = Join-Path $root "app"
$models = Join-Path $root "models"
$llamaDir = Join-Path $root "llama"
$exe = Join-Path $llamaDir "llama-server.exe"
$prefix = "http://127.0.0.1:8787/"
$llamaBase = "http://127.0.0.1:8088"
$script:llamaProc = $null
$script:ggufItem = $null

function Send-Json($res, [int]$code, [string]$msg) {
  $json = '{"error":' + ($msg | ConvertTo-Json -Compress) + '}'
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  $res.StatusCode = $code
  $res.ContentType = "application/json; charset=utf-8"
  $res.ContentLength64 = $bytes.Length
  $res.OutputStream.Write($bytes, 0, $bytes.Length)
  $res.OutputStream.Close()
}

function Send-Raw($res, [int]$code, [string]$json, [string]$type) {
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  $res.StatusCode = $code
  $res.ContentType = $type
  $res.ContentLength64 = $bytes.Length
  $res.OutputStream.Write($bytes, 0, $bytes.Length)
  $res.OutputStream.Close()
}

function Send-File($res, [string]$full) {
  $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
  $type = switch ($ext) {
    ".html" { "text/html; charset=utf-8" }
    ".js" { "text/javascript; charset=utf-8" }
    ".css" { "text/css; charset=utf-8" }
    ".svg" { "image/svg+xml" }
    ".png" { "image/png" }
    ".jpg" { "image/jpeg" }
    ".webp" { "image/webp" }
    ".json" { "application/json; charset=utf-8" }
    ".woff2" { "font/woff2" }
    default { "application/octet-stream" }
  }
  $bytes = [IO.File]::ReadAllBytes($full)
  $res.StatusCode = 200
  $res.ContentType = $type
  $res.ContentLength64 = $bytes.Length
  $res.OutputStream.Write($bytes, 0, $bytes.Length)
  $res.OutputStream.Close()
}

function Expand-PackedAssets {
  $assets = Join-Path $app "assets"
  if (-not (Test-Path -LiteralPath $assets)) { return }
  Add-Type -AssemblyName System.IO.Compression
  foreach ($name in @("index-Cjn5V7LH.js", "index-Bk1I3cTB.css")) {
    $parts = @(Get-ChildItem -LiteralPath $assets -Filter ($name + ".b64.*") -File | Sort-Object Name)
    if ($parts.Count -eq 0) { continue }
    $b64 = ""
    foreach ($p in $parts) { $b64 += ([System.IO.File]::ReadAllText($p.FullName) -replace '\s', '') }
    $bytes = [Convert]::FromBase64String($b64)
    $packed = New-Object System.IO.MemoryStream(,$bytes)
    $gz = New-Object System.IO.Compression.GzipStream($packed, [System.IO.Compression.CompressionMode]::Decompress)
    $output = New-Object System.IO.MemoryStream
    $gz.CopyTo($output)
    $gz.Close()
    [System.IO.File]::WriteAllBytes((Join-Path $assets $name), $output.ToArray())
    $output.Close()
  }
}
function Get-IndexPath {
  if (Test-Path -LiteralPath (Join-Path $app "index.html")) { return "/index.html" }
  if (Test-Path -LiteralPath (Join-Path $app "win\index.html")) { return "/win/index.html" }
  return ""
}

function Find-Gguf {
  New-Item -ItemType Directory -Force -Path $models | Out-Null
  $hint = Join-Path $root "model.txt"
  if (Test-Path -LiteralPath $hint) {
    $line = (Get-Content -LiteralPath $hint -TotalCount 1 -ErrorAction SilentlyContinue)
    if ($line) {
      $line = ([string]$line).Trim().Trim('"')
      if ($line) {
        $candidate = $line
        if (-not [IO.Path]::IsPathRooted($candidate)) { $candidate = Join-Path $models $line }
        if (Test-Path -LiteralPath $candidate) { return Get-Item -LiteralPath $candidate }
      }
    }
  }
  return Get-ChildItem -LiteralPath $models -Filter *.gguf -File -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Test-LlamaReady {
  try {
    $h = Invoke-WebRequest -Uri "$llamaBase/health" -UseBasicParsing -TimeoutSec 2
    return $h.StatusCode -eq 200
  } catch {
    return $false
  }
}

function Ensure-Runtime {
  if (Test-Path -LiteralPath $exe) { return }
  Write-Host "llama-server.exe was not found in the llama folder."
  Write-Host "Download the Windows CPU build and unpack it into the llama folder:"
  Write-Host "https://github.com/ggml-org/llama.cpp/releases/download/b11223/llama-b11223-bin-win-cpu-x64.zip"
  exit 1
}

function Start-Llama([System.IO.FileInfo]$gguf) {
  if (Test-LlamaReady) {
    Write-Host "llama-server already answers on $llamaBase"
    return
  }
  Ensure-Runtime
  if (-not (Test-Path -LiteralPath $exe)) {
    Write-Host "llama-server.exe is missing. Unpack the zip again."
    exit 1
  }
  Write-Host "Loading $($gguf.Name)"
  Write-Host "First start can take a few minutes. Leave this window open."
  $argList = @("-m", $gguf.FullName, "--host", "127.0.0.1", "--port", "8088", "-c", "8192", "-t", "4", "-ngl", "0")
  $script:llamaProc = Start-Process -FilePath $exe -ArgumentList $argList -WorkingDirectory $llamaDir -PassThru
  $deadline = (Get-Date).AddMinutes(12)
  while ((Get-Date) -lt $deadline) {
    if ($script:llamaProc.HasExited) {
      Write-Host "llama-server stopped before the model was ready."
      exit 1
    }
    if (Test-LlamaReady) {
      Write-Host "Model is ready."
      return
    }
    Start-Sleep -Seconds 2
  }
  Write-Host "The model did not become ready in 12 minutes."
  exit 1
}

function Stop-Llama {
  if ($script:llamaProc -and -not $script:llamaProc.HasExited) {
    & taskkill.exe /PID $script:llamaProc.Id /T /F | Out-Null
  }
}

function Forward-Scene($ctx, [string]$raw) {
  $res = $ctx.Response
  if ($raw.Length -gt 200000) { Send-Json $res 400 "Слишком большой запрос."; return }
  try { $body = $raw | ConvertFrom-Json } catch { Send-Json $res 400 "Запрос не JSON."; return }
  if (-not $body.messages) { Send-Json $res 400 "Нет текста сцены."; return }
  if (-not (Test-LlamaReady)) { Send-Json $res 502 "Локальная модель не отвечает. Перезапусти Start.bat."; return }
  $payloadObj = @{
    model = "local"
    stream = $true
    max_tokens = 1800
    temperature = 0.75
    messages = $body.messages
  }
  $payload = $payloadObj | ConvertTo-Json -Depth 40 -Compress
  $req = [System.Net.HttpWebRequest]::Create("$llamaBase/v1/chat/completions")
  $req.Method = "POST"
  $req.ContentType = "application/json"
  $req.Accept = "text/event-stream"
  $req.Timeout = 180000
  $req.ReadWriteTimeout = 180000
  $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
  $req.ContentLength = $bytes.Length
  $out = $req.GetRequestStream()
  $out.Write($bytes, 0, $bytes.Length)
  $out.Close()
  try { $upstream = $req.GetResponse() }
  catch [System.Net.WebException] {
    $detail = ""
    if ($_.Exception.Response) {
      $er = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
      $detail = $er.ReadToEnd()
      $er.Close()
    }
    if ($detail.Length -gt 180) { $detail = $detail.Substring(0, 180) }
    Send-Json $res 502 ("Локальная модель не приняла ход. " + $detail)
    return
  }
  $res.StatusCode = 200
  $res.ContentType = "text/plain; charset=utf-8"
  $res.SendChunked = $true
  $reader = New-Object IO.StreamReader($upstream.GetResponseStream(), [Text.Encoding]::UTF8)
  $writer = $res.OutputStream
  $enc = [Text.Encoding]::UTF8
  try {
    while (($line = $reader.ReadLine()) -ne $null) {
      $trim = $line.Trim()
      if (-not $trim.StartsWith("data:")) { continue }
      $data = $trim.Substring(5).Trim()
      if (-not $data -or $data -eq "[DONE]") { continue }
      try { $obj = $data | ConvertFrom-Json } catch { continue }
      $choice = $obj.choices
      if ($choice -is [System.Array]) { $choice = $choice[0] }
      $delta = $choice.delta
      if (-not $delta) { continue }
      $piece = [string]$delta.content
      $thought = [string]$delta.reasoning_content
      if ($thought) {
        $packet = (@{ t = $thought } | ConvertTo-Json -Compress -Depth 5) + "`n"
        $buf = $enc.GetBytes($packet)
        $writer.Write($buf, 0, $buf.Length)
      }
      if ($piece) {
        $packet = (@{ c = $piece } | ConvertTo-Json -Compress -Depth 5) + "`n"
        $buf = $enc.GetBytes($packet)
        $writer.Write($buf, 0, $buf.Length)
      }
      $writer.Flush()
    }
  } finally {
    $reader.Close()
    $upstream.Close()
    $writer.Close()
  }
}

$script:ggufItem = Find-Gguf
if (-not $script:ggufItem) {
  Write-Host "Put a .gguf file into the models folder, then start again."
  New-Item -ItemType Directory -Force -Path $models | Out-Null
  Start-Process explorer.exe $models
  exit 1
}
Start-Llama $script:ggufItem
if (-not (Test-Path -LiteralPath $app)) {
  Write-Host "Folder app is missing. Unpack the zip again."
  Stop-Llama
  exit 1
}
Expand-PackedAssets

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
try { $listener.Start() }
catch {
  Write-Host "Port 8787 is busy. Close the other Kontur window and start again."
  Stop-Llama
  exit 1
}
$index = Get-IndexPath
if (-not $index) {
  Write-Host "index.html was not found in app."
  $listener.Stop()
  Stop-Llama
  exit 1
}
Write-Host "Kontur offline: $prefix"
Write-Host "Model: $($script:ggufItem.Name)"
Write-Host "Close this window to stop."
Start-Process ($prefix.TrimEnd("/") + $index)
try {
  while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    try {
      $path = $ctx.Request.Url.AbsolutePath
      if ($ctx.Request.HttpMethod -eq "GET" -and $path -eq "/api/model") {
        $name = $script:ggufItem.Name.Replace("\", "\\").Replace('"', '\"')
        $json = '{"name":"' + $name + '","bytes":' + [int64]$script:ggufItem.Length + '}'
        Send-Raw $ctx.Response 200 $json "application/json; charset=utf-8"
        continue
      }
      if ($ctx.Request.HttpMethod -eq "POST" -and $path -eq "/api/scene") {
        $sr = New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
        $raw = $sr.ReadToEnd()
        $sr.Close()
        Forward-Scene $ctx $raw
        continue
      }
      if ($ctx.Request.HttpMethod -ne "GET" -and $ctx.Request.HttpMethod -ne "HEAD") {
        Send-Json $ctx.Response 404 "Нет такой страницы."
        continue
      }
      $rel = [Uri]::UnescapeDataString($path)
      if ($rel -eq "/") { $rel = $index }
      $rel = $rel.TrimStart("/").Replace("/", [IO.Path]::DirectorySeparatorChar)
      if ($rel.Contains("..")) { Send-Json $ctx.Response 400 "Плохой путь."; continue }
      $full = [IO.Path]::GetFullPath((Join-Path $app $rel))
      $rootFull = [IO.Path]::GetFullPath($app)
      if (-not $rootFull.EndsWith([IO.Path]::DirectorySeparatorChar)) {
        $rootFull = $rootFull + [IO.Path]::DirectorySeparatorChar
      }
      if (-not $full.StartsWith($rootFull)) { Send-Json $ctx.Response 400 "Плохой путь."; continue }
      if (-not (Test-Path -LiteralPath $full) -or (Get-Item -LiteralPath $full).PSIsContainer) {
        Send-Json $ctx.Response 404 "Файл не найден."
        continue
      }
      if ($ctx.Request.HttpMethod -eq "HEAD") {
        $ctx.Response.StatusCode = 200
        $ctx.Response.OutputStream.Close()
        continue
      }
      Send-File $ctx.Response $full
    } catch {
      try { Send-Json $ctx.Response 500 "Сбой локального сервера." } catch {}
    }
  }
} finally {
  if ($listener.IsListening) { $listener.Stop() }
  $listener.Close()
  Stop-Llama
}
