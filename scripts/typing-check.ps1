#!/usr/bin/env pwsh

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/bootstrap.ps1"

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# The typing gate needs the emmylua type model. MCP renders no wiki, so provision
# just that tier (-TypeModel) rather than the omnibus -Wiki, which also pulls MoonSharp.
Initialize-GmodTools -Root $Root -TypeModel | Out-Null

$result = Test-GmodTyping -RepoRoot $Root
if (-not $result.Ok) { exit 1 }
exit 0
