# video-tab-counter - Chrome 视频标签页计数器
# 版本 1.2
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

$ToolVersion = '1.2'   # 版本号：第二行注释和 README 开头要跟它一致
$ErrorActionPreference = 'Stop'
$Root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$StatePath = Join-Path $Root 'state.json'
$BakPath   = Join-Path $Root 'state.bak.json'
$LogPath   = Join-Path $Root 'counter.log'
$SessDir   = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Sessions'
$KeyVersion = 3

# 一个视频至少要「被看到」这么多秒，离开标签栏时才记一次看完。
# 低于门槛的当点错处理：点开、发现不对、马上叉掉，不该记一笔。
$MinWatchSec = 15

function Write-Log([string]$m) {
  try { Add-Content -Path $LogPath -Value "$(Get-Date -Format o) $m" -Encoding UTF8 } catch {}
}

# Chrome 会往标签名里塞状态文字（正在出声、吃内存高），顺序和个数都不固定，
# 所以要反复剥，剥到不再变化为止。只剥状态文字，站点后缀留给调用方。
function Remove-TitleStatusNoise([string]$t) {
  if (-not $t) { return $t }
  $prev = ''
  $s = $t
  while ($s -ne $prev) {
    $prev = $s
    $s = $s -replace '\s*-\s*audio playing\s*$', ''
    $s = $s -replace '\s*-\s*high memory usage\s*-\s*[\d.,]+\s*(?:gb|mb|kb|tb)\s*$', ''
    $s = $s -replace '\s*-\s*[\d.,]+\s*(?:gb|mb|kb|tb)\s*$', ''
    $s = $s.Trim()
  }
  return $s
}

function Get-RawNorm([string]$title) {
  if (-not $title) { return $null }
  $t = $title -replace '^\(\d+\)\s*', ''
  $t = Remove-TitleStatusNoise $t
  $t = ($t -replace '\s+', ' ').Trim()
  if (-not $t) { return $null }
  return $t.ToLowerInvariant()
}

# 身份键：在原始规范化标题基础上再去掉站点后缀，这样跟按网址回溯出来的标题对得上。
# 站点后缀也可能不止一层，同样反复剥。
function Get-TitleKey([string]$title) {
  $k = Get-RawNorm $title
  if (-not $k) { return $null }
  $prev = ''
  while ($k -ne $prev) {
    $prev = $k
    $k = $k -replace '\s*-\s*youtube\s*$', ''
    $k = $k -replace '_哔哩哔哩_bilibili\s*$', ''
    $k = $k.Trim()
  }
  return $k
}

# 把一个已经成型的键（'t:' + 标题）再洗一遍，用于修历史脏键
function Get-CleanKey([string]$key) {
  if (-not $key) { return $key }
  if ($key.StartsWith('t:')) { return 't:' + (Get-TitleKey $key.Substring(2)) }
  return (Get-TitleKey $key)
}

# 一次性迁移：把历史里带状态尾巴的脏键改回干净名字。
# 不改的话，同一个视频会在「编号表」和「看完名单」里对不上，时长查不到，还可能被算成两个。
function Repair-StateKeys($st) {
  if ($null -eq $st) { return 0 }
  $changed = 0
  foreach ($field in @('ids','titles')) {
    if (-not $st.PSObject.Properties[$field]) { continue }
    $new = [pscustomobject]@{}
    foreach ($p in @($st.$field.PSObject.Properties)) {
      $ck = Get-CleanKey $p.Name
      if ($ck -ne $p.Name) { $changed++ }
      if (-not $new.PSObject.Properties[$ck]) { $new | Add-Member -NotePropertyName $ck -NotePropertyValue $p.Value }
    }
    $st.$field = $new
  }
  if ($st.PSObject.Properties['open']) {
    $newOpen = [pscustomobject]@{}
    foreach ($p in @($st.open.PSObject.Properties)) {
      $ck = Get-CleanKey $p.Name
      if ($ck -ne $p.Name) { $changed++ }
      if (-not $newOpen.PSObject.Properties[$ck]) { $newOpen | Add-Member -NotePropertyName $ck -NotePropertyValue $p.Value }
    }
    $st.open = $newOpen
  }
  foreach ($field in @('opened','closed')) {
    if (-not $st.PSObject.Properties[$field]) { continue }
    foreach ($d in @($st.$field.PSObject.Properties)) {
      $arr = @()
      foreach ($k in @($d.Value)) {
        $ck = Get-CleanKey $k
        if ($ck -ne $k) { $changed++ }
        $arr += $ck
      }
      $d.Value = @($arr | Sort-Object -Unique)
    }
  }
  return $changed
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
  if (-not (Test-Path $StatePath)) { return $null }
  try {
    return (Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json)
  } catch {
    # 关键：文件读不出来（被写到一半、被截断）**不等于**第一次运行。
    # 以前这里静静地返回 null，于是程序当成新装、建一个空的，然后立刻把空的覆盖回去，
    # 历史就这么整块没了。真发生过。所以现在：留下残骸、大声记一笔。
    $bad = "$StatePath.corrupt-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
    try { Move-Item -Path $StatePath -Destination $bad -Force } catch {}
    Write-Log "state unreadable -> kept as $(Split-Path $bad -Leaf); trying the backup: $($_.Exception.Message)"
    return $null
  }
}

function Save-State($s) {
  # 先写临时文件再替换：直接覆盖写的话，进程在写的那一刻被杀掉就会留下半个文件
  $json = $s | ConvertTo-Json -Depth 6 -Compress
  $tmp = "$StatePath.tmp"
  [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -Path $tmp -Destination $StatePath -Force
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

  # open 的值是「第一次看到这个视频的时间」。老状态里是 $true（没有时间戳），
  # 那种按「早就看到了」算，免得升级那一刻把真实记录丢掉。
  $prev = @{}
  if ($state.open) { foreach ($p in $state.open.PSObject.Properties) { $prev[$p.Name] = $p.Value } }

  if ($state.seeded) {
    $appeared = @(); $gone = @()
    foreach ($k in $openNow.Keys) { if (-not $prev.ContainsKey($k)) { $appeared += $k } }
    foreach ($k in $prev.Keys) {
      if ($openNow.ContainsKey($k)) { continue }
      # 只被看到一下就没了（点错、马上叉掉）不算看完：停留不到门槛的直接丢掉
      $seenStamp = [string]$prev[$k]
      if ($seenStamp -and $seenStamp -ne 'True') {
        try {
          $dwell = (New-TimeSpan -Start ([datetime]::Parse($seenStamp)) -End $now).TotalSeconds
          if ($dwell -lt $MinWatchSec) { continue }
        } catch {}
      }
      $gone += $k
    }

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
  foreach ($k in $openNow.Keys) {
    # 值记「第一次看到它的时间」，下次少了它要拿这个算停留了多久。
    $stamp = $now.ToString('o')
    if ($prev.ContainsKey($k)) {
      $stamp = [string]$prev[$k]
      # 老格式（$true）：当成早就看到了，别从这一轮重新计时
      if ($stamp -eq 'True' -or -not $stamp) { $stamp = $now.AddSeconds(-$MinWatchSec).ToString('o') }
    }
    $o | Add-Member -NotePropertyName $k -NotePropertyValue $stamp
  }
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
  # 必须向下取整：以前写的是 [int]($seconds / 3600)，那是四舍五入，
  # 1 小时 49 分会显示成「2 小时 49 分」——分钟一到 30 就多算一小时。
  $h = [int][math]::Floor($seconds / 3600); $m = [int][math]::Floor(($seconds % 3600) / 60)
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
      [pscustomobject]@{ Key = $k; Title = (Get-DisplayTitle $state $k); Sec = $sec }
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
# 查鼠标左键此刻是不是按着：用来判断「点到面板外面了」
Add-Type -Namespace VideoUi -Name Keys -MemberDefinition @'
[DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
'@ -ErrorAction SilentlyContinue

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
    # 关闭按钮单独一个大字号，原来那个 × 太小，不好点也不好认
    $script:FClose = New-Object System.Drawing.Font 'Microsoft YaHei UI', 14, ([System.Drawing.FontStyle]::Regular)
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
  # 同样向下取整，不然面板上的小时也会多算一小时
  $h = [int][math]::Floor($sec / 3600); $m = [int][math]::Floor(($sec % 3600) / 60)
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
    # 近 7 天跟下面那份列表必须同一套口径：同一个视频七天里看过两次也只算一个。
    # 以前是按天把当天的数加起来，跨天重复的会被算两次，于是出现「共 65 个」而列表只有 61 条。
    $keys = @()
    for ($i = 0; $i -lt 7; $i++) {
      $k = Get-DayKey $now.AddDays(-$i)
      if ($state.closed.PSObject.Properties[$k]) { $keys += @($state.closed.$k) }
    }
    $keys = @($keys | Select-Object -Unique)
    $total = 0; $unknown = 0
    foreach ($k in $keys) {
      $id = $null
      if ($state.PSObject.Properties['ids'] -and $state.ids.PSObject.Properties[$k]) { $id = [string]$state.ids.$k }
      if ($id -and $durMap.ContainsKey($id)) { $total += [int]$durMap[$id] } else { $unknown++ }
    }
    return [pscustomobject]@{ Total = $total; Count = $keys.Count; Unknown = $unknown; Day = $null }
  }
  if ($rng -eq 3) {
    $n = if ($state.open) { @($state.open.PSObject.Properties).Count } else { 0 }
    return [pscustomobject]@{ Total = 0; Count = $n; Unknown = 0; Day = $null }
  }
  $day = Get-DayKey $now.AddDays(-$rng)
  $d = Get-DayDuration $state $durMap $day
  return [pscustomobject]@{ Total = [int]$d.Total; Count = [int]$d.Count; Unknown = [int]$d.Unknown; Day = $day }
}

# 面板上要列的视频：今天 / 昨天按当天，近 7 天按这七天，现在开着按当前标签栏
function Get-PanelVideos($state, $durMap, [datetime]$now, [int]$rng) {
  if ($rng -eq 3) {
    $openRows = @()
    foreach ($p in $state.open.PSObject.Properties) {
      $k = $p.Name
      $id = $null
      if ($state.PSObject.Properties['ids'] -and $state.ids.PSObject.Properties[$k]) { $id = [string]$state.ids.$k }
      $sec = if ($id -and $durMap.ContainsKey($id)) { [int]$durMap[$id] } else { 0 }
      $ttl = if ($state.PSObject.Properties['titles'] -and $state.titles.PSObject.Properties[$k]) { $state.titles.$k } else { $k }
      $openRows += [pscustomobject]@{ Key = $k; Title = $ttl; Sec = $sec }
    }
    return @($openRows | Sort-Object -Property @{Expression='Sec';Descending=$true}, Title)
  }
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
    [pscustomobject]@{ Key = $k; Title = (Get-DisplayTitle $state $k); Sec = $sec }
  }
  return @($rows | Sort-Object -Property @{Expression='Sec';Descending=$true}, Title)
}

# 从记录里抹掉一个视频（面板上点它右边的「×」）。误记的、点错被算成看完的，都靠它清掉。
# 删完立刻存盘：面板上的合计、条数、底部的柱子、托盘提示都是每次现算的，下一次重画就跟着变。
# 「近 7 天」那一栏是按标题去重的七天合集，删它就等于把这七天里所有同名的都抹掉——
# 只删当天的话，删完它还在列表里，看着像没生效。
function Remove-PanelVideo($state, [int]$rng, [string]$key) {
  if (-not $key) { return 0 }
  $days = @()
  if ($rng -eq 2) {
    for ($i = 0; $i -lt 7; $i++) { $days += (Get-DayKey (Get-Date).AddDays(-$i)) }
  } else {
    $days += (Get-DayKey (Get-Date).AddDays(-$rng))
  }
  $removed = 0
  foreach ($d in $days) {
    if (-not $state.closed.PSObject.Properties[$d]) { continue }
    $old = @($state.closed.$d)
    if ($old -notcontains $key) { continue }
    $state.closed.$d = @($old | Where-Object { $_ -ne $key })
    $removed++
  }
  if ($removed -gt 0) {
    Save-State $state
    Write-Log "panel delete: $key (range=$rng, days=$removed)"
  }
  return $removed
}

# 面板的版面：哪一段放什么、列表区能放多少行。画的时候和算窗口高度的时候都用它，
# 免得两边各写一套数字、切个标签就只露出半行。
function Get-PanelLayout([int]$h, [bool]$withFooter) {
  $listTop = 158
  # 底部那排柱子只在「近 7 天」才有，别的栏不给它留位置，省下的高度全给列表
  $listBottom = if ($withFooter) { $h - 92 } else { $h - 24 }
  $rowH = 24
  $maxRows = [int][Math]::Floor(($listBottom - $listTop) / $rowH)
  if ($maxRows -lt 1) { $maxRows = 1 }
  return [pscustomobject]@{ listTop = $listTop; listBottom = $listBottom; rowH = $rowH; maxRows = $maxRows }
}

# 一栏有 n 条时面板该多高：刚好装下这些条；实在太多就顶到屏幕，交给滚动条
function Get-PanelHeight([int]$n, $wa, [bool]$withFooter) {
  if ($n -lt 1) { $n = 1 }
  $pad = if ($withFooter) { 260 } else { 182 }
  $need = $pad + $n * 24
  $cap = [Math]::Min(680, ($wa.Height - 60))
  if ($need -gt $cap) { return $cap }
  $floor = if ($withFooter) { 320 } else { 240 }
  if ($need -lt $floor) { return $floor }
  return $need
}

# 自绘面板必须开双缓冲，不然定时重画时整块会闪一下。
# DoubleBuffered 是受保护的属性，直接赋值得反射；用 Control.SetStyle 更稳。
function Set-PanelDoubleBuffer($form) {
  try {
    $styles = [int]([System.Windows.Forms.ControlStyles]::UserPaint)
    $styles = $styles -bor [int]([System.Windows.Forms.ControlStyles]::AllPaintingInWmPaint)
    $styles = $styles -bor [int]([System.Windows.Forms.ControlStyles]::OptimizedDoubleBuffer)
    $styles = $styles -bor [int]([System.Windows.Forms.ControlStyles]::Opaque)
    $m = [System.Windows.Forms.Control].GetMethod('SetStyle', [System.Reflection.BindingFlags]'NonPublic,Instance')
    [void]$m.Invoke($form, @([System.Windows.Forms.ControlStyles]$styles, $true))
  } catch { Write-Log "double buffer unavailable: $($_.Exception.Message)" }
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

  # ---- 顶部标签（多一栏「现在开着」）
  $tabs = @('今天', '昨天', '近 7 天', '现在开着')
  $tx = 16
  $script:TabRects = @()
  for ($i = 0; $i -lt $tabs.Count; $i++) {
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

  # ---- 大字号
  $openN = if ($st.open) { @($st.open.PSObject.Properties).Count } else { 0 }
  if ($rng -eq 3) {
    $big = "$openN 个"
    # 这里不写「不算看完」那类规则说明：界面上只说事实，规则写在文档里
    $sub = ''
  } else {
    $big = Format-Dur $info.Total
    $sub = "共 $($info.Count) 个"
    if ($info.Unknown -gt 0) { $sub += "   ·   $($info.Unknown) 个时长未知" }
  }
  $g.DrawString($big, $script:FTitle, $bText, 14, 44)
  $szBig = $g.MeasureString($big, $script:FTitle)
  $g.DrawString($sub, $script:FSub, $bMuted, 18, 40 + $szBig.Height)
  # 右上角只留关闭按钮。既然有了「现在开着」那一栏，这里再写一遍就是重复。
  $g.DrawString('×', $script:FClose, $bMuted, ($w - 30), 2)
  $script:PanelCloseRect = [pscustomobject]@{ x = ($w - 40); y = 0; w = 36; h = 34 }

  # ---- 视频列表（装不下就滚动，不再只显示前几个）
  $vids = Get-PanelVideos $st $durMap $now $rng
  $lay = Get-PanelLayout $h ($rng -eq 2)
  $maxRows = $lay.maxRows
  $off = [int]$script:PanelOffset
  if ($off -gt ($vids.Count - $maxRows)) { $off = [Math]::Max(0, $vids.Count - $maxRows) }
  if ($off -lt 0) { $off = 0 }
  $headTxt = if ($rng -eq 3) { '现在开着的视频' } else { '看完的视频' }
  $g.DrawString($headTxt, $script:FTabB, $bText, 16, 116)
  $cntTxt = "共 $($vids.Count) 条"
  $cntW = $g.MeasureString($cntTxt, $script:FTiny).Width
  $g.DrawString($cntTxt, $script:FTiny, $bMuted, ($w - 16 - $cntW), 120)
  $y = $lay.listTop
  $view = @($vids | Select-Object -Skip $off -First $maxRows)
  # 每行右边那个「×」的位置，点它就把这条从记录里抹掉。只给「看完」那几栏画：
  # 「现在开着」是此刻标签栏的实况、不是记录，删它没有意义。
  $canDel = ($rng -ne 3)
  $script:RowDelRects = @()
  if ($vids.Count -eq 0) {
    $g.DrawString('（还没有）', $script:FTiny, $bMuted, 16, $y)
  } else {
    $maxV = 1
    foreach ($v in $vids) { if ($v.Sec -gt $maxV) { $maxV = $v.Sec } }
    foreach ($v in $view) {
      $t = Limit-Text $g $v.Title $script:FApp ($w - 292)
      $g.DrawString($t, $script:FApp, $bText, 16, $y)
      $bx = $w - 242; $bw = 110; $bh = 9
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
      $g.DrawString($durTxt, $script:FApp, $bText, ($w - 52 - 74), $y)
      if ($canDel) {
        $dx = $w - 38; $dw = 26; $dh = 22
        $hotRow = ([string]$script:RowDelKey -eq [string]$v.Key)
        if ($hotRow) {
          $gp = New-RoundRect $dx ($y - 1) $dw $dh 4
          $hb = New-Object System.Drawing.SolidBrush $script:UiTrack
          $g.FillPath($hb, $gp); $hb.Dispose(); $gp.Dispose()
        }
        $cb = New-Object System.Drawing.SolidBrush $(if ($hotRow) { $script:UiFun } else { $script:UiMuted })
        $g.DrawString('×', $script:FApp, $cb, ($dx + 6), $y)
        $cb.Dispose()
        $script:RowDelRects += [pscustomobject]@{ x = $dx; y = $y; w = $dw; h = $dh; key = [string]$v.Key }
      }
      $y += $lay.rowH
    }
    # 装不下就画一条能拖的滚动条：右边一条轨道，里面一根滑块
    if ($vids.Count -gt $maxRows) {
      $trackX = $w - 9
      $trackY = $lay.listTop
      $trackH = $maxRows * $lay.rowH - 4
      $gp = New-RoundRect $trackX $trackY 4 $trackH 2
      $b = New-Object System.Drawing.SolidBrush $script:UiTrack
      $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
      $maxOff = $vids.Count - $maxRows
      $thumbH = [single]($trackH * $maxRows / $vids.Count)
      if ($thumbH -lt 28) { $thumbH = 28 }
      $thumbY = [single]$trackY
      if ($maxOff -gt 0) { $thumbY = [single]($trackY + ($trackH - $thumbH) * $off / $maxOff) }
      $gp = New-RoundRect $trackX $thumbY 4 $thumbH 2
      $b = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 176, 186, 198))
      $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
      # 记下几何，给鼠标拖动用
      $script:PanelScroll = [pscustomobject]@{ x = $trackX; y = $trackY; h = $trackH; thumbY = $thumbY; thumbH = $thumbH; maxOff = $maxOff }
    } else {
      $script:PanelScroll = $null
    }
  }

  # ---- 底部：只有「近 7 天」这一栏画每天一根竖条。
  # 今天/昨天/现在开着底下不放它：那几栏讲的是当天或此刻，摆一周的柱子只是占地方。
  # 鼠标停在哪根上，那根高亮，并在它上方写出日期和数字。
  $script:BarRects = @()
  if ($rng -eq 2) {
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
      $hot = ([int]$script:PanelBarHover -eq $idx)
      if ($bh2 -gt 0) {
        $gp = New-RoundRect ($bx + 6) ($baseY + 24 - $bh2) ($dayW - 14) $bh2 3
        $bc = if ($hot) { $script:UiFun } elseif ($idx -eq 6) { $script:UiWork } else { [System.Drawing.Color]::FromArgb(255, 150, 175, 235) }
        $b = New-Object System.Drawing.SolidBrush $bc
        $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
      }
      $bt = New-Object System.Drawing.SolidBrush $(if ($hot) { $script:UiText } else { $script:UiMuted })
      $g.DrawString($v.d.ToString('MM-dd'), $script:FTiny, $bt, ($bx + 2), ($baseY + 26))
      $bt.Dispose()
      $script:BarRects += [pscustomobject]@{ i = $idx; x = $bx; w = $dayW }
      $idx++
    }
    $hv = [int]$script:PanelBarHover
    if ($hv -ge 0 -and $hv -lt $vals.Count) {
      $one = $vals[$hv]
      $htxt = $one.d.ToString('MM-dd') + '  ' + (Format-Dur $one.v)
      $hb = New-Object System.Drawing.SolidBrush $script:UiText
      $hw = $g.MeasureString($htxt, $script:FTiny).Width
      $hx = 16 + $hv * $dayW + ($dayW - $hw) / 2
      if ($hx -lt 16) { $hx = 16 }
      if ($hx + $hw -gt ($w - 8)) { $hx = $w - 8 - $hw }
      $g.DrawString($htxt, $script:FTiny, $hb, [single]$hx, [single]($baseY - 14))
      $hb.Dispose()
    }
  }
  $bText.Dispose(); $bMuted.Dispose()
}

function Show-Panel($state) {
  try {
    Initialize-WinForms
    if ($script:PanelForm -and -not $script:PanelForm.IsDisposed) { $script:PanelForm.Close() }
    $script:PanelRange = 0
    $script:PanelReady = $false
    $script:PanelOffset = 0
    $script:PanelDrag = $null
    $script:PanelScroll = $null
    $script:PanelBarHover = -1
    $script:BarRects = @()
    # 列表里那些「×」的命中区（每次重画时填），以及当前鼠标停在哪一条上
    $script:RowDelRects = @()
    $script:RowDelKey = ''
    # 鼠标是不是在面板里按下去的：按住不放拖到面板外时，不能当「点到别处」把面板关掉
    $script:PanelHold = $false
    # 高度跟着当前这一栏的条数走，最多占满屏幕：条目少就矮一点、不留一大块空白；
    # 条目多就顶到屏幕高度，多出来的交给滚动条。
    $w = 520
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $n0 = @(Get-PanelVideos $state (Get-Durations) (Get-Date) 0).Count
    if ($n0 -lt 1) { $n0 = 1 }
    $h = Get-PanelHeight $n0 $wa $false
    $script:PanelMaxRows = (Get-PanelLayout $h $false).maxRows
    $f = New-Object System.Windows.Forms.Form
    Set-PanelDoubleBuffer $f
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $f.ShowInTaskbar = $false
    $f.TopMost = $true
    $f.BackColor = $script:UiBg
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $f.ClientSize = New-Object System.Drawing.Size $w, $h
    $f.Location = New-Object System.Drawing.Point (($wa.Right - $w - 10), ($wa.Bottom - $h - 10))
    $f.Add_Paint({ param($s, $e) Draw-Panel $e.Graphics $s.ClientSize.Width $s.ClientSize.Height })
    $f.Add_MouseClick({
      param($s, $e)
      $rngNow = [int]$script:PanelRange
      if ($rngNow -ne 3) {
        foreach ($rr in @($script:RowDelRects)) {
          if ($e.X -ge $rr.x -and $e.X -le ($rr.x + $rr.w) -and $e.Y -ge $rr.y -and $e.Y -le ($rr.y + $rr.h)) {
            $gone = Remove-PanelVideo $script:State $rngNow $rr.key
            if ($gone -gt 0) {
              $script:RowDelKey = ''
              # 少一条之后窗口该矮一点：跟切标签时一样重算高度，别在底下留一截空白
              $wa3 = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
              $left = @(Get-PanelVideos $script:State (Get-Durations) (Get-Date) $rngNow).Count
              $nh3 = Get-PanelHeight $left $wa3 ($rngNow -eq 2)
              if ($nh3 -ne $s.ClientSize.Height) {
                $s.ClientSize = New-Object System.Drawing.Size 520, $nh3
                $s.Location = New-Object System.Drawing.Point (($wa3.Right - 520 - 10), ($wa3.Bottom - $nh3 - 10))
                $script:PanelMaxRows = (Get-PanelLayout $nh3 ($rngNow -eq 2)).maxRows
              }
              $script:PanelSig = ''
              $s.Invalidate()
              # 托盘提示和「今天」的数也要跟着变，不然面板删掉了、托盘还挂着旧值
              Update-Tray
            }
            return
          }
        }
      }
      $cr = $script:PanelCloseRect
      if ($cr -and $e.X -ge $cr.x -and $e.X -le ($cr.x + $cr.w) -and $e.Y -ge $cr.y -and $e.Y -le ($cr.y + $cr.h)) { $s.Close(); return }
      foreach ($t in $script:TabRects) {
        if ($e.Y -ge 8 -and $e.Y -le 34 -and $e.X -ge $t.x -and $e.X -le ($t.x + $t.w + 8)) {
          $script:PanelRange = $t.i
          $script:PanelOffset = 0
          # 换栏目时把窗口调到这一栏需要的高度，别让上一栏的高度卡着新的一栏
          $n = @(Get-PanelVideos $script:State (Get-Durations) (Get-Date) $t.i).Count
          $wa2 = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
          $nh = Get-PanelHeight $n $wa2 ($t.i -eq 2)
          $s.ClientSize = New-Object System.Drawing.Size 520, $nh
          $s.Location = New-Object System.Drawing.Point (($wa2.Right - 520 - 10), ($wa2.Bottom - $nh - 10))
          $script:PanelMaxRows = (Get-PanelLayout $nh ($t.i -eq 2)).maxRows
          $s.Invalidate()
          return
        }
      }
    })
    $f.Add_MouseWheel({
      param($s, $e)
      $total = @(Get-PanelVideos $script:State (Get-Durations) (Get-Date) ([int]$script:PanelRange)).Count
      $maxOff = [Math]::Max(0, $total - [int]$script:PanelMaxRows)
      $newOff = [int]$script:PanelOffset - [int]([Math]::Sign($e.Delta))
      if ($newOff -lt 0) { $newOff = 0 }
      if ($newOff -gt $maxOff) { $newOff = $maxOff }
      if ($newOff -ne [int]$script:PanelOffset) { $script:PanelOffset = $newOff; $s.Invalidate() }
    })
    # 滚动条能用鼠标拖：按在滑块上拖，或者点轨道直接跳过去
    $f.Add_MouseDown({
      param($s, $e)
      if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
      $script:PanelHold = $true
      $sc = $script:PanelScroll
      if (-not $sc) { return }
      if ($e.X -lt ($sc.x - 5) -or $e.X -gt ($sc.x + 12)) { return }
      if ($e.Y -ge $sc.thumbY -and $e.Y -le ($sc.thumbY + $sc.thumbH)) {
        $script:PanelDrag = [int]($e.Y - $sc.thumbY)
      } else {
        $rel = ($e.Y - $sc.y) / [double]([Math]::Max(1, ($sc.h - $sc.thumbH)))
        if ($rel -lt 0) { $rel = 0 }
        if ($rel -gt 1) { $rel = 1 }
        $script:PanelOffset = [int][Math]::Round($rel * $sc.maxOff)
        $s.Invalidate()
      }
    })
    $f.Add_MouseUp({ param($s, $e) $script:PanelDrag = $null; $script:PanelHold = $false })
    $f.Add_MouseLeave({
      param($s, $e)
      $need = $false
      if ([int]$script:PanelBarHover -ne -1) { $script:PanelBarHover = -1; $need = $true }
      if ([string]$script:RowDelKey -ne '') { $script:RowDelKey = ''; $need = $true }
      if ($need) { $s.Invalidate() }
    })
    $f.Add_MouseMove({
      param($s, $e)
      # 列表每行右边的「×」：鼠标停上去变色，让人知道这里能点
      $dHot = ''
      if ([int]$script:PanelRange -ne 3) {
        foreach ($rr in @($script:RowDelRects)) {
          if ($e.X -ge $rr.x -and $e.X -le ($rr.x + $rr.w) -and $e.Y -ge $rr.y -and $e.Y -le ($rr.y + $rr.h)) { $dHot = [string]$rr.key; break }
        }
      }
      if ($dHot -ne [string]$script:RowDelKey) { $script:RowDelKey = $dHot; $s.Invalidate() }
      # 底部柱子：鼠标进来就高亮那一根，并把它的日期和数字写在上面
      $hot = -1
      foreach ($br in @($script:BarRects)) {
        if ($e.Y -ge ($s.ClientSize.Height - 58) -and $e.X -ge $br.x -and $e.X -lt ($br.x + $br.w)) { $hot = [int]$br.i; break }
      }
      if ($hot -ne [int]$script:PanelBarHover) { $script:PanelBarHover = $hot; $s.Invalidate() }
      $sc = $script:PanelScroll
      if ($null -ne $script:PanelDrag -and $sc) {
        $rel = (($e.Y - [int]$script:PanelDrag) - $sc.y) / [double]([Math]::Max(1, ($sc.h - $sc.thumbH)))
        if ($rel -lt 0) { $rel = 0 }
        if ($rel -gt 1) { $rel = 1 }
        $newOff = [int][Math]::Round($rel * $sc.maxOff)
        if ($newOff -ne [int]$script:PanelOffset) { $script:PanelOffset = $newOff; $s.Invalidate() }
        return
      }
    })
    # 点别处收起来；延迟半秒再武装，免得菜单刚关掉时的那次失焦把它关掉
    $f.Add_Shown({
      $script:PanelArm = New-Object System.Windows.Forms.Timer
      $script:PanelArm.Interval = 500
      $script:PanelArm.Add_Tick({ $script:PanelArm.Stop(); $script:PanelReady = $true })
      $script:PanelArm.Start()
    })
    $f.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Escape' -or $e.KeyCode -eq 'Space') { $s.Close() } })
    # 关闭方式改掉：**只有点到面板外面才关**。
    # 以前挂在 Deactivate 上，一切换焦点就关，想截图都来不及。
    # 这里每 150 毫秒看一眼：鼠标左键按着、并且位置在面板外面，才关。
    $script:PanelWatch = New-Object System.Windows.Forms.Timer
    $script:PanelWatch.Interval = 150
    $script:PanelWatch.Add_Tick({
      try {
        if (-not $script:PanelForm -or $script:PanelForm.IsDisposed) { $script:PanelWatch.Stop(); return }
        $r = $script:PanelForm.RectangleToScreen($script:PanelForm.ClientRectangle)
        $pos = [System.Windows.Forms.Cursor]::Position
        $inside = ($pos.X -ge $r.Left -and $pos.X -le $r.Right -and $pos.Y -ge $r.Top -and $pos.Y -le $r.Bottom)
        # 别的工具后来开了明细面板，就先把我的收起来，只留一个
        try {
          $ownerFile = Join-Path $env:TEMP 'dsh-tray-panel.owner'
          if (Test-Path $ownerFile) {
            $parts = (Get-Content $ownerFile -Raw -ErrorAction SilentlyContinue).Trim() -split '\|'
            if ($parts.Count -eq 2 -and $parts[0] -ne 'video-tab-counter') {
              if ([long]$parts[1] -gt [long]$script:PanelOpenedAt) { $script:PanelForm.Close(); return }
            }
          }
        } catch {}
        # 面板开着时每 13 次心跳（约 2 秒）核一次内容：变了才重画，没变就不碰屏幕。
        # 这样既不会看见「每两秒闪一下」，也省掉没必要的重画。
        $script:PanelTickN = [int]$script:PanelTickN + 1
        if (($script:PanelTickN % 13) -eq 0) {
          $pv = @(Get-PanelVideos $script:State (Get-Durations) (Get-Date) ([int]$script:PanelRange))
          $psig = "$($script:PanelRange)|$($script:PanelOffset)|$($pv.Count)|"
          foreach ($one in $pv) { $psig += $one.Title + '|' + $one.Sec + ';' }
          if ($psig -ne [string]$script:PanelSig) { $script:PanelSig = $psig; $script:PanelForm.Invalidate() }
        }
        # 任务栏/托盘那一带不算「点到别处」：不然点托盘图标开面板时，按下的那一刻就被
        # 判成点在面板外，面板先关一次再被点开，看着就是「闪一下又弹出来」。
        $waNow = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $onTaskbar = ($pos.Y -gt $waNow.Bottom -or $pos.Y -lt $waNow.Top -or $pos.X -gt $waNow.Right -or $pos.X -lt $waNow.Left)
        $downNow = ([VideoUi.Keys]::GetAsyncKeyState(0x01) -band 0x8000) -ne 0
        if (-not $downNow) { $script:PanelHold = $false }
        # 从面板里按下去、拖到面板外再松手，这不算「点了别处」；
        # 拖滚动条拖到底、手滑出面板边界时，以前就是被这条规则把面板关掉的。
        if (-not $inside -and -not $onTaskbar -and -not $script:PanelHold -and $downNow) {
          $script:PanelForm.Close()
        }
      } catch {}
    })
    $script:PanelWatch.Start()
    $script:PanelTickN = 0
    $script:PanelForm = $f
    # 三个工具的明细面板同一时刻只留一个，别在右下角叠成一摞
    $script:PanelOpenedAt = [DateTime]::UtcNow.Ticks
    try { [System.IO.File]::WriteAllText((Join-Path $env:TEMP 'dsh-tray-panel.owner'), "video-tab-counter|$($script:PanelOpenedAt)") } catch {}
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

# 有人在自己文件夹里放一个 exit-request.txt，就正常退出：先结算存盘、删掉请求文件，再关。
# 这样以后重启和更新都不用强杀进程（强杀会丢上一次存盘之后的那一段）。
function Test-ExitRequested {
  $flag = Join-Path $Root 'exit-request.txt'
  if (-not (Test-Path $flag)) { return $false }
  try { Remove-Item $flag -Force -ErrorAction SilentlyContinue } catch {}
  Write-Log 'exit requested by flag file'
  $script:Timer.Stop(); Save-State $script:State
  $script:Ni.Visible = $false; $script:Ni.Dispose()
  [System.Windows.Forms.Application]::Exit()
  return $true
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

  # 左键单击托盘图标当开关用：点一下开，再点一下关。
  # （鼠标按在托盘那一片不算「点到面板外」，所以不会被外面的规则先关掉。）
  $script:Ni.Add_MouseClick({
    param($s, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    try {
      if ($script:PanelForm -and -not $script:PanelForm.IsDisposed) { $script:PanelForm.Close(); return }
      Update-Tray
      Show-Panel $script:State
    } catch { Write-Log "left click failed: $($_.Exception.Message)" }
  })

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
  $script:Timer.Add_Tick({ if (Test-ExitRequested) { return }; Update-Tray })
  $script:Timer.Start()

  Write-Log "tray started, version=$ToolVersion, interval=$($script:IntervalSec)s"
  Update-Tray
  [System.Windows.Forms.Application]::Run()
  Write-Log 'tray exited'
}

# ---------------------------------------------------------------- 入口

$state = Load-State
# 状态读不出来时，先试着用上一次的备份救回来（只有真出过事才知道这一步值钱）
if ($null -eq $state -and (Test-Path $BakPath)) {
  try {
    $bak = Get-Content $BakPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($bak -and $bak.PSObject.Properties['closed']) {
      $state = $bak
      Write-Log 'state missing or unreadable -> restored from state.bak.json'
    }
  } catch { Write-Log "backup unreadable: $($_.Exception.Message)" }
}
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

# 修历史脏键：Chrome 曾经把「正在出声 / 吃内存高」写进标签名，那些键带着尾巴，
# 跟看完名单对不上。这里统一洗一遍（只改键名，记录一条不丢）。
$fixed = Repair-StateKeys $state
if ($fixed -gt 0) { Write-Log "repaired $fixed dirty title keys" }

# 每次启动留一份上一版的备份。只在这份确实有内容时才覆盖，
# 免得把好备份冲成空的。
if ((Test-Path $StatePath) -and ((@($state.opened.PSObject.Properties).Count + @($state.closed.PSObject.Properties).Count) -gt 0)) {
  try { Copy-Item -Path $StatePath -Destination $BakPath -Force } catch { Write-Log "backup failed: $($_.Exception.Message)" }
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
