#requires -version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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
@"
set -euxo pipefail
PKG="dnf"; command -v dnf >/dev/null 2>&1 || PKG="yum"
sudo \$PKG -y install git curl || true
if ! command -v java >/dev/null 2>&1; then
  if [ "\$PKG" = "dnf" ]; then sudo dnf -y install java-17-amazon-corretto-devel
  else sudo amazon-linux-extras enable java-openjdk17 || true; sudo yum -y install java-17-amazon-corretto-devel; fi
fi
if [ ! -d "$dir" ]; then
  mkdir -p "$dir"; git clone "$repo" "$dir"
else
  if [ -d "$dir/.git" ]; then cd "$dir"; git fetch --all || true
  else rm -rf "$dir"/*; git clone "$repo" "$dir"; fi
fi
cd "$dir"; chmod +x ./gradlew || true
if [ -f app.pid ]; then kill \$(cat app.pid) || true; rm -f app.pid; fi
if command -v ss >/dev/null 2>&1; then
  PID=\$(ss -tlnp | awk '/:$port / {print \$NF}' | sed 's/.*pid=//;s/,.*//')
  [ -n "\$PID" ] && kill \$PID || true
else pkill -f 'gradle.*bootRun' || true; fi
nohup bash -lc "./gradlew --no-daemon bootRun > app.log 2>&1 & echo \$! > app.pid" || exit 1
for i in {1..60}; do
  if curl -fsS "http://127.0.0.1:$port$healthPath" | grep -qi 'UP\|200\|ok'; then echo HEALTH_OK; exit 0; fi
  sleep 3
done
echo HEALTH_TIMEOUT; exit 2
"@
}

function Invoke-SSM([string]$region,[string]$iid,[string]$commands,[string]$comment="gui-rolling") {
  $cmdId = Run-Cli @(
    "ssm","send-command",
    "--region",$region,
    "--instance-ids",$iid,
    "--document-name","AWS-RunShellScript",
    "--comment",$comment,
    "--parameters","commands=$([Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($commands))",
    "--query","Command.CommandId","--output","text"
  )
  $cmdId.Trim()
}
function Wait-SSM([string]$region,[string]$iid,[string]$cmdId) {
  Append-Log "Waiting SSM command $cmdId on $iid ..."
  Run-Cli @("ssm","wait","command-executed","--region",$region,"--command-id",$cmdId,"--instance-id",$iid) | Out-Null
}

function Deregister-Target([string]$region,[string]$tg,[string]$iid) {
  Append-Log "Deregister $iid from TG ..."
  Run-Cli @("elbv2","deregister-targets","--region",$region,"--target-group-arns",$tg,"--targets","Id=$iid") | Out-Null
  Run-Cli @("elbv2","wait","target-deregistered","--region",$region,"--target-group-arns",$tg,"--targets","Id=$iid") | Out-Null
}
function Register-Target([string]$region,[string]$tg,[string]$iid) {
  Append-Log "Register $iid to TG ..."
  Run-Cli @("elbv2","register-targets","--region",$region,"--target-group-arns",$tg,"--targets","Id=$iid") | Out-Null
  Run-Cli @("elbv2","wait","target-in-service","--region",$region,"--target-group-arns",$tg,"--targets","Id=$iid") | Out-Null
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
      $cmdId  = Invoke-SSM $region $iid $script "ensure+start $dir"
      Wait-SSM $region $iid $cmdId
      Append-Log "App started & health OK on $iid"

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
