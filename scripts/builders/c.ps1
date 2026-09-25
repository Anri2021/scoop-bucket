[CmdletBinding()]
param($Plan, $SourceRoot, $PackageDir, $CacheRoot)

$bash = "C:\msys64\usr\bin\bash.exe"
if (-not (Test-Path $bash)) { throw "MSYS2 bash was not found." }
$buildScript = @'
set -e
export PATH="/mingw64/bin:/usr/bin:$PATH"
pacman -S --noconfirm --needed mingw-w64-x86_64-gcc mingw-w64-x86_64-glib2 mingw-w64-x86_64-pkgconf autoconf automake libtool bison flex make
autoreconf -fi
./configure --prefix=/mingw64 --disable-man
make -j$(nproc)
'@ -replace "`r`n", "`n"

Set-Content (Join-Path $SourceRoot "build.sh") -Value $buildScript -Encoding ascii
Invoke-Checked $bash @("-lc", ("cd '{0}' && ./build.sh" -f ($SourceRoot -replace '\\', '/')))

Get-ChildItem (Join-Path $SourceRoot "src/util/.libs/*.exe") | Copy-Item -Destination $PackageDir -Force
Get-ChildItem (Join-Path $SourceRoot "src/libmdb/.libs/*.dll") | Copy-Item -Destination $PackageDir -Force
$mingwDlls = @("libglib-2.0-0.dll", "libintl-8.dll", "libiconv-2.dll", "libpcre2-8-0.dll", "libwinpthread-1.dll")
foreach ($dll in $mingwDlls) {
  $dllPath = "C:\msys64\mingw64\bin\$dll"
  if (Test-Path $dllPath) { Copy-Item $dllPath -Destination $PackageDir -Force }
}
