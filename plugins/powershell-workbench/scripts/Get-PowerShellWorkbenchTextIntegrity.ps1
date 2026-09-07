[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [string[]]$IncludeExtension = @('.ps1','.psm1','.psd1'),
    [ValidateRange(1,1073741824)][long]$MaximumFileBytes = 16777216,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedByteSha256,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedNormalizedTextSha256,
    [ValidateSet('Utf8NoBom','Utf8Bom','Utf16LittleEndianBom','Utf16BigEndianBom','Utf32LittleEndianBom','Utf32BigEndianBom')][string[]]$AllowedEncoding,
    [ValidateSet('LF','CRLF','CR','None')][string[]]$AllowedLineEnding,
    [switch]$DisallowMixedLineEndings,
    [switch]$AsJson,
    [switch]$NoThrow
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$failedGates = New-Object 'System.Collections.Generic.List[string]'

function Add-FailedGate { param([string]$Gate) if(-not $failedGates.Contains($Gate)){[void]$failedGates.Add($Gate)} }
function Get-ByteSha256 { param([byte[]]$Bytes) $sha=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()} }
function Get-FileSnapshot {
    param([string]$LiteralPath,[long]$ByteLimit)
    $file=Get-Item -LiteralPath $LiteralPath -Force
    if($file.Length -gt $ByteLimit){return [pscustomobject]@{Bytes=$null;Length=[int64]$file.Length;Stable=$true;OverLimit=$true}}
    $stream=[IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        $initial=$stream.Length;$bytes=New-Object byte[] $initial;$offset=0
        while($offset -lt $bytes.Length){$read=$stream.Read($bytes,$offset,$bytes.Length-$offset);if($read -eq 0){break};$offset+=$read}
        $stable=($stream.Length -eq $initial -and $offset -eq $initial)
        if(-not $stable){return [pscustomobject]@{Bytes=$null;Length=[int64]$offset;Stable=$false;OverLimit=$false}}
        [pscustomobject]@{Bytes=$bytes;Length=[int64]$initial;Stable=$true;OverLimit=$false}
    }finally{$stream.Dispose()}
}
function Convert-TextSnapshot {
    param([byte[]]$Bytes)
    $encodingName='UnknownOrInvalid';$offset=0;$decoder=$null
    if($Bytes.Length -ge 4 -and $Bytes[0]-eq 0x00 -and $Bytes[1]-eq 0x00 -and $Bytes[2]-eq 0xfe -and $Bytes[3]-eq 0xff){$encodingName='Utf32BigEndianBom';$offset=4;$decoder=New-Object Text.UTF32Encoding($true,$true)}
    elseif($Bytes.Length -ge 4 -and $Bytes[0]-eq 0xff -and $Bytes[1]-eq 0xfe -and $Bytes[2]-eq 0x00 -and $Bytes[3]-eq 0x00){$encodingName='Utf32LittleEndianBom';$offset=4;$decoder=New-Object Text.UTF32Encoding($false,$true)}
    elseif($Bytes.Length -ge 3 -and $Bytes[0]-eq 0xef -and $Bytes[1]-eq 0xbb -and $Bytes[2]-eq 0xbf){$encodingName='Utf8Bom';$offset=3;$decoder=New-Object Text.UTF8Encoding($false,$true)}
    elseif($Bytes.Length -ge 2 -and $Bytes[0]-eq 0xff -and $Bytes[1]-eq 0xfe){$encodingName='Utf16LittleEndianBom';$offset=2;$decoder=New-Object Text.UnicodeEncoding($false,$true,$true)}
    elseif($Bytes.Length -ge 2 -and $Bytes[0]-eq 0xfe -and $Bytes[1]-eq 0xff){$encodingName='Utf16BigEndianBom';$offset=2;$decoder=New-Object Text.UnicodeEncoding($true,$true,$true)}
    else{$encodingName='Utf8NoBom';$decoder=New-Object Text.UTF8Encoding($false,$true)}
    try{$text=$decoder.GetString($Bytes,$offset,$Bytes.Length-$offset);[pscustomobject]@{Text=$text;Encoding=$encodingName;Readable=$true}}catch{[pscustomobject]@{Text=$null;Encoding='UnknownOrInvalidUtf8';Readable=$false}}
}
function Get-LineEndingSummary {
    param([string]$Text)
    $crlf=[regex]::Matches($Text,"`r`n").Count;$lf=[regex]::Matches($Text,"(?<!`r)`n").Count;$cr=[regex]::Matches($Text,"`r(?!`n)").Count
    $styles=@();if($crlf -gt 0){$styles+='CRLF'};if($lf -gt 0){$styles+='LF'};if($cr -gt 0){$styles+='CR'}
    $style=if($styles.Count -eq 0){'None'}elseif($styles.Count -eq 1){$styles[0]}else{'Mixed'}
    [pscustomobject]@{Style=$style;CrLfCount=$crlf;LfCount=$lf;CrCount=$cr}
}
function Get-TargetFile {
    param([string]$ResolvedPath,[string[]]$Extensions)
    $extensionSet=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($extension in $Extensions){
        if(-not [string]::IsNullOrWhiteSpace($extension)){
            $normalizedExtension=$extension
            if(-not $normalizedExtension.StartsWith('.')){$normalizedExtension=".$normalizedExtension"}
            [void]$extensionSet.Add($normalizedExtension)
        }
    }
    $item=Get-Item -LiteralPath $ResolvedPath -Force
    if(-not $item.PSIsContainer){if($extensionSet.Contains($item.Extension)){return @($item)};return @()}
    $results=New-Object 'System.Collections.Generic.List[object]';$pending=New-Object 'System.Collections.Generic.Queue[string]';$pending.Enqueue($item.FullName)
    while($pending.Count -gt 0){
        foreach($child in @(Get-ChildItem -LiteralPath $pending.Dequeue() -Force)){
            if($child.PSIsContainer){if(-not ($child.Attributes -band [IO.FileAttributes]::ReparsePoint)){$pending.Enqueue($child.FullName)}}
            elseif($extensionSet.Contains($child.Extension)){$results.Add($child)}
        }
    }
    @($results | Sort-Object FullName)
}

try {
    $resolved=(Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $item=Get-Item -LiteralPath $resolved -Force
    if($item.PSIsContainer -and ($ExpectedByteSha256 -or $ExpectedNormalizedTextSha256)){Add-FailedGate 'ExpectedHashesRequireFile'}
    $files=@(Get-TargetFile -ResolvedPath $resolved -Extensions $IncludeExtension)
    if($files.Count -eq 0){Add-FailedGate 'MatchingFilesPresent'}
    $records=@(foreach($file in $files){
        $snapshot=Get-FileSnapshot -LiteralPath $file.FullName -ByteLimit $MaximumFileBytes
        $relative=if($item.PSIsContainer){$file.FullName.Substring($item.FullName.TrimEnd('\').Length).TrimStart('\').Replace('\','/')}else{$file.Name}
        if($snapshot.OverLimit){[pscustomobject]@{Path=$relative;ByteLength=$snapshot.Length;State='SKIPPED_TOO_LARGE';ByteSha256=$null;Encoding=$null;LineEndings=$null;NormalizedTextSha256=$null;ComparisonState='UNKNOWN'}}
        elseif(-not $snapshot.Stable){[pscustomobject]@{Path=$relative;ByteLength=$snapshot.Length;State='CHANGED_DURING_READ';ByteSha256=$null;Encoding=$null;LineEndings=$null;NormalizedTextSha256=$null;ComparisonState='UNKNOWN'}}
        else{
            $textSnapshot=Convert-TextSnapshot -Bytes $snapshot.Bytes;$byteHash=Get-ByteSha256 -Bytes $snapshot.Bytes
            if(-not $textSnapshot.Readable){[pscustomobject]@{Path=$relative;ByteLength=$snapshot.Length;State='NOT_UTF8_TEXT';ByteSha256=$byteHash;Encoding=$textSnapshot.Encoding;LineEndings=$null;NormalizedTextSha256=$null;ComparisonState='UNKNOWN'}}
            else{
                $lineEndings=Get-LineEndingSummary -Text $textSnapshot.Text;$normalized=$textSnapshot.Text.Replace("`r`n","`n").Replace("`r","`n");$normalizedHash=Get-ByteSha256 -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($normalized))
                $comparison=if(-not $ExpectedByteSha256 -and -not $ExpectedNormalizedTextSha256){'NOT_REQUESTED'}elseif($ExpectedByteSha256 -and $byteHash -eq $ExpectedByteSha256.ToLowerInvariant()){'BYTE_IDENTICAL'}elseif($ExpectedNormalizedTextSha256 -and $normalizedHash -eq $ExpectedNormalizedTextSha256.ToLowerInvariant()){'BYTE_ONLY_DRIFT'}else{'SEMANTIC_DRIFT'}
                [pscustomobject]@{Path=$relative;ByteLength=$snapshot.Length;State='TEXT';ByteSha256=$byteHash;Encoding=$textSnapshot.Encoding;LineEndings=$lineEndings;NormalizedTextSha256=$normalizedHash;ComparisonState=$comparison}
            }
        }
    })
    if(@($records|Where-Object {$_.State -in @('CHANGED_DURING_READ','NOT_UTF8_TEXT')}).Count -gt 0){Add-FailedGate 'TextSnapshotReadable'}
    $textRecords=@($records|Where-Object {$_.State -eq 'TEXT'})
    if($AllowedEncoding -and @($textRecords|Where-Object {$AllowedEncoding -notcontains $_.Encoding}).Count -gt 0){Add-FailedGate 'EncodingPolicy'}
    if($AllowedLineEnding -and @($textRecords|Where-Object {$AllowedLineEnding -notcontains $_.LineEndings.Style}).Count -gt 0){Add-FailedGate 'LineEndingPolicy'}
    if($DisallowMixedLineEndings -and @($textRecords|Where-Object {$_.LineEndings.Style -eq 'Mixed'}).Count -gt 0){Add-FailedGate 'MixedLineEndingsPolicy'}
    $result=[pscustomobject]@{SchemaVersion='1.0';Passed=($failedGates.Count -eq 0);FailedGates=@($failedGates);RootPath=$resolved;FileCount=@($records).Count;Files=@($records);Policy=[pscustomobject]@{AllowedEncoding=@($AllowedEncoding);AllowedLineEnding=@($AllowedLineEnding);DisallowMixedLineEndings=[bool]$DisallowMixedLineEndings};WritePerformed=$false;NetworkPerformed=$false;ProcessPerformed=$false;TransportPerformed=$false}
    if($AsJson){$result|ConvertTo-Json -Depth 8}else{$result}
    if(-not $result.Passed -and -not $NoThrow){throw "Text integrity diagnostic failed: $($result.FailedGates -join ', ')."}
} catch {
    if($NoThrow){$result=[pscustomobject]@{SchemaVersion='1.0';Passed=$false;FailedGates=@('InputPathValid');RootPath=$Path;FileCount=0;Files=@();WritePerformed=$false;NetworkPerformed=$false;ProcessPerformed=$false;TransportPerformed=$false;Error=$_.Exception.Message};if($AsJson){$result|ConvertTo-Json -Depth 8}else{$result}}else{throw}
}
