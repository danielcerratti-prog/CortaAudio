param([int]$Port = 18765)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ServerPort = $Port
$script:FFmpegExe = $null

function Resolve-FFmpeg {
  $config = Join-Path $Root 'FFMPEG_PATH.txt'
  if (Test-Path -LiteralPath $config) {
    foreach ($line in [System.IO.File]::ReadAllLines($config)) {
      $candidate = $line.Trim()
      if (!$candidate -or $candidate.StartsWith('#')) { continue }
      $candidate = $candidate.Trim('"')
      if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
  }
  $command = Get-Command 'ffmpeg.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if (!$command) { $command = Get-Command 'ffmpeg' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }
  if ($command -and $command.Source -and (Test-Path -LiteralPath $command.Source)) { return $command.Source }
  $common = @(
    (Join-Path $env:ProgramFiles 'FFmpeg\bin\ffmpeg.exe'),
    (Join-Path $env:ProgramFiles 'ffmpeg\bin\ffmpeg.exe'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\ffmpeg.exe'),
    (Join-Path $Root 'ffmpeg.exe'),
    (Join-Path (Join-Path $Root 'ffmpeg') 'bin\ffmpeg.exe')
  )
  foreach ($candidate in $common) { if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return (Resolve-Path -LiteralPath $candidate).Path } }
  return $null
}

function Send-Headers {
  param([System.IO.Stream]$Stream, [int]$Code, [string]$Reason, [string]$ContentType, [long]$Length, [hashtable]$Extra = @{})
  $text = "HTTP/1.1 $Code $Reason`r`nContent-Type: $ContentType`r`nContent-Length: $Length`r`nCache-Control: no-store`r`nConnection: close`r`nX-Content-Type-Options: nosniff`r`n"
  foreach ($key in $Extra.Keys) { $text += "${key}: $($Extra[$key])`r`n" }
  $text += "`r`n"
  $bytes = [System.Text.Encoding]::ASCII.GetBytes($text)
  $Stream.Write($bytes, 0, $bytes.Length)
}

function Send-Bytes {
  param([System.IO.Stream]$Stream, [int]$Code, [string]$Reason, [string]$ContentType, [byte[]]$Bytes, [hashtable]$Extra = @{})
  Send-Headers -Stream $Stream -Code $Code -Reason $Reason -ContentType $ContentType -Length $Bytes.Length -Extra $Extra
  if ($Bytes.Length -gt 0) { $Stream.Write($Bytes, 0, $Bytes.Length) }
}

function Send-Json {
  param([System.IO.Stream]$Stream, [int]$Code, [object]$Object)
  $json = $Object | ConvertTo-Json -Depth 5 -Compress
  $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
  Send-Bytes -Stream $Stream -Code $Code -Reason $(if ($Code -ge 400) { 'Error' } else { 'OK' }) -ContentType 'application/json; charset=utf-8' -Bytes $bytes
}

function Send-File {
  param([System.IO.Stream]$Stream, [string]$Path, [string]$ContentType)
  $fileStream = [System.IO.File]::OpenRead($Path)
  try {
    Send-Headers -Stream $Stream -Code 200 -Reason 'OK' -ContentType $ContentType -Length $fileStream.Length
    $buffer = New-Object byte[] 65536
    while (($read = $fileStream.Read($buffer, 0, $buffer.Length)) -gt 0) { $Stream.Write($buffer, 0, $read) }
  } finally { $fileStream.Dispose() }
}

function Parse-Query {
  param([string]$Raw)
  $result = @{}
  if ([string]::IsNullOrEmpty($Raw)) { return $result }
  foreach ($part in $Raw.Split('&')) {
    if (!$part) { continue }
    $idx = $part.IndexOf('=')
    if ($idx -lt 0) { $key = $part; $value = '' } else { $key = $part.Substring(0, $idx); $value = $part.Substring($idx + 1) }
    $key = [Uri]::UnescapeDataString($key.Replace('+', ' '))
    $value = [Uri]::UnescapeDataString($value.Replace('+', ' '))
    $result[$key] = $value
  }
  return $result
}

function Quote-Arg {
  param([string]$Value)
  return '"' + $Value.Replace('"', '\"') + '"'
}

function Handle-Client {
  param([System.Net.Sockets.TcpClient]$Client)
  $stream = $Client.GetStream()
  $tempDir = $null
  $responded = $false
  try {
    $headerBytes = New-Object 'System.Collections.Generic.List[byte]'
    while ($true) {
      $b = $stream.ReadByte()
      if ($b -lt 0) { throw 'A conexão foi encerrada antes de receber os cabeçalhos HTTP.' }
      $headerBytes.Add([byte]$b)
      $n = $headerBytes.Count
      if ($n -gt 65536) { throw 'Cabeçalhos HTTP muito grandes.' }
      if ($n -ge 4 -and $headerBytes[$n-4] -eq 13 -and $headerBytes[$n-3] -eq 10 -and $headerBytes[$n-2] -eq 13 -and $headerBytes[$n-1] -eq 10) { break }
    }
    $head = [System.Text.Encoding]::ASCII.GetString($headerBytes.ToArray())
    $lines = $head -split "`r`n"
    $requestParts = $lines[0].Split(' ')
    if ($requestParts.Length -lt 2) { throw 'Requisição HTTP inválida.' }
    $method = $requestParts[0].ToUpperInvariant()
    $target = $requestParts[1]
    $requestHeaders = @{}
    for ($i = 1; $i -lt $lines.Length; $i++) {
      $line = $lines[$i]
      $colon = $line.IndexOf(':')
      if ($colon -gt 0) { $requestHeaders[$line.Substring(0, $colon).Trim().ToLowerInvariant()] = $line.Substring($colon + 1).Trim() }
    }
    $question = $target.IndexOf('?')
    if ($question -ge 0) { $path = $target.Substring(0, $question); $queryRaw = $target.Substring($question + 1) } else { $path = $target; $queryRaw = '' }
    $path = [Uri]::UnescapeDataString($path)
    $query = Parse-Query $queryRaw

    # Keep the local bridge protected from requests initiated by unrelated web pages.
    if ($method -eq 'POST' -and $requestHeaders.ContainsKey('origin')) {
      $expectedOrigin = 'http://127.0.0.1:' + $script:ServerPort
      if ($requestHeaders['origin'] -ne $expectedOrigin) {
        $responded = $true
        Send-Json -Stream $stream -Code 403 -Object @{ok=$false; error='Origem não autorizada.'}
        return
      }
    }

    if ($method -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
      $page = Join-Path $Root 'index.html'
      if (!(Test-Path -LiteralPath $page)) { throw 'O arquivo index.html não foi encontrado.' }
      $responded = $true
      Send-File -Stream $stream -Path $page -ContentType 'text/html; charset=utf-8'
      return
    }

    if ($method -eq 'GET' -and $path -eq '/api/status') {
      $exe = Resolve-FFmpeg
      if (!$exe) {
        $msg = 'FFmpeg não encontrado. Se já está instalado, informe o caminho completo de ffmpeg.exe no arquivo FFMPEG_PATH.txt e reinicie a ferramenta.'
        $responded = $true
        Send-Json -Stream $stream -Code 200 -Object @{ok=$false; message=$msg}
      } else {
        $version = ''
        try { $version = (& $exe -version 2>&1 | Select-Object -First 1 | Out-String).Trim() } catch { $version = 'FFmpeg instalado' }
        $script:FFmpegExe = $exe
        $responded = $true
        Send-Json -Stream $stream -Code 200 -Object @{ok=$true; version=$version; executable=$exe}
      }
      return
    }

    if ($method -eq 'POST' -and $path -in @('/api/cut','/api/preview')) {
      $length = 0L
      if (!$requestHeaders.ContainsKey('content-length')) {
        $lengthValid = $false
      } else {
        $lengthValid = [long]::TryParse($requestHeaders['content-length'], [ref]$length)
      }
      if (!$lengthValid -or $length -le 0) {
        $responded = $true
        Send-Json -Stream $stream -Code 400 -Object @{ok=$false; error='O arquivo de áudio não foi recebido corretamente.'}
        return
      }
      if ($length -gt 2147483648) {
        $responded = $true
        Send-Json -Stream $stream -Code 413 -Object @{ok=$false; error='Arquivo acima de 2 GB. Use um arquivo menor.'}
        return
      }
      $exe = Resolve-FFmpeg
      if (!$exe) {
        $responded = $true
        Send-Json -Stream $stream -Code 500 -Object @{ok=$false; error='FFmpeg não encontrado. Configure FFMPEG_PATH.txt e reinicie.'}
        return
      }
      $from = 0.0; $to = 0.0
      $format = [string]$query['format']
      $quality = [string]$query['quality']
      if ($path -eq '/api/cut') {
        $parseFrom = [double]::TryParse([string]$query['start'], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$from)
        $parseTo = [double]::TryParse([string]$query['end'], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$to)
        if (!$parseFrom -or !$parseTo -or $from -lt 0 -or $to -le $from -or $format -notin @('mp3','wav','m4a','ogg','flac')) {
          $responded = $true
          Send-Json -Stream $stream -Code 400 -Object @{ok=$false; error='Intervalo ou formato de saída inválido.'}
          return
        }
      }

      $tempDir = Join-Path $env:TEMP ('CortaAudio_' + [Guid]::NewGuid().ToString('N'))
      New-Item -ItemType Directory -Path $tempDir | Out-Null
      $originalName = [string]$query['filename']
      $extension = [IO.Path]::GetExtension($originalName)
      if ($extension -notmatch '^\.[A-Za-z0-9]{1,10}$') { $extension = '.audio' }
      $inputPath = Join-Path $tempDir ('entrada' + $extension.ToLowerInvariant())
      $outputPath = Join-Path $tempDir ('corte.' + $format)
      $inputStream = [System.IO.File]::Open($inputPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
      try {
        $remaining = $length
        $buffer = New-Object byte[] 65536
        while ($remaining -gt 0) {
          $toRead = [int][Math]::Min([long]$buffer.Length, $remaining)
          $read = $stream.Read($buffer, 0, $toRead)
          if ($read -le 0) { throw 'A transferência do arquivo foi interrompida.' }
          $inputStream.Write($buffer, 0, $read)
          $remaining -= $read
        }
      } finally { $inputStream.Dispose() }

      if ($path -eq '/api/preview') {
        $previewPath = Join-Path $tempDir 'preview.mp3'
        $previewPsi = New-Object System.Diagnostics.ProcessStartInfo
        $previewPsi.FileName = $exe
        $previewPsi.Arguments = '-hide_banner -loglevel error -nostdin -y -i ' + (Quote-Arg $inputPath) + ' -vn -map 0:a:0 -ac 1 -ar 22050 -c:a libmp3lame -b:a 48k ' + (Quote-Arg $previewPath)
        $previewPsi.UseShellExecute = $false
        $previewPsi.CreateNoWindow = $true
        $previewPsi.RedirectStandardError = $true
        $previewPsi.RedirectStandardOutput = $true
        $previewProc = New-Object System.Diagnostics.Process
        $previewProc.StartInfo = $previewPsi
        [void]$previewProc.Start()
        $previewError = $previewProc.StandardError.ReadToEnd()
        $previewOut = $previewProc.StandardOutput.ReadToEnd()
        $previewProc.WaitForExit()
        if ($previewProc.ExitCode -ne 0 -or !(Test-Path -LiteralPath $previewPath -PathType Leaf)) {
          $detail = $previewError.Trim()
          if (!$detail) { $detail = 'FFmpeg não conseguiu preparar uma prévia deste arquivo.' }
          $responded = $true
          Send-Json -Stream $stream -Code 500 -Object @{ok=$false; error=$detail}
          return
        }
        $responded = $true
        Send-File -Stream $stream -Path $previewPath -ContentType 'audio/mpeg'
        return
      }

      $fromText = $from.ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
      $durationText = ($to - $from).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
      switch ($format) {
        'mp3' {
          $q = switch ($quality) { 'high' { '0' } 'compact' { '5' } default { '2' } }
          $codecArgs = "-c:a libmp3lame -q:a $q"
        }
        'wav' { $codecArgs = '-c:a pcm_s16le' }
        'm4a' {
          $rate = switch ($quality) { 'high' { '256k' } 'compact' { '96k' } default { '192k' } }
          $codecArgs = "-c:a aac -b:a $rate -movflags +faststart"
        }
        'ogg' {
          $q = switch ($quality) { 'high' { '7' } 'compact' { '3' } default { '5' } }
          $codecArgs = "-c:a libvorbis -q:a $q"
        }
        'flac' { $codecArgs = '-c:a flac' }
      }
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = $exe
      $psi.Arguments = '-hide_banner -loglevel error -nostdin -y -ss ' + $fromText + ' -i ' + (Quote-Arg $inputPath) + ' -t ' + $durationText + ' -vn -map 0:a:0 -map_metadata -1 ' + $codecArgs + ' ' + (Quote-Arg $outputPath)
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow = $true
      $psi.RedirectStandardError = $true
      $psi.RedirectStandardOutput = $true
      $proc = New-Object System.Diagnostics.Process
      $proc.StartInfo = $psi
      [void]$proc.Start()
      $stderr = $proc.StandardError.ReadToEnd()
      $stdout = $proc.StandardOutput.ReadToEnd()
      $proc.WaitForExit()
      if ($proc.ExitCode -ne 0 -or !(Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        $detail = $stderr.Trim()
        if (!$detail) { $detail = 'FFmpeg não conseguiu cortar este arquivo.' }
        $responded = $true
        Send-Json -Stream $stream -Code 500 -Object @{ok=$false; error=$detail}
        return
      }
      $mime = switch ($format) { 'mp3' {'audio/mpeg'} 'wav' {'audio/wav'} 'm4a' {'audio/mp4'} 'ogg' {'audio/ogg'} 'flac' {'audio/flac'} default {'application/octet-stream'} }
      $responded = $true
      Send-File -Stream $stream -Path $outputPath -ContentType $mime
      return
    }

    $notFound = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"Recurso não encontrado."}')
    $responded = $true
    Send-Bytes -Stream $stream -Code 404 -Reason 'Not Found' -ContentType 'application/json; charset=utf-8' -Bytes $notFound
  } catch {
    $message = $_.Exception.Message
    Write-Host ('Falha na requisição: ' + $message) -ForegroundColor Yellow
    if (!$responded) { try { Send-Json -Stream $stream -Code 500 -Object @{ok=$false; error=$message} } catch {} }
  } finally {
    if ($tempDir -and (Test-Path -LiteralPath $tempDir)) { try { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
    try { $stream.Dispose() } catch {}
    try { $Client.Close() } catch {}
  }
}

$listener = $null
for ($candidate = $Port; $candidate -lt ($Port + 10); $candidate++) {
  try {
    $candidateListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $candidate)
    $candidateListener.Start()
    $listener = $candidateListener
    $script:ServerPort = $candidate
    break
  } catch {
    try { if ($candidateListener) { $candidateListener.Stop() } } catch {}
  }
}
if (!$listener) {
  Write-Host 'Não foi possível abrir uma porta local para o CortaÁudio. Feche outras cópias da ferramenta e tente novamente.' -ForegroundColor Red
  Read-Host 'Pressione Enter para fechar'
  exit 1
}
$url = 'http://127.0.0.1:' + $script:ServerPort + '/'
Write-Host ''
Write-Host 'CortaÁudio 1.1 iniciado.' -ForegroundColor Green
Write-Host ('Endereço local: ' + $url)
$exeAtStart = Resolve-FFmpeg
if ($exeAtStart) {
  $script:FFmpegExe = $exeAtStart
  Write-Host ('FFmpeg encontrado: ' + $exeAtStart) -ForegroundColor Green
} else {
  Write-Host 'FFmpeg não encontrado automaticamente. Confira FFMPEG_PATH.txt.' -ForegroundColor Yellow
}
Write-Host 'Mantenha esta janela aberta enquanto usa o editor. Para encerrar, pressione Ctrl+C.'
try { Start-Process $url } catch { Write-Host ('Abra este endereço no Edge: ' + $url) }
try {
  while ($true) {
    $client = $listener.AcceptTcpClient()
    Handle-Client -Client $client
  }
} finally {
  try { $listener.Stop() } catch {}
}
