param([switch]$BackupOnly, [switch]$NoDialog)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$configPath = Join-Path $PSScriptRoot 'config.json'
$script:SaveDir = ''
if (Test-Path -LiteralPath $configPath) {
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:SaveDir = [string]$config.SaveDir
}
if (!$script:SaveDir -or !(Test-Path -LiteralPath $script:SaveDir -PathType Container)) {
    $picker = New-Object System.Windows.Forms.FolderBrowserDialog
    $picker.Description = '请选择包含 PBZSaveGame.sav 的 Steam 账号存档文件夹'
    if ($picker.ShowDialog() -ne 'OK') { exit }
    $script:SaveDir = $picker.SelectedPath
    if (!(Test-Path -LiteralPath (Join-Path $script:SaveDir 'PBZSaveGame.sav'))) {
        [System.Windows.Forms.MessageBox]::Show('所选文件夹不包含 PBZSaveGame.sav。') | Out-Null
        exit 1
    }
    @{ SaveDir=$script:SaveDir } | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
}
$script:BackupDir = Join-Path $PSScriptRoot 'PBZ-Backups'
$script:OldBackupDir = Join-Path $PSScriptRoot 'Imported-Backups'

function New-SaveBackup {
    if (Get-Process -Name PBZ -ErrorAction SilentlyContinue) {
        throw '请先退出影之刃零，再备份，避免复制到正在写入的存档。'
    }
    if (!(Test-Path -LiteralPath (Join-Path $script:SaveDir 'PBZSaveGame.sav'))) {
        throw '未找到游戏主存档，请检查存档目录。'
    }
    New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null
    $name = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'
    $pending = Join-Path $script:BackupDir ('.partial-' + $name)
    $destination = Join-Path $script:BackupDir $name
    New-Item -ItemType Directory -Path $pending | Out-Null
    try {
        $files = @(Get-ChildItem -LiteralPath $script:SaveDir -File -Recurse)
        $manifest = @()
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($script:SaveDir.Length + 1)
            $copy = Join-Path $pending $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $copy) -Force | Out-Null
            $before = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            Copy-Item -LiteralPath $file.FullName -Destination $copy
            $copied = (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash
            $after = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            if ($before -ne $copied -or $after -ne $copied) { throw "文件在备份中发生变化：$relative。请退出 Steam 后重试。" }
            $manifest += [pscustomobject]@{ File=$relative; SHA256=$copied; Bytes=$file.Length }
        }
        $manifest | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $pending 'backup-manifest.json') -Encoding UTF8
        Rename-Item -LiteralPath $pending -NewName $name
        return $destination
    } catch {
        throw "备份未完成，不会覆盖已有备份。临时副本保留在 $pending`r`n$($_.Exception.Message)"
    }
}

if ($BackupOnly) {
    try {
        $result = New-SaveBackup
        if ($NoDialog) { Write-Output $result } else {
            [System.Windows.Forms.MessageBox]::Show("备份成功，已通过 SHA256 校验。`r`n$result", '影之刃零备份') | Out-Null
        }
        exit 0
    } catch {
        if ($NoDialog) { Write-Error $_ } else {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '备份未完成') | Out-Null
        }
        exit 1
    }
}

function Get-SaveCandidates {
    $seen = @{}
    foreach ($root in @($script:SaveDir, $script:BackupDir, $script:OldBackupDir)) {
        if (!(Test-Path -LiteralPath $root)) { continue }
        foreach ($file in (Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.sav')) {
            if ($file.FullName -match '\\.partial-' -or $file.FullName -eq (Join-Path $script:SaveDir 'PBZSaveGame.sav')) { continue }
            if ($file.Name -ne 'PBZSaveGame.sav' -and $file.Name -notmatch '^\d{8}-\d{6}-\d+\.sav$') { continue }
            $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            if ($seen.ContainsKey($hash)) { continue }
            $seen[$hash] = $true
            $date = $file.LastWriteTime
            if ($file.Name -match '^(\d{8}-\d{6})-') {
                $date = [datetime]::ParseExact($Matches[1], 'yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
            }
            $kind = '手动备份'
            if ($file.FullName -match '\\1RealTime\\') { $kind='实时历史' }
            elseif ($file.FullName -match '\\2Hourly\\') { $kind='小时历史' }
            elseif ($file.FullName -match '\\3Daily\\') { $kind='每日历史' }
            elseif ($file.FullName.StartsWith($script:OldBackupDir)) { $kind='首次恢复前备份' }
            [pscustomobject]@{ Path=$file.FullName; Date=$date; Kind=$kind; Bytes=$file.Length; Hash=$hash }
        }
    }
}

function Restore-SaveCandidate($candidate) {
    if (Get-Process -Name PBZ,steam -ErrorAction SilentlyContinue) {
        throw '请先退出游戏和 Steam（包括右下角托盘），再点击恢复。'
    }
    if ((Get-FileHash -LiteralPath $candidate.Path -Algorithm SHA256).Hash -ne $candidate.Hash) {
        throw '选中的文件已变化，请刷新列表后重新选择。'
    }
    $bytes = [IO.File]::ReadAllBytes($candidate.Path)
    if ($bytes.Length -lt 16 -or [Text.Encoding]::ASCII.GetString($bytes,0,4) -ne 'PBZS') {
        throw '不是可识别的 PBZS 存档，未执行恢复。'
    }
    $backup = New-SaveBackup
    $target = Join-Path $script:SaveDir 'PBZSaveGame.sav'
    $staged = Join-Path $script:SaveDir ('restore-' + [guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllBytes($staged,$bytes)
    if ((Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash -ne $candidate.Hash) {
        throw '恢复临时文件校验失败，当前存档未替换。'
    }
    if (Get-Process -Name PBZ,steam -ErrorAction SilentlyContinue) {
        throw '检测到游戏或 Steam 已启动，已中止替换。'
    }
    [IO.File]::Replace($staged,$target,(Join-Path $backup 'replacement-original.sav'))
    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $candidate.Hash) {
        throw "恢复后的校验异常。原进度备份位于：$backup"
    }
    return $backup
}

$script:NotesFile = Join-Path $PSScriptRoot 'PBZ-Save-Notes.json'
$script:Notes = @{}
if (Test-Path -LiteralPath $script:NotesFile) {
    try {
        $data = Get-Content -LiteralPath $script:NotesFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($prop in $data.PSObject.Properties) { $script:Notes[$prop.Name] = [string]$prop.Value }
    } catch { [System.Windows.Forms.MessageBox]::Show('进度备注文件无法读取，将暂时显示为空。','提示') | Out-Null }
}
$form = New-Object System.Windows.Forms.Form
$form.Text = '影之刃零 · 存档时间线与恢复'
$form.ClientSize = New-Object System.Drawing.Size(1020,650)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI',10)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(245,247,250)
function Add-Label($text,$x,$y,$w,$h) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text=$text; $label.SetBounds($x,$y,$w,$h)
    $form.Controls.Add($label)
    return $label
}
$title=Add-Label '选择历史时间点，找回当时的进度' 24 18 970 38
$title.Font=New-Object System.Drawing.Font('Microsoft YaHei UI',17,[System.Drawing.FontStyle]::Bold)
$null=Add-Label '恢复整份存档后，在游戏里选择具体条目。时间为文件快照时间，不等于游戏内保存时间。' 24 64 970 28
function Add-Action($text,$x,$w,$action) {
    $button=New-Object System.Windows.Forms.Button
    $button.Text=$text; $button.SetBounds($x,103,$w,40); $button.Add_Click($action)
    $form.Controls.Add($button)
    return $button
}
$null=Add-Action '一键备份当前进度' 24 180 {
    try {
        $status.Text='正在备份与校验…'; $form.Refresh()
        $path=New-SaveBackup; Update-BackupList
        $status.Text='备份完成：'+(Split-Path -Leaf $path)
    } catch { Show-Failure $_ }
}
$restore=Add-Action '恢复选中的存档' 216 180 {
    if ($list.SelectedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('请先选中一个历史存档。','提示') | Out-Null; return
    }
    $candidate=$list.SelectedItems[0].Tag
    $message="恢复时间点："+$candidate.Date.ToString('yyyy-MM-dd HH:mm:ss')+"
恢复前会自动备份当前进度。
请保持云同步关闭。是否继续？"
    $message=$message.Replace('
',"`r`n")
    if ([System.Windows.Forms.MessageBox]::Show($message,'确认恢复','YesNo','Question') -ne 'Yes') { return }
    try {
        $status.Text='正在保护当前存档并恢复…'; $form.Refresh()
        $backup=Restore-SaveCandidate $candidate
        Update-BackupList
        $status.Text='恢复成功，SHA256 校验通过。请启动游戏查看进度。'
        [System.Windows.Forms.MessageBox]::Show("恢复成功。原进度已备份到：`r`n$backup",'完成') | Out-Null
    } catch { Show-Failure $_ }
}
$restore.BackColor=[System.Drawing.Color]::FromArgb(35,105,190)
$restore.ForeColor=[System.Drawing.Color]::White
$null=Add-Action '打开备份目录' 408 160 {
    New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null
    Start-Process explorer.exe -ArgumentList ('"'+$script:BackupDir+'"')
}
$null=Add-Action '打开游戏存档' 580 160 {
    Start-Process explorer.exe -ArgumentList ('"'+$script:SaveDir+'"')
}
$null=Add-Action '刷新' 752 100 { Update-BackupList }
$filter=New-Object System.Windows.Forms.CheckBox
$filter.Text='仅看今天以前'; $filter.SetBounds(855,110,155,30)
$filter.Add_CheckedChanged({ Update-BackupList })
$form.Controls.Add($filter)

$list=New-Object System.Windows.Forms.ListView
$list.SetBounds(24,158,972,300)
$list.View='Details'; $list.FullRowSelect=$true; $list.MultiSelect=$false; $list.HideSelection=$false
$list.Columns.Add('历史快照时间',190) | Out-Null
$list.Columns.Add('来源',150) | Out-Null
$list.Columns.Add('大小',90) | Out-Null
$list.Columns.Add('进度备注（手动填写）',500) | Out-Null
$list.Add_SelectedIndexChanged({
    if ($list.SelectedItems.Count) {
        $c=$list.SelectedItems[0].Tag
        $detail.Text=$c.Path
        $noteBox.Text=[string]$script:Notes[$c.Hash]
    }
})
$list.Add_DoubleClick({
    if ($list.SelectedItems.Count) {
        Start-Process explorer.exe -ArgumentList ('/select,"'+$list.SelectedItems[0].Tag.Path+'"')
    }
})
$form.Controls.Add($list)
$detail=Add-Label '选择一条查看路径；双击可在文件夹中定位。' 24 465 972 40
$null=Add-Label '进度备注：' 24 517 95 28
$noteBox=New-Object System.Windows.Forms.TextBox
$noteBox.SetBounds(122,514,720,30); $form.Controls.Add($noteBox)
$saveNote=New-Object System.Windows.Forms.Button
$saveNote.Text='保存备注'; $saveNote.SetBounds(854,512,142,34)
$saveNote.Add_Click({
    if (!$list.SelectedItems.Count) { return }
    try {
        $c=$list.SelectedItems[0].Tag
        $script:Notes[$c.Hash]=$noteBox.Text
        $script:Notes | ConvertTo-Json | Set-Content -LiteralPath $script:NotesFile -Encoding UTF8
        $list.SelectedItems[0].SubItems[3].Text=$noteBox.Text
        $status.Text='备注已保存，同一份存档的副本共享备注。'
    } catch { Show-Failure $_ }
})
$form.Controls.Add($saveNote)
$status=Add-Label '准备就绪。' 24 560 972 30
$null=Add-Label '地点/时长尚无法可靠解析；载入确认后可写备注。相同内容已去重。恢复不会删除历史副本。' 24 605 972 28
function Show-Failure($failure) {
    $status.Text='操作未完成，请查看提示。'
    [System.Windows.Forms.MessageBox]::Show($failure.Exception.Message,'操作未完成') | Out-Null
}
function Update-BackupList {
    $list.BeginUpdate()
    try {
        $list.Items.Clear()
        foreach ($c in (Get-SaveCandidates | Sort-Object Date -Descending)) {
            if ($filter.Checked -and $c.Date.Date -ge (Get-Date).Date) { continue }
            $item=New-Object System.Windows.Forms.ListViewItem($c.Date.ToString('yyyy-MM-dd HH:mm:ss'))
            $item.SubItems.Add($c.Kind) | Out-Null
            $item.SubItems.Add(('{0:N1} KB' -f ($c.Bytes/1KB))) | Out-Null
            $item.SubItems.Add([string]$script:Notes[$c.Hash]) | Out-Null
            $item.Tag=$c; $list.Items.Add($item) | Out-Null
        }
        $detail.Text='选择一条查看路径；双击可在文件夹中定位。'
        $noteBox.Text=''
        $status.Text="找到 $($list.Items.Count) 个不同内容的历史快照。"
    } finally { $list.EndUpdate() }
}
Update-BackupList
[void]$form.ShowDialog()
