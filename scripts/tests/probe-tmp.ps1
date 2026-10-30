# Temporary probe (removed before merge): the exception chain when a bad exe is called the way Invoke-AwsCli does
$dir = Join-Path ([IO.Path]::GetTempPath()) ('probe-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $dir | Out-Null
$exe = Join-Path $dir 'aws.exe'
[IO.File]::WriteAllText($exe, "not an executable`r`n", [Text.Encoding]::ASCII)
$ErrorActionPreference = 'Continue'
try {
    $all = & $exe 'ec2' 2>&1
    Write-Output "no exception; all=$all"
} catch {
    Write-Output "PS $($PSVersionTable.PSVersion) ErrorRecord: [$_]"
    $e = $_.Exception
    $i = 0
    while ($e) {
        Write-Output ("  [{0}] {1}: [{2}]" -f $i, $e.GetType().FullName, $e.Message)
        $e = $e.InnerException
        $i++
    }
    Write-Output "  PositionMessage: [$($_.InvocationInfo.PositionMessage)]"
}
