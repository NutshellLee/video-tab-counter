# video-tab-counter - Chrome 视频标签页计数器
# 版本 1.0
#
# 托盘中显示当前打开的视频标签页数量；悬停显示 现在开着 / 今天看完 / 昨天看完。
#
# 数据来源分两路：
#   1) 活的标签页清单 —— 用 UI Automation 直接读 Chrome 的标签栏，实时。
#      （Chrome 的会话文件在运行期间被独占锁定，读不到，所以不能用它做实时来源。）
#   2) 排除表 —— 从 Chrome 可读的那份会话快照里，找出「不是视频页」的标题
#      （首页 / 频道页 / 播放列表页），把同名标签页排除掉。
#
# 不读取 Chrome 历史数据库，不安装任何东西，不调用任何模型，不联网。
#
# 删除方法：结束进程 + 删除本文件夹 + 删除启动文件夹里的快捷方式。

param(
  [switch]$Once,        # 控制台模式：打印一次结果后退出（用于测试）
  [switch]$Detail,      # 控制台模式：打印明细文本后退出（用于测试）
  [switch]$ShowDetail,  # 只为打开一次明细窗口（手动查看用）
  [int]$IntervalSec = 5
)

$ErrorActionPreference = 'Stop'
$Root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$StatePath = Join-Path $Root 'state.json'
$LogPath   = Join-Path $Root 'counter.log'
$SessDir   = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Sessions'
$KeyVersion = 3

function Write-Log([string]$m) {
  try { Add-Content -Path $LogPath -Value "$(Get-Date -Format o) $m" -Encoding UTF8 } catch {}
}

function Get-RawNorm([string]$title) {
  if (-not $title) { return $null }
  $t = $title -replace '^\(\d+\)\s*', ''
  $t = $t -replace '\s*-\s*Audio playing\s*$', ''
  $t = ($t -replace '\s+', ' ').Trim()
  if (-not $t) { return $null }
  return $t.ToLowerInvariant()
}

# 身份键：在原始规范化标题基础上再去掉站点后缀，这样跟按网址回溯出来的标题对得上
function Get-TitleKey([string]$title) {
  $k = Get-RawNorm $title
  if (-not $k) { return $null }
  $k = $k -replace '\s*-\s*youtube$', ''
  $k = $k -replace '_哔哩哔哩_bilibili$', ''
  return $k.Trim()
}

function Test-VideoUrl([string]$url) {
  return ($null -ne (Get-VideoIdFromUrl $url))
}

# 从网址里取出视频 ID；不是视频页就返回 $null
function Get-VideoIdFromUrl([string]$url) {
  if (-not $url) { return $null }
  if ($url -notmatch '^https?://') { $url = 'https://' + $url }
  try { $u = [Uri]$url } catch { return $null }
  $h = $u.Host -replace '^www\.', ''
  if ($h -like '*youtube.com') {
    if ($u.AbsolutePath -eq '/watch') {
      $m = [regex]::Match($url, '[?&]v=([A-Za-z0-9_\-]{11})')
      if ($m.Success) { return $m.Groups[1].Value }
    } elseif ($u.AbsolutePath -like '/shorts/*') {
      $m = [regex]::Match($u.AbsolutePath, '/shorts/([A-Za-z0-9_\-]{11})')
      if ($m.Success) { return $m.Groups[1].Value }
    }
    return $null
  }
  if ($h -like '*bilibili.com') {
    $m = [regex]::Match($u.AbsolutePath, '/(video|bangumi/play)/(BV[0-9A-Za-z]+|av\d+|ep\d+)')
    if ($m.Success) { return $m.Groups[1].Value }
  }
  return $null
}

# ---------------------------------------------------------------- 会话快照（只用来做排除表）

function Read-SnssSnapshot {
  param([string]$Path)

  $bytes = $null
  try {
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
                                 [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $ms = New-Object System.IO.MemoryStream
    $fs.CopyTo($ms); $fs.Dispose()
    $bytes = $ms.ToArray()
  } catch { return $null }

  if ($bytes.Length -lt 12) { return $null }
  if ([System.Text.Encoding]::ASCII.GetString($bytes, 0, 4) -ne 'SNSS') { return $null }

  $enc = [System.Text.Encoding]::GetEncoding(28591)
  $tabs = @{}
  $off  = 8
  while ($off + 3 -le $bytes.Length) {
    $size = [BitConverter]::ToUInt16($bytes, $off)
    if ($size -eq 0) { break }
    $total = $size + 2
    if ($off + $total -gt $bytes.Length) { break }
    $type = $bytes[$off + 2]
    $p    = $off + 3

    if ($type -eq 6) {   # UpdateTabNavigation: pickle, tab_id, nav_index, url(string), title(string16)
      $id  = [BitConverter]::ToUInt32($bytes, $p + 4)
      $idx = [BitConverter]::ToUInt32($bytes, $p + 8)
      $q   = $p + 12
      if ($q + 4 -le $bytes.Length) {
        $len = [BitConverter]::ToUInt32($bytes, $q)
        $q += 4
        if ($len -lt 8192 -and $q + $len -le $bytes.Length) {
          $url = $enc.GetString($bytes, $q, $len)
          $q += $len + ((4 - ($len % 4)) % 4)
          $title = ''
          if ($q + 4 -le $bytes.Length) {
            $chars = [BitConverter]::ToUInt32($bytes, $q)
            $q += 4
            $nbytes = $chars * 2
            if ($chars -lt 4096 -and $q + $nbytes -le $bytes.Length) {
              $title = [System.Text.Encoding]::Unicode.GetString($bytes, $q, $nbytes)
            }
          }
          if (-not $tabs.ContainsKey($id)) { $tabs[$id] = @{ nav = @{}; cur = $null; dead = $false; win = $null } }
          $tabs[$id].nav[$idx] = @{ url = $url; title = $title }
        }
      }
    }
    elseif ($type -eq 0) {
      $w = [BitConverter]::ToUInt32($bytes, $p); $id = [BitConverter]::ToUInt32($bytes, $p + 4)
      if (-not $tabs.ContainsKey($id)) { $tabs[$id] = @{ nav = @{}; cur = $null; dead = $false; win = $null } }
      $tabs[$id].win = $w
    }
    elseif ($type -eq 7) {
      $id = [BitConverter]::ToUInt32($bytes, $p)
      if (-not $tabs.ContainsKey($id)) { $tabs[$id] = @{ nav = @{}; cur = $null; dead = $false; win = $null } }
      $tabs[$id].cur = [BitConverter]::ToUInt32($bytes, $p + 4)
    }
    elseif ($type -eq 16) {
      $id = [BitConverter]::ToUInt32($bytes, $p)
      if (-not $tabs.ContainsKey($id)) { $tabs[$id] = @{ nav = @{}; cur = $null; dead = $false; win = $null } }
      $tabs[$id].dead = $true
    }
    $off += $total
  }

  $list = New-Object System.Collections.ArrayList
  foreach ($id in $tabs.Keys) {
    $t = $tabs[$id]
    if ($t.dead) { continue }
    $url = $null; $title = ''
    if ($t.cur -ne $null -and $t.nav.ContainsKey($t.cur)) { $url = $t.nav[$t.cur].url; $title = $t.nav[$t.cur].title }
    if (-not $url -and $t.nav.Count -gt 0) {
      $best = ($t.nav.Keys | Sort-Object -Descending)[0]
      $url = $t.nav[$best].url; $title = $t.nav[$best].title
    }
    if ($url) { [void]$list.Add(@{ url = $url; title = $title }) }
  }
  return $list
}

function Get-SnapshotMaps {
  $snap = $null
  if (Test-Path $SessDir) {
    # 活的那份被独占锁定，所以按体积从大到小试，取第一份读得出来的
    $cands = Get-ChildItem $SessDir -Filter 'Session_*' -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Length -gt 1000 } | Sort-Object Length -Descending
    foreach ($c in $cands) {
      $r = Read-SnssSnapshot $c.FullName
      if ($null -ne $r -and $r.Count -gt 0) { $snap = $r; break }
    }
  }
  $block = @{}; $ids = @{}
  if ($null -eq $snap) { return [pscustomobject]@{ Block = $block; Ids = $ids } }
  foreach ($t in $snap) {
    if (Test-VideoUrl $t.url) {
      # 快照里有网址也有标题，正好用来学「标题 -> 视频 ID」
      $id = Get-VideoIdFromUrl $t.url
      $k  = Get-TitleKey $t.title
      if ($id -and $k) { $ids['t:' + $k] = $id }
    } else {
      $k = Get-RawNorm $t.title
      if ($k) { $block[$k] = $true }
    }
  }
  return [pscustomobject]@{ Block = $block; Ids = $ids }
}

# ---------------------------------------------------------------- 活的标签页（UI Automation）

function Test-VideoTitle([string]$title, $block) {
  $raw = Get-RawNorm $title          # 带站点后缀，用来判类型和查排除表
  if (-not $raw) { return $false }
  if ($block.ContainsKey($raw)) { return $false }
  if ($raw -eq 'youtube' -or $raw -eq '哔哩哔哩' -or $raw -eq 'bilibili') { return $false }
  if ($raw -like '*- youtube') { return $true }
  if ($raw -like '*_哔哩哔哩_bilibili') { return $true }
  return $false
}

function Get-ChromeTabInfo {
  try {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
  } catch { return $null }

  $proc = Get-Process chrome -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if (-not $proc) { return $null }

  try {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($proc.MainWindowHandle)
    if (-not $root) { return $null }
    $top  = $root.Current.BoundingRectangle.Top
    $cond = New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::TabItem)
    $found = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)

    $titles = New-Object System.Collections.ArrayList
    $selected = $null
    foreach ($t in $found) {
      try {
        if ($t.Current.BoundingRectangle.Top -lt ($top + 100)) {
          [void]$titles.Add($t.Current.Name)
          if ($null -eq $selected) {
            try {
              $sp = $t.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
              if ($sp.Current.IsSelected) { $selected = $t.Current.Name }
            } catch {}
          }
        }
      } catch {}
    }

    # 地址栏就是工具栏区域里的那个编辑框
    $url = $null
    $editCond = New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Edit)
    $edits = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $editCond)
    foreach ($e in $edits) {
      try {
        if ($e.Current.BoundingRectangle.Top -lt ($top + 100)) {
          $url = $e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
          break
        }
      } catch {}
    }
  } catch { return $null }

  return [pscustomobject]@{ Titles = $titles; Selected = $selected; Url = $url }
}

function Get-LiveTabTitles {
  $info = Get-ChromeTabInfo
  if ($null -eq $info) { return $null }
  return $info.Titles
}

# 当前打开的视频标签页集合（键 = 规范化标题，值 = 原样标题，用于明细显示）
function Get-OpenVideoSet($block, $info) {
  if ($null -eq $info) { return $null }
  $set = @{}
  foreach ($t in $info.Titles) {
    if (Test-VideoTitle $t $block) {
      $k = Get-TitleKey $t
      if ($k) { $set['t:' + $k] = $t }
    }
  }
  return $set
}

# 从地址栏学「标题 -> 视频 ID」：只有当前选中的标签页读得到网址
function Learn-IdFromAddressBar($state, $info) {
  if ($null -eq $info -or -not $info.Url -or -not $info.Selected) { return }
  $id = Get-VideoIdFromUrl $info.Url
  if (-not $id) { return }
  $k = Get-TitleKey $info.Selected
  if (-not $k) { return }
  $key = 't:' + $k
  if ($state.ids.PSObject.Properties[$key]) { return }
  $state.ids | Add-Member -NotePropertyName $key -NotePropertyValue $id
}

function Test-ChromeRunning {
  return [bool](Get-Process chrome -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------- 状态

function Load-State {
  if (Test-Path $StatePath) {
    try { return (Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
  }
  return $null
}

function Save-State($s) {
  $json = $s | ConvertTo-Json -Depth 6 -Compress
  [System.IO.File]::WriteAllText($StatePath, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function New-State {
  return [pscustomobject]@{
    open       = [pscustomobject]@{}
    opened     = [pscustomobject]@{}
    closed     = [pscustomobject]@{}
    titles     = [pscustomobject]@{}
    seeded     = $false
    keyVersion = $KeyVersion
  }
}

function Get-DayKey([datetime]$d) { return $d.ToString('yyyy-MM-dd') }

function Ensure-Day($state, [string]$d) {
  if (-not $state.opened.PSObject.Properties[$d]) { $state.opened | Add-Member -NotePropertyName $d -NotePropertyValue @() }
  if (-not $state.closed.PSObject.Properties[$d]) { $state.closed | Add-Member -NotePropertyName $d -NotePropertyValue @() }
}

# ---------------------------------------------------------------- 一轮

function Step($state, [datetime]$now, $block) {
  if (-not (Test-ChromeRunning)) { return $true }   # Chrome 没跑：冻结，什么都不改

  $info = Get-ChromeTabInfo
  if ($null -eq $info) { return $false }            # 读不到标签栏：放弃这一轮，保住旧状态

  $openNow = Get-OpenVideoSet $block $info
  if ($null -eq $openNow) { return $false }

  if (-not $state.PSObject.Properties['ids']) { $state | Add-Member -NotePropertyName ids -NotePropertyValue ([pscustomobject]@{}) }
  Learn-IdFromAddressBar $state $info

  $today = Get-DayKey $now
  Ensure-Day $state $today

  $prev = @{}
  if ($state.open) { foreach ($p in $state.open.PSObject.Properties) { $prev[$p.Name] = $true } }

  if ($state.seeded) {
    $appeared = @(); $gone = @()
    foreach ($k in $openNow.Keys) { if (-not $prev.ContainsKey($k)) { $appeared += $k } }
    foreach ($k in $prev.Keys)    { if (-not $openNow.ContainsKey($k)) { $gone += $k } }

    # 保护：一次性少掉很多，当成浏览器没恢复标签页，不计入
    if ($gone.Count -gt 20 -and $gone.Count -gt ($prev.Count * 0.5)) { $gone = @() }

    if ($appeared.Count) { $state.opened.$today = @(@($state.opened.$today) + $appeared | Sort-Object -Unique) }
    if ($gone.Count)     { $state.closed.$today = @(@($state.closed.$today) + $gone     | Sort-Object -Unique) }
  }

  # 记下每个键对应的原样标题，明细窗口要显示
  if (-not $state.PSObject.Properties['titles']) { $state | Add-Member -NotePropertyName titles -NotePropertyValue ([pscustomobject]@{}) }
  foreach ($k in $openNow.Keys) {
    $val = $openNow[$k]
    if ($state.titles.PSObject.Properties[$k]) { $state.titles.$k = $val }
    else { $state.titles | Add-Member -NotePropertyName $k -NotePropertyValue $val }
  }

  $o = [pscustomobject]@{}
  foreach ($k in $openNow.Keys) { $o | Add-Member -NotePropertyName $k -NotePropertyValue $true }
  $state.open = $o
  $state.seeded = $true
  return $true
}

# ---------------------------------------------------------------- 明细文本

function Get-DisplayTitle($state, [string]$key) {
  if ($state.PSObject.Properties['titles'] -and $state.titles.PSObject.Properties[$key]) { return $state.titles.$key }
  return ($key -replace '^[a-z]+:', '')
}

function Apply-Snapshot($state) {
  $maps = Get-SnapshotMaps
  if ($null -eq $state.PSObject.Properties['ids']) { $state | Add-Member -NotePropertyName ids -NotePropertyValue ([pscustomobject]@{}) }
  foreach ($k in $maps.Ids.Keys) {
    if (-not $state.ids.PSObject.Properties[$k]) { $state.ids | Add-Member -NotePropertyName $k -NotePropertyValue $maps.Ids[$k] }
  }
  return $maps.Block
}

function Get-Durations {
  $p = Join-Path $Root 'durations.json'
  if (-not (Test-Path $p)) { return @{} }
  $stamp = (Get-Item $p).LastWriteTimeUtc.Ticks
  if ($script:DurMap -and $script:DurStamp -eq $stamp) { return $script:DurMap }
  $map = @{}
  try {
    $d = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($x in $d.PSObject.Properties) { $map[$x.Name] = [int]$x.Value }
  } catch {}
  $script:DurMap = $map
  $script:DurStamp = $stamp
  return $map
}

function Format-HM([int]$seconds) {
  if ($seconds -le 0) { return '0分' }
  $h = [int]($seconds / 3600); $m = [int](($seconds % 3600) / 60)
  if ($h -gt 0) { return "${h}小时${m}分" }
  return "${m}分"
}

# 托盘悬停提示（上限 63 个字符，超了要退回短格式）
function Get-TrayText($state, $durMap, $n, [datetime]$now) {
  $dt = Get-DayDuration $state $durMap (Get-DayKey $now)
  $dy = Get-DayDuration $state $durMap (Get-DayKey $now.AddDays(-1))
  # 没有时长数据（还没配密钥）时就别写「共 0分」
  $l1 = if ($dt.Total -gt 0) { "今天看完：$($n.Today) 个，共 $(Format-HM $dt.Total)" } else { "今天看完：$($n.Today) 个" }
  $l2 = if ($dy.Total -gt 0) { "昨天看完：$($n.Yesterday) 个，共 $(Format-HM $dy.Total)" } else { "昨天看完：$($n.Yesterday) 个" }
  $full = "视频标签页`n现在开着：$($n.Open) 个`n$l1`n$l2"
  if ($full.Length -le 63) { return $full }
  $mid = "视频标签页`n现在开着：$($n.Open) 个`n今天看完：$($n.Today) 个`n昨天看完：$($n.Yesterday) 个"
  if ($mid.Length -le 63) { return $mid }
  return "视频标签页`n现在开着：$($n.Open) 个"
}

# 某一天看完的视频，加起来多少时长
function Get-DayDuration($state, $durMap, [string]$day) {
  $total = 0; $unknown = 0; $count = 0
  if ($state.closed.PSObject.Properties[$day]) {
    foreach ($k in @($state.closed.$day)) {
      $count++
      $id = $null
      if ($state.PSObject.Properties['ids'] -and $state.ids.PSObject.Properties[$k]) { $id = $state.ids.$k }
      if ($id -and $durMap.ContainsKey($id)) { $total += [int]$durMap[$id] } else { $unknown++ }
    }
  }
  return [pscustomobject]@{ Total = $total; Unknown = $unknown; Count = $count }
}

function Build-DetailText($state, [datetime]$now) {
  $today  = Get-DayKey $now
  $yest   = Get-DayKey $now.AddDays(-1)
  $sb = New-Object System.Text.StringBuilder

  [void]$sb.AppendLine("生成时间：$($now.ToString('yyyy-MM-dd HH:mm:ss'))")

  $durMap = Get-Durations

  # 今天 / 昨天放在最前面：这两块才是这个工具的重点。
  # 「现在开着」放最后，因为打开浏览器自己就能看到，优先级最低。
  $rank = 0
  foreach ($pair in @(@('今天看完', $today), @('昨天看完', $yest))) {
    $label = $pair[0]; $day = $pair[1]
    $rank++
    $keys = @()
    if ($state.closed.PSObject.Properties[$day]) { $keys = @($state.closed.$day) }
    $d = Get-DayDuration $state $durMap $day
    $sum = "共 $($d.Count) 个 · 合计 $(Format-HM $d.Total)"
    if ($d.Unknown -gt 0) { $sum += "（$($d.Unknown) 个时长未知，未计入）" }

    # 按播放顺序不好还原，就按时长从长到短排，长的排前面
    $rows = foreach ($k in $keys) {
      $id = $null
      if ($state.PSObject.Properties['ids'] -and $state.ids.PSObject.Properties[$k]) { $id = $state.ids.$k }
      $sec = if ($id -and $durMap.ContainsKey($id)) { [int]$durMap[$id] } else { -1 }
      [pscustomobject]@{ Title = (Get-DisplayTitle $state $k); Sec = $sec }
    }
    $rows = @($rows | Sort-Object -Property @{Expression='Sec';Descending=$true}, Title)

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("【$label】$day  $sum")
    if ($rows.Count -eq 0) { [void]$sb.AppendLine('    （没有）') }
    foreach ($r in $rows) {
      if ($r.Sec -ge 0) { [void]$sb.AppendLine("    [$(Format-HM $r.Sec)] $($r.Title)") }
      else              { [void]$sb.AppendLine("    [时长未知] $($r.Title)") }
    }
  }

  # 最后才是「现在开着」
  $openKeys = @()
  if ($state.open) { $openKeys = @($state.open.PSObject.Properties | ForEach-Object { $_.Name }) }
  $openTitles = $openKeys | ForEach-Object { Get-DisplayTitle $state $_ } | Sort-Object
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine("【现在开着】$($openTitles.Count) 个")
  foreach ($t in $openTitles) { [void]$sb.AppendLine("    $t") }

  return $sb.ToString()
}

# ---------------------------------------------------------------- 面板（自绘）
# 三个工具共用同一套外观：同一个尺寸、同一套配色、同一种画法。

# 下面要用 System.Drawing 的类型，先把程序集加载进来（不加载会报找不到类型）
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:UiBg    = [System.Drawing.Color]::FromArgb(255, 249, 250, 251)
$script:UiText  = [System.Drawing.Color]::FromArgb(255, 28, 32, 38)
$script:UiMuted = [System.Drawing.Color]::FromArgb(255, 138, 147, 158)
$script:UiWork  = [System.Drawing.Color]::FromArgb(255, 45, 108, 223)
$script:UiFun   = [System.Drawing.Color]::FromArgb(255, 240, 148, 65)
$script:UiGreen = [System.Drawing.Color]::FromArgb(255, 58, 167, 109)
$script:UiTrack = [System.Drawing.Color]::FromArgb(255, 232, 236, 241)
$script:UiLine  = [System.Drawing.Color]::FromArgb(255, 222, 227, 233)

function Get-UiFonts {
  if (-not $script:FTitle) {
    $script:FTitle = New-Object System.Drawing.Font 'Microsoft YaHei UI', 21, ([System.Drawing.FontStyle]::Bold)
    $script:FTab   = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9.5
    $script:FTabB  = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9.5, ([System.Drawing.FontStyle]::Bold)
    $script:FSub   = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9
    $script:FApp   = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9
    $script:FTiny  = New-Object System.Drawing.Font 'Microsoft YaHei UI', 7.5
  }
}

function New-RoundRect([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  if ($r -le 0 -or $w -le 0 -or $h -le 0) { $p.AddRectangle((New-Object System.Drawing.RectangleF $x, $y, $w, $h)); return $p }
  if ($r -gt $h / 2) { $r = $h / 2 }
  if ($r -gt $w / 2) { $r = $w / 2 }
  $d = $r * 2
  $p.AddArc($x, $y, $d, $d, 180, 90)
  $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
  $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
  $p.CloseFigure()
  return $p
}

function Format-Dur([int]$sec) {
  if ($sec -le 0) { return '0 分' }
  if ($sec -lt 60) { return "$sec 秒" }
  $h = [int]($sec / 3600); $m = [int](($sec % 3600) / 60)
  if ($h -gt 0 -and $m -gt 0) { return "$h 小时 $m 分" }
  if ($h -gt 0) { return "$h 小时" }
  return "$m 分"
}

# 标题太长就截断加省略号
function Limit-Text($g, [string]$t, $font, [int]$maxW) {
  if ([string]::IsNullOrEmpty($t)) { return '' }
  if ($g.MeasureString($t, $font).Width -le $maxW) { return $t }
  $s = $t
  while ($s.Length -gt 1 -and $g.MeasureString(($s + '…'), $font).Width -gt $maxW) { $s = $s.Substring(0, $s.Length - 1) }
  return $s + '…'
}

# 面板上一个档期（今天/昨天/近 7 天）要用的数据
function Get-PanelRange($state, $durMap, [datetime]$now, [int]$rng) {
  if ($rng -eq 2) {
    $total = 0; $count = 0; $unknown = 0
    for ($i = 0; $i -lt 7; $i++) {
      $d = Get-DayDuration $state $durMap (Get-DayKey $now.AddDays(-$i))
      $total += [int]$d.Total; $count += [int]$d.Count; $unknown += [int]$d.Unknown
    }
    return [pscustomobject]@{ Total = $total; Count = $count; Unknown = $unknown; Day = $null }
  }
  $day = Get-DayKey $now.AddDays(-$rng)
  $d = Get-DayDuration $state $durMap $day
  return [pscustomobject]@{ Total = [int]$d.Total; Count = [int]$d.Count; Unknown = [int]$d.Unknown; Day = $day }
}

# 面板上要列的视频（今天/昨天按当天，近 7 天按这七天的）
function Get-PanelVideos($state, $durMap, [datetime]$now, [int]$rng) {
  $keys = @()
  if ($rng -eq 2) {
    for ($i = 0; $i -lt 7; $i++) {
      $k = Get-DayKey $now.AddDays(-$i)
      if ($state.closed.PSObject.Properties[$k]) { $keys += @($state.closed.$k) }
    }
    $keys = @($keys | Select-Object -Unique)
  } else {
    $k = Get-DayKey $now.AddDays(-$rng)
    if ($state.closed.PSObject.Properties[$k]) { $keys = @($state.closed.$k) }
  }
  $rows = foreach ($k in $keys) {
    $id = $null
    if ($state.PSObject.Properties['ids'] -and $state.ids.PSObject.Properties[$k]) { $id = $state.ids.$k }
    $sec = if ($id -and $durMap.ContainsKey($id)) { [int]$durMap[$id] } else { 0 }
    [pscustomobject]@{ Title = (Get-DisplayTitle $state $k); Sec = $sec }
  }
  return @($rows | Sort-Object -Property @{Expression='Sec';Descending=$true}, Title | Select-Object -First 6)
}

function Draw-Panel($g, [int]$w, [int]$h) {
  Get-UiFonts
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
  $g.Clear($script:UiBg)

  $now = Get-Date
  $st = $script:State
  $durMap = Get-Durations
  $rng = [int]$script:PanelRange

  $info = Get-PanelRange $st $durMap $now $rng
  $bText = New-Object System.Drawing.SolidBrush $script:UiText
  $bMuted = New-Object System.Drawing.SolidBrush $script:UiMuted

  # ---- 顶部三个标签
  $tabs = @('今天', '昨天', '近 7 天')
  $tx = 16
  $script:TabRects = @()
  for ($i = 0; $i -lt 3; $i++) {
    $fnt = if ($i -eq $rng) { $script:FTabB } else { $script:FTab }
    $col = if ($i -eq $rng) { $script:UiWork } else { $script:UiMuted }
    $sz = $g.MeasureString($tabs[$i], $fnt)
    $br = New-Object System.Drawing.SolidBrush $col
    $g.DrawString($tabs[$i], $fnt, $br, $tx, 12)
    $br.Dispose()
    $script:TabRects += [pscustomobject]@{ x = $tx; w = [int]$sz.Width; i = $i }
    if ($i -eq $rng) {
      $pen = New-Object System.Drawing.Pen $script:UiWork, 2
      $g.DrawLine($pen, $tx, 32, $tx + $sz.Width - 2, 32)
      $pen.Dispose()
    }
    $tx += [int]$sz.Width + 18
  }

  # ---- 大字号：看完的总时长
  $big = Format-Dur $info.Total
  $g.DrawString($big, $script:FTitle, $bText, 14, 44)
  $szBig = $g.MeasureString($big, $script:FTitle)
  $openN = if ($st.open) { @($st.open.PSObject.Properties).Count } else { 0 }
  $sub = "共 $($info.Count) 个"
  if ($info.Unknown -gt 0) { $sub += "   ·   $($info.Unknown) 个时长未知" }
  $sub += "   ·   现在开着 $openN 个"
  $g.DrawString($sub, $script:FSub, $bMuted, 18, 40 + $szBig.Height)

  # ---- 视频列表
  $g.DrawString('看的视频', $script:FTabB, $bText, 16, 116)
  $y = 138
  $vids = Get-PanelVideos $st $durMap $now $rng
  if ($vids.Count -eq 0) {
    $g.DrawString('（还没有）', $script:FTiny, $bMuted, 16, $y)
  } else {
    $maxV = 1
    foreach ($v in $vids) { if ($v.Sec -gt $maxV) { $maxV = $v.Sec } }
    foreach ($v in $vids) {
      $t = Limit-Text $g $v.Title $script:FApp 190
      $g.DrawString($t, $script:FApp, $bText, 16, $y)
      $bx = 218; $bw = 118; $bh = 9
      $gp = New-RoundRect $bx ($y + 3) $bw $bh 4
      $b = New-Object System.Drawing.SolidBrush $script:UiTrack
      $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
      if ($v.Sec -gt 0) {
        $wv = [single]($bw * $v.Sec / $maxV)
        $gp = New-RoundRect $bx ($y + 3) $wv $bh 4
        $b = New-Object System.Drawing.SolidBrush $script:UiWork
        $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
      }
      $durTxt = if ($v.Sec -gt 0) { Format-Dur $v.Sec } else { '时长未知' }
      $g.DrawString($durTxt, $script:FApp, $bText, ($w - 16 - 70), $y)
      $y += 24
    }
  }

  # ---- 底部：近 7 天每天一根竖条
  $baseY = $h - 40
  $dayW = [int](($w - 32) / 7)
  $vals = @()
  $maxD = 1
  for ($i = 6; $i -ge 0; $i--) {
    $dd = $now.AddDays(-$i)
    $d = Get-DayDuration $st $durMap (Get-DayKey $dd)
    $vals += [pscustomobject]@{ d = $dd; v = [int]$d.Total }
    if ([int]$d.Total -gt $maxD) { $maxD = [int]$d.Total }
  }
  $idx = 0
  foreach ($v in $vals) {
    $bx = 16 + $idx * $dayW
    $bh2 = [int](28 * $v.v / $maxD)
    if ($bh2 -lt 1 -and $v.v -gt 0) { $bh2 = 1 }
    if ($bh2 -gt 0) {
      $gp = New-RoundRect ($bx + 6) ($baseY + 24 - $bh2) ($dayW - 14) $bh2 3
      $b = New-Object System.Drawing.SolidBrush $(if ($idx -eq 6) { $script:UiWork } else { [System.Drawing.Color]::FromArgb(255, 150, 175, 235) })
      $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
    }
    $g.DrawString($v.d.ToString('MM-dd'), $script:FTiny, $bMuted, ($bx + 2), ($baseY + 26))
    $idx++
  }
  $bText.Dispose(); $bMuted.Dispose()
}

function Show-Panel($state) {
  try {
    Initialize-WinForms
    if ($script:PanelForm -and -not $script:PanelForm.IsDisposed) { $script:PanelForm.Close() }
    $script:PanelRange = 0
    $script:PanelReady = $false
    $nRow = @(Get-PanelVideos $state (Get-Durations) (Get-Date) 0).Count
    if ($nRow -lt 1) { $nRow = 1 }
    $w = 420
    $h = 168 + $nRow * 24 + 78
    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $f.ShowInTaskbar = $false
    $f.TopMost = $true
    $f.BackColor = $script:UiBg
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $f.ClientSize = New-Object System.Drawing.Size $w, $h
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $f.Location = New-Object System.Drawing.Point (($wa.Right - $w - 10), ($wa.Bottom - $h - 10))
    $f.Add_Paint({ param($s, $e) Draw-Panel $e.Graphics $s.ClientSize.Width $s.ClientSize.Height })
    $f.Add_MouseClick({
      param($s, $e)
      foreach ($t in $script:TabRects) {
        if ($e.Y -ge 8 -and $e.Y -le 34 -and $e.X -ge $t.x -and $e.X -le ($t.x + $t.w + 8)) {
          $script:PanelRange = $t.i
          $s.Invalidate()
          return
        }
      }
    })
    # 点别处收起来；延迟半秒再武装，免得菜单刚关掉时的那次失焦把它关掉
    $f.Add_Shown({
      $script:PanelArm = New-Object System.Windows.Forms.Timer
      $script:PanelArm.Interval = 500
      $script:PanelArm.Add_Tick({ $script:PanelArm.Stop(); $script:PanelReady = $true })
      $script:PanelArm.Start()
    })
    $f.Add_Deactivate({ if ($script:PanelReady -and $script:PanelForm -and -not $script:PanelForm.IsDisposed) { $script:PanelForm.Close() } })
    $f.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Escape') { $s.Close() } })
    $script:PanelForm = $f
    $f.Show()
    $f.Activate()
  } catch { Write-Log "panel failed: $($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber)" }
}

function Get-Numbers($state, [datetime]$now) {
  $today = Get-DayKey $now
  $yest  = Get-DayKey $now.AddDays(-1)
  $openN = 0
  if ($state.open) { $openN = @($state.open.PSObject.Properties).Count }
  $ct = 0; $cy = 0
  if ($state.closed.PSObject.Properties[$today]) { $ct = @($state.closed.$today).Count }
  if ($state.closed.PSObject.Properties[$yest])  { $cy = @($state.closed.$yest).Count }
  return [pscustomobject]@{ Open = $openN; Today = $ct; Yesterday = $cy }
}

# ---------------------------------------------------------------- 托盘

function New-CountIcon([int]$n) {
  Add-Type -AssemblyName System.Drawing
  $bmp = New-Object System.Drawing.Bitmap 32, 32
  $g   = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)
  $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 30, 90, 190))), 0, 0, 31, 31)
  $txt = if ($n -gt 999) { '999+' } else { "$n" }
  $size = switch ($txt.Length) { 1 {16} 2 {14} 3 {11} default {8} }
  $font = New-Object System.Drawing.Font 'Segoe UI', $size, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
  $fmt  = New-Object System.Drawing.StringFormat
  $fmt.Alignment = [System.Drawing.StringAlignment]::Center
  $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
  $g.DrawString($txt, $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, 0, 32, 32), $fmt)
  $g.Dispose()
  $h = $bmp.GetHicon()
  $ico = [System.Drawing.Icon]::FromHandle($h)
  $bmp.Dispose()
  return $ico
}

function Update-Tray {
  try {
    if ($null -eq $script:Block) { $script:Block = Apply-Snapshot $script:State }
    $ok = Step $script:State (Get-Date) $script:Block
    if (-not $ok) {
      # 读不到标签栏这一轮被跳过，数字保持不动。这种情况必须留痕，否则又变成静默卡住。
      $now = Get-Date
      if (-not $script:LastMissLog -or ($now - $script:LastMissLog).TotalSeconds -ge 60) {
        Write-Log 'skipped a round: could not read the Chrome tab strip'
        $script:LastMissLog = $now
      }
    }
    $n = Get-Numbers $script:State (Get-Date)
    if ($n.Open -ne $script:LastIcon) { $script:Ni.Icon = New-CountIcon $n.Open; $script:LastIcon = $n.Open }
    $durMap = Get-Durations
    $dt = Get-DayDuration $script:State $durMap (Get-DayKey (Get-Date))
    $dy = Get-DayDuration $script:State $durMap (Get-DayKey (Get-Date).AddDays(-1))
    $script:Ni.Text = Get-TrayText $script:State $durMap $n (Get-Date)
    Save-State $script:State
    $script:Ticks++

    # 有没取到时长的，就让后台小助手去补（每 15 分钟最多起一次）
    if ($dt.Unknown -gt 0 -or $dy.Unknown -gt 0) {
      $now = Get-Date
      if (-not $script:LastFetch -or ($now - $script:LastFetch).TotalMinutes -ge 15) {
        $script:LastFetch = $now
        Start-DurationFetch
      }
    }
  } catch {
    Write-Log "tick failed: $($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber)"
  }
}

function Initialize-WinForms {
  if ($script:WinFormsReady) { return }
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  # 关键：不设成 false 的话，控件走 GDI+ 的 DrawString，中文会发虚、笔画粗细不匀
  try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch {}
  [System.Windows.Forms.Application]::EnableVisualStyles()
  # 界面里的异常别弹那个吓人的框，写进日志并带上堆栈
  try {
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
    [System.Windows.Forms.Application]::add_ThreadException({
      param($s, $e)
      Write-Log "ui exception: $($e.Exception.ToString())"
    })
  } catch { Write-Log "install ui exception logger failed: $($_.Exception.Message)" }
  $script:WinFormsReady = $true
}

function Start-DurationFetch {
  try {
    $script = Join-Path $Root 'fetch-durations.ps1'
    if (-not (Test-Path $script)) { return }
    Start-Process -FilePath 'powershell.exe' `
      -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$script`"" `
      -WindowStyle Hidden | Out-Null
  } catch { Write-Log "could not start duration fetch: $($_.Exception.Message)" }
}

function Start-Tray {
  Initialize-WinForms

  $script:Ticks = 0
  $script:LastIcon = -1
  $script:Block = Apply-Snapshot $script:State
  Write-Log "exclusion list built: $($script:Block.Count) non-video titles; ids known: $(@($script:State.ids.PSObject.Properties).Count)"
  Start-DurationFetch
  $script:LastFetch = Get-Date

  $script:Ni = New-Object System.Windows.Forms.NotifyIcon
  $script:Ni.Icon = New-CountIcon 0
  $script:Ni.Text = '视频标签页计数器 启动中'
  $script:Ni.Visible = $true

  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  $miDetail = $menu.Items.Add('明细')
  $miNow  = $menu.Items.Add('立即刷新')
  [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
  $miOpen = $menu.Items.Add('打开计数文件夹')
  $miExit = $menu.Items.Add('退出')
  $script:Ni.ContextMenuStrip = $menu

  $miDetail.Add_Click({ Update-Tray; Show-Panel $script:State })
  $miNow.Add_Click({ $script:Block = Apply-Snapshot $script:State; Update-Tray })
  $miOpen.Add_Click({ Start-Process explorer.exe $Root })
  $miExit.Add_Click({
    $script:Timer.Stop(); Save-State $script:State
    $script:Ni.Visible = $false; $script:Ni.Dispose()
    [System.Windows.Forms.Application]::Exit()
  })

  $script:Timer = New-Object System.Windows.Forms.Timer
  $script:Timer.Interval = [int]($script:IntervalSec * 1000)
  $script:Timer.Add_Tick({ Update-Tray })
  $script:Timer.Start()

  Write-Log "tray started, interval=$($script:IntervalSec)s"
  Update-Tray
  [System.Windows.Forms.Application]::Run()
  Write-Log 'tray exited'
}

# ---------------------------------------------------------------- 入口

$state = Load-State
if ($null -eq $state) { $state = New-State }
foreach ($f in 'open','opened','closed','titles','ids') {
  if (-not $state.PSObject.Properties[$f]) { $state | Add-Member -NotePropertyName $f -NotePropertyValue ([pscustomobject]@{}) }
}
if (-not $state.PSObject.Properties['seeded'])     { $state | Add-Member -NotePropertyName seeded -NotePropertyValue $false }
if (-not $state.PSObject.Properties['keyVersion']) { $state | Add-Member -NotePropertyName keyVersion -NotePropertyValue 0 }

# 键的算法变了（从视频 ID 改成标题）时重新取基线，避免误记一大批「看完」
if ($state.keyVersion -ne $KeyVersion) {
  $state.open = [pscustomobject]@{}
  $state.seeded = $false
  $state.keyVersion = $KeyVersion
  Write-Log "key version changed -> rebaselined"
}

$block = Apply-Snapshot $state

if ($Once) {
  [void](Step $state (Get-Date) $block)
  Save-State $state
  $n = Get-Numbers $state (Get-Date)
  $live = Get-LiveTabTitles
  $liveCount = if ($null -eq $live) { 'unavailable' } else { @($live).Count }
  $durMap = Get-Durations
  $dt = Get-DayDuration $state $durMap (Get-DayKey (Get-Date))
  $dy = Get-DayDuration $state $durMap (Get-DayKey (Get-Date).AddDays(-1))
  "chrome: $(if (Test-ChromeRunning) { 'running' } else { 'not running' })"
  "live tab strip items: $liveCount"
  "exclusion titles: $(@($block.Keys).Count)"
  "ids known: $(@($state.ids.PSObject.Properties).Count)   durations cached: $($durMap.Count)"
  "open    : $($n.Open)"
  "today   : $($n.Today)  合计 $(Format-HM $dt.Total)  未知 $($dt.Unknown)"
  "yesterday: $($n.Yesterday)  合计 $(Format-HM $dy.Total)  未知 $($dy.Unknown)"
  $txt = Get-TrayText $state $durMap $n (Get-Date)
  "tooltip ($($txt.Length)/63):"
  $txt -split "`n" | ForEach-Object { "    |$_" }
  exit 0
}

if ($Detail) {
  [void](Step $state (Get-Date) $block)
  Save-State $state
  Build-DetailText $state (Get-Date)
  exit 0
}

if ($ShowDetail) {
  [void](Step $state (Get-Date) $block)
  Save-State $state
  $script:State = $state
  Show-Panel $state
  [System.Windows.Forms.Application]::Run($script:PanelForm)
  exit 0
}

$script:State = $state
$script:IntervalSec = $IntervalSec

$script:SingleInstance = New-Object System.Threading.Mutex($false, 'Local\video-tab-counter-singleton')
if (-not $script:SingleInstance.WaitOne(0)) { Write-Log 'another instance is already running, exiting'; exit 0 }

Start-Tray
