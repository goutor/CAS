#!/usr/bin/env pwsh
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$SrcDir = Join-Path $Root "src"
$AssetsDir = Join-Path $Root "assets"
$DistDir = Join-Path $Root "dist"
$SourceFile = Join-Path $SrcDir "CodexAccountSwitcher.cs"
$PngIconFile = Join-Path $AssetsDir "AppIcon-1024.png"
$IcoFile = Join-Path $AssetsDir "AppIcon.ico"
$ExeFile = Join-Path $DistDir "CodexAccountSwitcher.exe"

New-Item -ItemType Directory -Path $AssetsDir -Force | Out-Null
New-Item -ItemType Directory -Path $DistDir -Force | Out-Null

function Write-UInt16LE {
    param(
        [System.IO.BinaryWriter]$Writer,
        [int]$Value
    )
    $Writer.Write([byte]($Value -band 0xFF))
    $Writer.Write([byte](($Value -shr 8) -band 0xFF))
}

function Write-UInt32LE {
    param(
        [System.IO.BinaryWriter]$Writer,
        [int]$Value
    )
    $Writer.Write([byte]($Value -band 0xFF))
    $Writer.Write([byte](($Value -shr 8) -band 0xFF))
    $Writer.Write([byte](($Value -shr 16) -band 0xFF))
    $Writer.Write([byte](($Value -shr 24) -band 0xFF))
}

function Convert-PngToIco {
    param(
        [string]$PngPath,
        [string]$IcoPath
    )

    Add-Type -AssemblyName System.Drawing
    $sizes = @(256, 128, 64, 48, 32, 16)
    $source = [System.Drawing.Image]::FromFile($PngPath)
    $frames = @()
    try {
        foreach ($size in $sizes) {
            $bitmap = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            try {
                $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
                try {
                    $graphics.Clear([System.Drawing.Color]::Transparent)
                    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                    $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
                    $graphics.DrawImage($source, 0, 0, $size, $size)
                } finally {
                    $graphics.Dispose()
                }

                $memory = New-Object System.IO.MemoryStream
                try {
                    $bitmap.Save($memory, [System.Drawing.Imaging.ImageFormat]::Png)
                    $frames += [pscustomobject]@{
                        Size = $size
                        Bytes = $memory.ToArray()
                    }
                } finally {
                    $memory.Dispose()
                }
            } finally {
                $bitmap.Dispose()
            }
        }
    } finally {
        $source.Dispose()
    }

    $stream = [System.IO.File]::Open($IcoPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    try {
        $writer = New-Object System.IO.BinaryWriter($stream)
        try {
            # ICONDIR
            Write-UInt16LE -Writer $writer -Value 0
            Write-UInt16LE -Writer $writer -Value 1
            Write-UInt16LE -Writer $writer -Value $frames.Count

            $offset = 6 + (16 * $frames.Count)
            foreach ($frame in $frames) {
                $encodedSize = if ($frame.Size -eq 256) { 0 } else { $frame.Size }
                $writer.Write([byte]$encodedSize)
                $writer.Write([byte]$encodedSize)
                $writer.Write([byte]0)
                $writer.Write([byte]0)
                Write-UInt16LE -Writer $writer -Value 1
                Write-UInt16LE -Writer $writer -Value 32
                Write-UInt32LE -Writer $writer -Value $frame.Bytes.Length
                Write-UInt32LE -Writer $writer -Value $offset
                $offset += $frame.Bytes.Length
            }

            foreach ($frame in $frames) {
                $writer.Write($frame.Bytes)
            }
        } finally {
            $writer.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Get-CscPath {
    $candidates = @(
        "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    throw "csc.exe was not found."
}

if (-not (Test-Path -LiteralPath $PngIconFile)) {
    $iconUrl = "https://raw.githubusercontent.com/goutor/CAS/main/MacOS/Assets/AppIcon-1024.png"
    Write-Host "Downloading icon from GitHub..."
    Invoke-WebRequest -Uri $iconUrl -OutFile $PngIconFile -UseBasicParsing
} else {
    Write-Host "Using cached GitHub icon..."
}

Write-Host "Converting PNG to ICO..."
Convert-PngToIco -PngPath $PngIconFile -IcoPath $IcoFile

$csc = Get-CscPath
Write-Host "Compiling Windows EXE..."
& $csc `
    /nologo `
    /target:winexe `
    /optimize+ `
    /unsafe- `
    /win32icon:$IcoFile `
    /out:$ExeFile `
    /r:System.dll `
    /r:System.Core.dll `
    /r:System.Drawing.dll `
    /r:System.Windows.Forms.dll `
    $SourceFile

if ($LASTEXITCODE -ne 0) {
    throw "Compilation failed with exit code $LASTEXITCODE."
}

Write-Host "Built: $ExeFile"
