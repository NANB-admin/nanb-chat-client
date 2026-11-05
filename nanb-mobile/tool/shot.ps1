param(
  [Parameter(Mandatory=$true)][string]$Serial,
  [Parameter(Mandatory=$true)][string]$Out,
  [int]$Width = 432
)
# Capture an adb screenshot, downscale to $Width wide, write PNG to $Out.
$adb = "adb"
$raw = "$env:TEMP\shot_raw_$($Serial -replace '[^A-Za-z0-9]','_').png"
& $adb -s $Serial exec-out screencap -p > $raw 2>$null
# exec-out via PowerShell mangles bytes; use pull instead for reliability.
& $adb -s $Serial shell screencap -p /sdcard/_shot.png 2>$null | Out-Null
& $adb -s $Serial pull /sdcard/_shot.png $raw 2>$null | Out-Null
& $adb -s $Serial shell rm /sdcard/_shot.png 2>$null | Out-Null
Add-Type -AssemblyName System.Drawing
$img = [System.Drawing.Image]::FromFile($raw)
$ratio = $Width / $img.Width
$h = [int]($img.Height * $ratio)
$bmp = New-Object System.Drawing.Bitmap($Width, $h)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.DrawImage($img, 0, 0, $Width, $h)
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose(); $img.Dispose()
Remove-Item $raw -ErrorAction SilentlyContinue
Write-Host "saved $Out ($Width x $h)"
