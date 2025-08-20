#requires -version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 1) 모듈 준비 (최초 1회만)
$modules = @("AWS.Tools.Common","AWS.Tools.SimpleSystemsManagement")
foreach ($m in $modules) {
  if (-not (Get-Module -ListAvailable -Name $m)) {
    Install-Module $m -Scope CurrentUser -Force -AllowClobber
  }
}

Import-Module AWS.Tools.Common
Import-Module AWS.Tools.SimpleSystemsManagement

# ---------- UI ----------
$form                  = New-Object System.Windows.Forms.Form
$form.Text             = "AWS Rolling Update (SSM) GUI"
$form.Size             = New-Object System.Drawing.Size(1100,750)
$form.StartPosition    = "CenterScreen"

$lblRegion   = New-Object System.Windows.Forms.Label
$lblRegion.Text = "Region:"
$lblRegion.Width = 70
$lblRegion.Location = "10,15"
$txtRegion   = New-Object System.Windows.Forms.TextBox
$txtRegion.Location = "85,10"; $txtRegion.Width = 200
$txtRegion.Text = "ap-northeast-2"

$lblTG = New-Object System.Windows.Forms.Label
$lblTG.Text = "Target Group ARN:"
$lblTG.Width = 120
$lblTG.Location = "300,15"
$txtTG = New-Object System.Windows.Forms.TextBox
$txtTG.Location = "430,10"; $txtTG.Width = 640

$lblPort = New-Object System.Windows.Forms.Label
$lblPort.Text = "App Port:"
$lblPort.Width = 70
$lblPort.Location = "10,45"
$numPort = New-Object System.Windows.Forms.NumericUpDown
$numPort.Location = "85,40"; $numPort.Minimum=1; $numPort.Maximum=65535; $numPort.Value=8080

$lblHealth = New-Object System.Windows.Forms.Label
$lblHealth.Text = "Health Path:"
$lblHealth.Width = 80
$lblHealth.Location = "210,45"
$txtHealth = New-Object System.Windows.Forms.TextBox
$txtHealth.Location = "290,40"; $txtHealth.Width = 260
$txtHealth.Text = "/"

$btnValidate = New-Object System.Windows.Forms.Button
$btnValidate.Text = "Validate AWS"
$btnValidate.Location = "570,38"; $btnValidate.Width = 120

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = "Run Rolling Update"
$btnRun.Location = "700,38"; $btnRun.Width = 150

$btnAdd = New-Object System.Windows.Forms.Button
$btnAdd.Text = "Add Row"
$btnAdd.Location = "860,38"; $btnAdd.Width = 90

$btnRemove = New-Object System.Windows.Forms.Button
$btnRemove.Text = "Remove Selected"
$btnRemove.Location = "960,38"; $btnRemove.Width = 120

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = "10,75"; $grid.Size = "1070,300"
$grid.AllowUserToAddRows = $false
$grid.RowHeadersVisible = $false
$grid.SelectionMode = "FullRowSelect"
$grid.AutoSizeColumnsMode = "Fill"
$grid.Columns.Add("InstanceId","InstanceId")   | Out-Null
$grid.Columns.Add("Dir","Service Directory")   | Out-Null
$grid.Columns.Add("Repo","Git Repo URL")       | Out-Null

# 샘플 2행
$grid.Rows.Add(@("i-xxxxxxxxweb01","/home/ec2-user/ssd_day2_h2baseapp","https://github.com/dev-library/sd_day2_h2baseapp.git"))|Out-Null
$grid.Rows.Add(@("i-xxxxxxxxweb02","/home/ec2-user/swu_stresstest_example","https://github.com/dev-library/swu_stresstest_example.git"))|Out-Null

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = "Log:"
$lblLog.Location = "10,345"

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.Location = "10,390"; $txtLog.Size = "1070,300"
$txtLog.Font = New-Object System.Drawing.Font("Consolas",9)

$form.Controls.AddRange(@(
  $lblRegion,$txtRegion,$lblTG,$txtTG,$lblPort,$numPort,$lblHealth,$txtHealth,
  $btnValidate,$btnRun,$btnAdd,$btnRemove,$grid,$lblLog,$txtLog
))

# ---------- Helpers ----------
function Append-Log([string]$msg,[string]$level="INFO") {
  $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  $line = "[$ts][$level] $msg"
  $txtLog.AppendText($line + [Environment]::NewLine)
  [System.Windows.Forms.Application]::DoEvents()
}

function Run-Cli($argsArray) {
  # argsArray는 문자열 배열. 예: @('ssm','send-command','--region', $Region, ...)
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "aws"
    $psi.Arguments = ($argsArray -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    if ($out) { Append-Log $out.Trim() }
    if ($err) { Append-Log $err.Trim() "WARN" }
    if ($p.ExitCode -ne 0) { throw "aws exitcode $($p.ExitCode)" }
    return $out
  } catch {
    Append-Log "CLI error: $_" "ERROR"; throw
  }
}

function Build-EnsureStartScript([string]$dir,[string]$repo,[int]$port,[string]$healthPath) {
$tpl = @'
#!/usr/bin/env bash
set -euxo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 1. 소스 디렉토리 준비
if [ ! -d "__DIR__" ]; then
  mkdir -p "__DIR__"
  git clone "__REPO__" "__DIR__"
else
  if [ -d "__DIR__/.git" ]; then
    cd "__DIR__"
    git fetch --all || true
    git reset --hard origin/$(git rev-parse --abbrev-ref HEAD) || true
  else
    rm -rf "__DIR__"/*
    git clone "__REPO__" "__DIR__"
  fi
fi

cd "__DIR__"
chmod +x ./gradlew || true

# 2. 기존 프로세스 종료
if [ -f app.pid ]; then
  kill $(cat app.pid) || true
  rm -f app.pid
fi

if command -v ss >/dev/null 2>&1; then
  PID=$(ss -tlnp 2>/dev/null | awk -v p=":__PORT__" '$0 ~ p {print $NF}' | sed -E 's/.*pid=([0-9]+).*/\1/')
  [ -n "$PID" ] && kill $PID || true
else
  pkill -f "gradle.*bootRun" || true
fi

# 3. 새 프로세스 기동
nohup ./gradlew --no-daemon bootRun > app.log 2>&1 & echo $! > app.pid

# 4. 헬스체크 (최대 3분)
for i in {1..60}; do
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:__PORT____HEALTH__" || true)
  if [ "$HTTP" = "200" ]; then
    echo "HEALTH_OK (200)"
    exit 0
  fi
  sleep 3
done

echo "HEALTH_TIMEOUT (last=$HTTP)"
exit 2
'@

# 플레이스홀더 치환
$tpl = $tpl.Replace('__DIR__', $dir)
$tpl = $tpl.Replace('__REPO__', $repo)
$tpl = $tpl.Replace('__PORT__', [string]$port)
$tpl = $tpl.Replace('__HEALTH__', $healthPath)

return $tpl
}

# 작은따옴표 이스케이프 대신 Base64 인코딩으로 안전 실행
function Build-BashOneLiner([string]$script) {
  # ✅ 줄바꿈 정규화: CRLF/CR -> LF
  $unix = ($script -replace "`r`n","`n" -replace "`r","")
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($unix)
  $b64   = [Convert]::ToBase64String($bytes)
  # ✅ bash로 명시 실행
  return "bash -lc 'echo $b64 | base64 -d | /usr/bin/env bash -s'"
}



function Invoke-SSMScript(
  [Parameter(Mandatory)] [string]$Region,
  [Parameter(Mandatory)] [string]$InstanceId,
  [Parameter(Mandatory)] [string]$Script,
  [string]$Comment = "gui-rolling"
) {
  try {
    $cmd = Build-BashOneLiner $Script

   $resp = Send-SSMCommand `
          -Region $Region `
          -InstanceId $InstanceId `
          -DocumentName 'AWS-RunShellScript' `
          -Comment $Comment `
          -Parameter @{ commands = @($cmd) }

    # 다양한 모듈/버전에 견고하게 대응
    $cmdId =
        if ($resp.PSObject.Properties['CommandId']) { $resp.CommandId }
        elseif ($resp.PSObject.Properties['Command'] -and $resp.Command.PSObject.Properties['CommandId']) { $resp.Command.CommandId }
        else { $null }

    if (-not $cmdId) {
      throw "Send-SSMCommand returned no CommandId. Raw: $($resp | ConvertTo-Json -Depth 8)"
    }

    return $cmdId

  }
  catch {
    Append-Log "Invoke-SSMScript error: $_" "ERROR"
    throw
  }
}

function Get-SSMInvocationDetails {
  param(
    [Parameter(Mandatory)] [string]$Region,
    [Parameter(Mandatory)] [string]$InstanceId,
    [Parameter(Mandatory)] [string]$CommandId
  )
  try {
    # -Details 가 핵심: 플러그인(aws:runShellScript)별 상태/출력 확보
    $inv = Get-SSMCommandInvocation -Region $Region -CommandId $CommandId -InstanceId $InstanceId -Details $true -ErrorAction Stop

    Append-Log "SSM Invocation Summary => Status: $($inv.Status), StatusDetails: $($inv.StatusDetails), ResponseCode: $($inv.ResponseCode)" "INFO"

    if ($inv.CommandPlugins) {
      foreach ($pl in $inv.CommandPlugins) {
        Append-Log ("Plugin: {0} | Status: {1} | Code: {2} | Name: {3}" -f $pl.Name, $pl.Status, $pl.ResponseCode, $pl.OutputS3KeyPrefix) "INFO"
        if ($pl.Output)   { Append-Log ("[Plugin-Output]\n" + $pl.Output.Trim()) }
        if ($pl.StandardOutputContent) { Append-Log ("[StdOut]\n" + $pl.StandardOutputContent.Trim()) }
        if ($pl.StandardErrorContent)  { Append-Log ("[StdErr]\n" + $pl.StandardErrorContent.Trim()) "WARN" }
      }
    } else {
      # 구버전 모듈/에이전트일 때 대비
      if ($inv.StandardOutputContent) { Append-Log ("[StdOut]\n" + $inv.StandardOutputContent.Trim()) }
      if ($inv.StandardErrorContent)  { Append-Log ("[StdErr]\n" + $inv.StandardErrorContent.Trim()) "WARN" }
    }
  } catch {
    Append-Log "Get-SSMInvocationDetails error: $_" "ERROR"
  }
}


function Wait-SSMCommand {
  param(
    [Parameter(Mandatory)] [string]$Region,
    [Parameter(Mandatory)] [string]$InstanceId,
    [Parameter(Mandatory)] [string]$CommandId,
    [int]$TimeoutSeconds = 900
  )
  $sw = [Diagnostics.Stopwatch]::StartNew()
  do {
    Start-Sleep -Seconds 3
    $inv = Get-SSMCommandInvocation -Region $Region -CommandId $CommandId -InstanceId $InstanceId -ErrorAction SilentlyContinue
    if ($inv -and $inv.Status -in 'Success','Failed','Cancelled','TimedOut') {
      # ✅ 종료상태면 상세 로그 남김
      Get-SSMInvocationDetails -Region $Region -InstanceId $InstanceId -CommandId $CommandId | Out-Null
      return $inv
    }
  } while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds)
  throw "SSM command timeout after $TimeoutSeconds seconds"
}



function Deregister-Target([string]$region,[string]$tg,[string]$iid) {
  Append-Log "Deregister $iid from TG ..."
  Run-Cli @("elbv2","deregister-targets","--region",$region,"--target-group-arn",$tg,"--targets","Id=$iid") | Out-Null
  Run-Cli @("elbv2","wait","target-deregistered","--region",$region,"--target-group-arn",$tg,"--targets","Id=$iid") | Out-Null
}
function Register-Target([string]$region,[string]$tg,[string]$iid) {
  Append-Log "Register $iid to TG ..."
  Run-Cli @("elbv2","register-targets","--region",$region,"--target-group-arn",$tg,"--targets","Id=$iid") | Out-Null
  Run-Cli @("elbv2","wait","target-in-service","--region",$region,"--target-group-arn",$tg,"--targets","Id=$iid") | Out-Null
}

# ---------- Buttons ----------
$btnAdd.Add_Click({
  $grid.Rows.Add(@("i-xxxxxxxx","/home/ec2-user/app","https://github.com/org/repo.git")) | Out-Null
})

$btnRemove.Add_Click({
  foreach ($r in @($grid.SelectedRows)) { $grid.Rows.Remove($r) }
})

$btnValidate.Add_Click({
  try {
    Append-Log "=== Validation start ==="
    $region = $txtRegion.Text.Trim()
    $tg     = $txtTG.Text.Trim()
    Run-Cli @("sts","get-caller-identity","--region",$region) | Out-Null
    if ($tg) { Run-Cli @("elbv2","describe-target-groups","--region",$region,"--target-group-arns",$tg) | Out-Null }
    Append-Log "Validation OK." "INFO"
  } catch {
    Append-Log "Validation failed: $_" "ERROR"
  }
})

$btnRun.Add_Click({
  $btnRun.Enabled = $false; $btnValidate.Enabled = $false
  try {
    $region  = $txtRegion.Text.Trim()
    $tg      = $txtTG.Text.Trim()
    $port    = [int]$numPort.Value
    $health  = $txtHealth.Text.Trim()
    if (-not $region -or -not $tg) { throw "Region/TargetGroup ARN is required." }
    if ($grid.Rows.Count -eq 0) { throw "No instances provided." }

    Append-Log "=== Rolling Update START ==="
    Append-Log "Region: $region"
    Append-Log "TG ARN: $tg"
    Append-Log "Port/Health: $port $health"

    foreach ($row in $grid.Rows) {
      $iid  = $row.Cells[0].Value; $dir = $row.Cells[1].Value; $repo = $row.Cells[2].Value
      if (-not $iid -or -not $dir -or -not $repo) { throw "Row has empty fields. Fill InstanceId/Dir/Repo." }

      Append-Log "---- Instance $iid ----"
      Deregister-Target $region $tg $iid

      $script = Build-EnsureStartScript $dir $repo $port $health

      # ★ SSM 모듈 방식으로 호출
      $cmdId = Invoke-SSMScript -Region $region -InstanceId $iid -Script $script -Comment "ensure+start $dir"
      Append-Log "SSM CommandId: $cmdId"

      $inv = Wait-SSMCommand -Region $region -InstanceId $iid -CommandId $cmdId -TimeoutSeconds 900

    # 이 시점에 상세 로그는 이미 Append-Log 로 찍힘.
    if ($inv.Status -ne 'Success') {
        # StatusDetails 빈칸 대응 위해 보조 메시지 추가
        $detail = if ($inv.StatusDetails) { $inv.StatusDetails } else { "(no StatusDetails)" }
        $code   = if ($inv.ResponseCode -ne $null) { $inv.ResponseCode } else { "(no code)" }
        throw ("SSM failed on {0}: {1} ({2})" -f $iid, $detail, $code)
    }

      if ($inv.StandardOutputContent) { Append-Log ($inv.StandardOutputContent.Trim()) }
      if ($inv.StandardErrorContent)  { Append-Log ($inv.StandardErrorContent.Trim()) "WARN" }

      Register-Target $region $tg $iid
      Append-Log "DONE for $iid"
    }

    Append-Log "=== Rolling Update COMPLETE ===" "INFO"
  } catch {
    Append-Log "RUN FAILED: $_" "ERROR"
  } finally {
    $btnRun.Enabled = $true; $btnValidate.Enabled = $true
  }
})


[void]$form.ShowDialog()
