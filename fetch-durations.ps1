# fetch-durations - 用 YouTube 官方 Data API 批量取视频时长
#
# 由 video-tab-counter 在后台调用，也可以自己手动跑。
# 输入：state.json 里的 ids（标题键 -> 视频 ID）、yt-api-key.txt 里的密钥
# 输出：durations.json（视频 ID -> 秒数）
#
# 官方接口 videos.list 一次最多带 50 个 ID，所以一天的量通常一次请求就够。
# 取不到时长的（已删除 / 私享 / 受限）不会写进结果，下次再试。

param(
  [int]$MaxBatches = 20   # 一次最多发多少个请求（每批 50 个 ID），防止失控
)

$ErrorActionPreference = 'Stop'
$Root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$KeyPath   = Join-Path $Root 'yt-api-key.txt'
$StatePath = Join-Path $Root 'state.json'
$DurPath   = Join-Path $Root 'durations.json'
$LogPath   = Join-Path $Root 'duration-fetch.log'

function Write-Log([string]$m) {
  try { Add-Content -Path $LogPath -Value "$(Get-Date -Format o) $m" -Encoding UTF8 } catch {}
}

function ConvertFrom-Iso8601([string]$d) {
  if (-not $d) { return $null }
  $m = [regex]::Match($d, '^P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$')
  if (-not $m.Success) { return $null }
  $s = 0
  if ($m.Groups[1].Success) { $s += [int]$m.Groups[1].Value * 86400 }
  if ($m.Groups[2].Success) { $s += [int]$m.Groups[2].Value * 3600 }
  if ($m.Groups[3].Success) { $s += [int]$m.Groups[3].Value * 60 }
  if ($m.Groups[4].Success) { $s += [int]$m.Groups[4].Value }
  return $s
}

if (-not (Test-Path $KeyPath)) { Write-Log 'no api key file, nothing to do'; exit 0 }
$key = ([System.IO.File]::ReadAllText($KeyPath, [System.Text.Encoding]::UTF8)).Trim()
if (-not $key) { Write-Log 'empty api key, nothing to do'; exit 0 }

# 已知的 标题键 -> 视频 ID
$ids = @{}
if (Test-Path $StatePath) {
  try {
    $st = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($st.PSObject.Properties['ids']) { foreach ($p in $st.ids.PSObject.Properties) { if ($p.Value) { $ids[$p.Name] = $p.Value } } }
  } catch { Write-Log "state.json unreadable: $($_.Exception.Message)" }
}
if ($ids.Count -eq 0) { Write-Log 'no video ids known yet'; exit 0 }

# 已经取到时长的
$dur = @{}
if (Test-Path $DurPath) {
  try {
    $d = Get-Content $DurPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $d.PSObject.Properties) { $dur[$p.Name] = [int]$p.Value }
  } catch { Write-Log "durations.json unreadable, starting over" }
}

$need = @($ids.Values | Sort-Object -Unique | Where-Object { -not $dur.ContainsKey($_) })
if ($need.Count -eq 0) { Write-Log 'everything cached'; exit 0 }

Write-Log "need $($need.Count) durations"
$batches = 0
for ($i = 0; $i -lt $need.Count -and $batches -lt $MaxBatches; $i += 50) {
  $batch = $need[$i..([Math]::Min($i + 49, $need.Count - 1))]
  $uri = "https://www.googleapis.com/youtube/v3/videos?part=contentDetails&id=$($batch -join ',')&key=$key"
  $batches++
  try {
    $r = Invoke-RestMethod -Uri $uri -TimeoutSec 30
    foreach ($it in $r.items) {
      $sec = ConvertFrom-Iso8601 $it.contentDetails.duration
      if ($sec -ne $null) { $dur[$it.id] = [int]$sec }
    }
    Write-Log "batch $batches ok: asked $($batch.Count), items $($r.items.Count)"
  } catch {
    Write-Log "batch $batches failed: $($_.Exception.Message)"
    break
  }
}

# 写回：普通对象，值按小到大排一下，方便看
$o = [ordered]@{}
foreach ($k in ($dur.Keys | Sort-Object)) { $o[$k] = $dur[$k] }
$json = $o | ConvertTo-Json -Compress
[System.IO.File]::WriteAllText($DurPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Log "durations.json now holds $($dur.Count) entries"
