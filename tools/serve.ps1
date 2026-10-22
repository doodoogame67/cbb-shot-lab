# Minimal static file server for site/ (no Python/Node on this machine).
# Usage: powershell -ExecutionPolicy Bypass -File tools\serve.ps1 [-Port 8765]
param([int]$Port = 8765)
$root = Join-Path $PSScriptRoot "..\site" | Resolve-Path
$types = @{ ".html" = "text/html; charset=utf-8"; ".csv" = "text/csv; charset=utf-8"; ".js" = "text/javascript"; ".css" = "text/css"; ".json" = "application/json"; ".parquet" = "application/octet-stream" }
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Serving $root at http://localhost:$Port/"
while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $path = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath.TrimStart('/'))
    if ($path -eq "") { $path = "index.html" }
    $file = Join-Path $root $path
    $res = $ctx.Response
    if ((Test-Path $file -PathType Leaf) -and ([IO.Path]::GetFullPath($file).StartsWith($root.Path))) {
        $bytes = [IO.File]::ReadAllBytes($file)
        $ext = [IO.Path]::GetExtension($file)
        $res.ContentType = if ($types[$ext]) { $types[$ext] } else { "application/octet-stream" }
        $res.ContentLength64 = $bytes.Length
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
    } else {
        $res.StatusCode = 404
    }
    $res.Close()
}
