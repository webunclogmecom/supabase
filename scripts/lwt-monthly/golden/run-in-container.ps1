# Runs the golden proof in a container with no network, no secrets, no capabilities.
# monthly.js is the bot's page: it is copied into -Work here and never lives in this repo.
#   powershell -File run-in-container.ps1 -MonthlyJs <path to monthly.js> -Work <empty scratch folder>
param(
  [Parameter(Mandatory = $true)][string]$MonthlyJs,
  [Parameter(Mandatory = $true)][string]$Work,
  [string]$Extra = ""
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
New-Item -ItemType Directory -Force "$Work\golden" | Out-Null
Copy-Item -Force "$root\monthly-rules.ts", "$root\package.json" $Work
Copy-Item -Force "$here\run-golden.mjs", "$here\sequences.mjs" "$Work\golden"
Copy-Item -Force $MonthlyJs "$Work\monthly.js"
$args2 = @("run", "--rm", "--network", "none", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
           "--read-only", "--tmpfs", "/tmp", "--user", "node", "--memory", "2g", "--pids-limit", "256",
           "-v", "${Work}:/work:ro", "node:22-slim",
           "node", "--experimental-strip-types", "--no-warnings", "/work/golden/run-golden.mjs", "/work/monthly.js")
if ($Extra) { $args2 += $Extra }
& docker @args2
exit $LASTEXITCODE
