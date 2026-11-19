param(
  [Parameter(Mandatory = $true)][string]$Version,
  [Parameter(Mandatory = $true)][string]$SetupSha,
  [Parameter(Mandatory = $true)][string]$ExeSha
)
# Signs a release for PinShot's updates and prints the signature (hex, r then s): the bytes
# "pinshot-update\n<version>\n<setup_sha256>\n<exe_sha256>\n" signed with the release key (ECDSA P-256, SHA-256), which
# app/update_win.c checks with the public half it holds. The key's PEM file is at $env:PINSHOT_SIGN_KEY: kept in the
# owner's still.fail vault (「PinShot 更新签名私钥（ECDSA P-256）」), given to the command that publishes as a file of its
# own, never kept in the repository or on a machine. OpenSSL is Git for Windows' own.
$ErrorActionPreference = 'Stop'
if (-not $env:PINSHOT_SIGN_KEY -or -not (Test-Path $env:PINSHOT_SIGN_KEY)) {
  throw "PINSHOT_SIGN_KEY names no key file: run this with the release key from the vault"
}
$openssl = @((Get-Command openssl -ErrorAction SilentlyContinue).Source,
  "$env:ProgramFiles\Git\mingw64\bin\openssl.exe", "$env:ProgramFiles\Git\usr\bin\openssl.exe") |
  Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $openssl) { throw "openssl not found (Git for Windows has it)" }
$msg = Join-Path $env:TEMP "pinshot-release-$PID.txt"
$der = Join-Path $env:TEMP "pinshot-release-$PID.sig"
try {
  $text = "pinshot-update`n$Version`n$($SetupSha.ToLower())`n$($ExeSha.ToLower())`n"
  [IO.File]::WriteAllBytes($msg, [Text.Encoding]::ASCII.GetBytes($text))
  & $openssl dgst -sha256 -sign $env:PINSHOT_SIGN_KEY -out $der $msg
  if ($LASTEXITCODE) { throw "openssl could not sign" }
  # (DER: SEQUENCE { INTEGER r, INTEGER s }, each made 32 bytes as Windows' BCrypt takes it)
  $b = [IO.File]::ReadAllBytes($der)
  $at = 2
  if ($b[1] -band 0x80) { $at = 2 + ($b[1] -band 0x7f) }
  $hex = ""
  foreach ($i in 0, 1) {
    if ($b[$at] -ne 2) { throw "not a signature" }
    $n = $b[$at + 1]
    $v = $b[($at + 2)..($at + 1 + $n)]
    while ($v.Length -gt 32 -and $v[0] -eq 0) { $v = $v[1..($v.Length - 1)] }
    if ($v.Length -gt 32) { throw "not a P-256 signature" }
    $hex += ("00" * (32 - $v.Length)) + (($v | ForEach-Object { $_.ToString("x2") }) -join "")
    $at += 2 + $n
  }
  $hex
} finally {
  Remove-Item -Force -ErrorAction SilentlyContinue $msg, $der
}
