$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$resolver = Join-Path $root 'scripts\Resolve-PowerShellWorkbenchReadOnlyToolChain.ps1'
$executor = Join-Path $root 'scripts\Invoke-PowerShellWorkbenchReadOnlyTool.ps1'
$adapter = Join-Path $root 'scripts\Invoke-PowerShellWorkbenchOllamaChat.ps1'
$proposalGenerator = Join-Path $root 'scripts\New-PowerShellWorkbenchReadOnlyToolProposal.ps1'
$approvalGenerator = Join-Path $root 'scripts\New-PowerShellWorkbenchReadOnlyToolApproval.ps1'
$referenceTime = [datetimeoffset]'2026-09-06T12:05:00Z'
$utf8 = New-Object Text.UTF8Encoding($false)

function Assert-True { param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message} }
function Assert-GatesExactly { param($Result,[string[]]$Expected,[string]$Message) $actual=@($Result.FailedGates);if(($actual -join '|') -cne ($Expected -join '|')){throw "$Message Expected [$($Expected -join ', ')], got [$($actual -join ', ')]."} }
function Get-Sha256 { param([string]$LiteralPath) (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash.ToLowerInvariant() }
function Write-Json { param([string]$LiteralPath,$Value) [IO.File]::WriteAllText($LiteralPath,($Value|ConvertTo-Json -Depth 10),$utf8) }
function New-Proposal {
    param([string]$LiteralPath,[string]$TargetPath,[string]$CreatedAt,[int64]$OffsetBytes,[int64]$MaximumBytes)
    if(-not $PSBoundParameters.ContainsKey('CreatedAt')){$CreatedAt='2026-09-06T12:00:00Z'}
    if(-not $PSBoundParameters.ContainsKey('OffsetBytes')){$OffsetBytes=2}
    if(-not $PSBoundParameters.ContainsKey('MaximumBytes')){$MaximumBytes=5}
    $value=[ordered]@{schemaVersion='1.0';proposalId='proposal-fixture';createdAt=$CreatedAt;source=[ordered]@{kind='ollama-tool-call';metadataSha256=('a'*64);responseSha256=('b'*64);toolCallIndex=0};tool=[ordered]@{name='read_file_slice';arguments=[ordered]@{path=$TargetPath;offsetBytes=$OffsetBytes;maximumBytes=$MaximumBytes}}}
    Write-Json -LiteralPath $LiteralPath -Value $value
    Get-Sha256 -LiteralPath $LiteralPath
}
function New-Approval {
    param([string]$LiteralPath,[string]$ProposalSha256,[string]$AllowedRoot,[string]$TargetPath,[string]$CreatedAt,[string]$ExpiresAt)
    if(-not $PSBoundParameters.ContainsKey('CreatedAt')){$CreatedAt='2026-09-06T12:01:00Z'}
    if(-not $PSBoundParameters.ContainsKey('ExpiresAt')){$ExpiresAt='2026-09-06T12:15:00Z'}
    $target=(Get-Item -LiteralPath $TargetPath)
    $value=[ordered]@{schemaVersion='1.0';approvalId='approval-fixture';createdAt=$CreatedAt;expiresAt=$ExpiresAt;decision='Approved';proposalSha256=$ProposalSha256;allowedRoot=$AllowedRoot;target=[ordered]@{path=$TargetPath;sha256=(Get-Sha256 -LiteralPath $TargetPath);bytes=$target.Length}}
    Write-Json -LiteralPath $LiteralPath -Value $value
    Get-Sha256 -LiteralPath $LiteralPath
}
function Resolve-Chain {
    param([string]$ProposalPath,[string]$ProposalSha256,[string]$ApprovalPath,[string]$ApprovalSha256,[string]$AllowedRoot,[datetimeoffset]$At=[datetimeoffset]'2026-09-06T12:05:00Z',[string]$ObservationPath,[string]$ObservationSha256,[string]$AllowedEvidenceRoot)
    $parameters=@{ProposalPath=$ProposalPath;ExpectedProposalSha256=$ProposalSha256;ApprovalPath=$ApprovalPath;ExpectedApprovalSha256=$ApprovalSha256;AllowedRoot=$AllowedRoot;ReferenceTimeUtc=$At;NoThrow=$true}
    if($ObservationPath){$parameters.ObservationPath=$ObservationPath}
    if($ObservationSha256){$parameters.ExpectedObservationSha256=$ObservationSha256}
    if($AllowedEvidenceRoot){$parameters.AllowedEvidenceRoot=$AllowedEvidenceRoot}
    & $resolver @parameters
}

foreach($path in @($resolver,$executor,$proposalGenerator,$approvalGenerator)){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    Assert-True ($errors.Count -eq 0) "$path has parser errors."
    $commands=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()}|Where-Object{$_})
    foreach($forbidden in @('Start-Process','Invoke-Expression','Invoke-RestMethod','Invoke-WebRequest','Set-Clipboard','git','gh')){Assert-True ($commands -notcontains $forbidden) "$path contains forbidden command $forbidden."}
}

$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('pwb-read-tool-'+[guid]::NewGuid().ToString('N'))
try{
    $allowedRoot=Join-Path $tempRoot 'allowed';$evidenceRoot=Join-Path $tempRoot 'evidence';$outputDirectory=Join-Path $evidenceRoot 'run'
    New-Item -ItemType Directory -Path $allowedRoot,$evidenceRoot,$outputDirectory | Out-Null
    $targetPath=Join-Path $allowedRoot 'fixture.txt';[IO.File]::WriteAllText($targetPath,'0123456789abcdef',$utf8)
    $modelDigest='f'*64
    $responseFixturePath=Join-Path $tempRoot 'tool-response.json'
    $responseFixture=[ordered]@{model='fixture-model';created_at='2026-09-06T12:00:00Z';message=[ordered]@{role='assistant';content='';tool_calls=@([ordered]@{type='function';function=[ordered]@{index=0;name='read_file_slice';arguments=[ordered]@{path=$targetPath;offsetBytes=2;maximumBytes=5}}})};done=$true;total_duration=123;prompt_eval_count=4;eval_count=2}
    Write-Json -LiteralPath $responseFixturePath -Value $responseFixture
    $capture=& $adapter -Prompt 'Propose one bounded file slice.' -ModelId fixture-model -ModelDigest $modelDigest -OutputDirectory (Join-Path $tempRoot 'capture') -FixtureResponsePath $responseFixturePath -EnableReadFileSliceProposal -Execute
    $metadataSha=Get-Sha256 -LiteralPath $capture.MetadataPath
    $proposalPath=Join-Path $evidenceRoot 'proposal.json'
    $proposalPreview=& $proposalGenerator -MetadataPath $capture.MetadataPath -ExpectedMetadataSha256 $metadataSha -ExpectedResponseSha256 $capture.artifacts.responseSha256 -ExpectedModelId fixture-model -ExpectedModelDigest $modelDigest -CreatedAt ([datetimeoffset]'2026-09-06T12:00:00Z') -AllowedEvidenceRoot $evidenceRoot -OutputPath $proposalPath -AcceptUnverifiedModelDigest -AllowFixtureEvidence
    $proposalPreviewAgain=& $proposalGenerator -MetadataPath $capture.MetadataPath -ExpectedMetadataSha256 $metadataSha -ExpectedResponseSha256 $capture.artifacts.responseSha256 -ExpectedModelId fixture-model -ExpectedModelDigest $modelDigest -CreatedAt ([datetimeoffset]'2026-09-06T12:00:00Z') -AllowedEvidenceRoot $evidenceRoot -OutputPath $proposalPath -AcceptUnverifiedModelDigest -AllowFixtureEvidence
    Assert-True ($proposalPreview.State -eq 'PREVIEW' -and -not $proposalPreview.WritePerformed -and -not(Test-Path -LiteralPath $proposalPath)) 'Proposal preview performed a write.'
    Assert-True ($proposalPreview.ProposalSha256 -eq $proposalPreviewAgain.ProposalSha256 -and $proposalPreview.ProposalJson -ceq $proposalPreviewAgain.ProposalJson) 'Proposal generation was not deterministic.'
    $proposalWritten=& $proposalGenerator -MetadataPath $capture.MetadataPath -ExpectedMetadataSha256 $metadataSha -ExpectedResponseSha256 $capture.artifacts.responseSha256 -ExpectedModelId fixture-model -ExpectedModelDigest $modelDigest -CreatedAt ([datetimeoffset]'2026-09-06T12:00:00Z') -AllowedEvidenceRoot $evidenceRoot -OutputPath $proposalPath -AcceptUnverifiedModelDigest -AllowFixtureEvidence -Write
    $proposalSha=$proposalWritten.ProposalSha256
    $approvalPath=Join-Path $evidenceRoot 'approval.json'
    $approvalPreview=& $approvalGenerator -ProposalPath $proposalPath -ExpectedProposalSha256 $proposalSha -AllowedRoot $allowedRoot -CreatedAt ([datetimeoffset]'2026-09-06T12:01:00Z') -ExpiresAt ([datetimeoffset]'2026-09-06T12:15:00Z') -AllowedEvidenceRoot $evidenceRoot -OutputPath $approvalPath
    Assert-True ($approvalPreview.State -eq 'PREVIEW' -and -not $approvalPreview.WritePerformed -and -not(Test-Path -LiteralPath $approvalPath)) 'Approval preview performed a write.'
    $approvalWritten=& $approvalGenerator -ProposalPath $proposalPath -ExpectedProposalSha256 $proposalSha -AllowedRoot $allowedRoot -CreatedAt ([datetimeoffset]'2026-09-06T12:01:00Z') -ExpiresAt ([datetimeoffset]'2026-09-06T12:15:00Z') -AllowedEvidenceRoot $evidenceRoot -OutputPath $approvalPath -Approve
    $approvalSha=$approvalWritten.ApprovalSha256

    $ready=Resolve-Chain -ProposalPath $proposalPath -ProposalSha256 $proposalSha -ApprovalPath $approvalPath -ApprovalSha256 $approvalSha -AllowedRoot $allowedRoot
    Assert-True ($ready.State -eq 'READY' -and $ready.Eligible -and -not $ready.ExecutionPerformed) "Valid evidence did not produce READY: $($ready|ConvertTo-Json -Compress)."
    Assert-GatesExactly -Result $ready -Expected @() -Message 'READY gates changed.'

    $preview=& $executor -ProposalPath $proposalPath -ExpectedProposalSha256 $proposalSha -ApprovalPath $approvalPath -ExpectedApprovalSha256 $approvalSha -AllowedRoot $allowedRoot -ReferenceTimeUtc $referenceTime -AllowedEvidenceRoot $evidenceRoot -OutputDirectory $outputDirectory -NoThrow
    Assert-True ($preview.State -eq 'READY' -and -not $preview.ExecutionPerformed -and @(Get-ChildItem -LiteralPath $outputDirectory).Count -eq 0) 'Preview performed an effect.'
    $outsidePreview=& $executor -ProposalPath $proposalPath -ExpectedProposalSha256 $proposalSha -ApprovalPath $approvalPath -ExpectedApprovalSha256 $approvalSha -AllowedRoot $allowedRoot -ReferenceTimeUtc $referenceTime -AllowedEvidenceRoot $evidenceRoot -OutputDirectory (Join-Path $tempRoot 'outside-evidence') -NoThrow
    Assert-GatesExactly -Result $outsidePreview -Expected @('OutputDirectoryWithinEvidenceRoot') -Message 'Evidence-root escape gate changed.'

    $executed=& $executor -ProposalPath $proposalPath -ExpectedProposalSha256 $proposalSha -ApprovalPath $approvalPath -ExpectedApprovalSha256 $approvalSha -AllowedRoot $allowedRoot -ReferenceTimeUtc $referenceTime -AllowedEvidenceRoot $evidenceRoot -OutputDirectory $outputDirectory -Execute
    Assert-True ($executed.State -eq 'SUCCEEDED' -and $executed.ExecutionPerformed -and -not $executed.TargetWritePerformed -and -not $executed.NetworkPerformed -and -not $executed.ProcessPerformed -and -not $executed.TransportPerformed) 'Execution effects were reported incorrectly.'
    Assert-True ([Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($executed.SlicePath)) -ceq '23456') 'Bounded slice content changed.'
    Assert-True ((Get-Sha256 -LiteralPath $targetPath) -eq (Get-Content -LiteralPath $approvalPath -Raw|ConvertFrom-Json).target.sha256) 'The approved target was mutated.'
    $observed=Resolve-Chain -ProposalPath $proposalPath -ProposalSha256 $proposalSha -ApprovalPath $approvalPath -ApprovalSha256 $approvalSha -AllowedRoot $allowedRoot -ObservationPath $executed.ObservationPath -ObservationSha256 $executed.ObservationSha256 -AllowedEvidenceRoot $evidenceRoot
    Assert-True ($observed.State -eq 'SUCCEEDED' -and $observed.Eligible -and -not $observed.ExecutionPerformed) 'Valid observation did not resolve to SUCCEEDED.'
    $missingEvidenceRoot=Resolve-Chain -ProposalPath $proposalPath -ProposalSha256 $proposalSha -ApprovalPath $approvalPath -ApprovalSha256 $approvalSha -AllowedRoot $allowedRoot -ObservationPath $executed.ObservationPath -ObservationSha256 $executed.ObservationSha256
    Assert-True ($missingEvidenceRoot.State -eq 'UNKNOWN') 'Missing evidence root was not UNKNOWN.';Assert-GatesExactly -Result $missingEvidenceRoot -Expected @('AllowedEvidenceRootPresent') -Message 'Missing evidence-root gate changed.'

    $missing=Resolve-Chain -ProposalPath $proposalPath -ProposalSha256 $proposalSha -ApprovalPath (Join-Path $tempRoot 'missing.json') -ApprovalSha256 ('c'*64) -AllowedRoot $allowedRoot
    Assert-True ($missing.State -eq 'UNKNOWN') 'Missing approval was not UNKNOWN.';Assert-GatesExactly -Result $missing -Expected @('ApprovalPresent') -Message 'Missing approval gate changed.'
    $wrongHash=Resolve-Chain -ProposalPath $proposalPath -ProposalSha256 ('d'*64) -ApprovalPath $approvalPath -ApprovalSha256 $approvalSha -AllowedRoot $allowedRoot
    Assert-True ($wrongHash.State -eq 'CONFLICT') 'Proposal hash drift was not CONFLICT.';Assert-GatesExactly -Result $wrongHash -Expected @('ProposalSha256') -Message 'Proposal hash gate changed.'

    $staleProposalPath=Join-Path $tempRoot 'stale-proposal.json';$staleProposalSha=New-Proposal -LiteralPath $staleProposalPath -TargetPath $targetPath -CreatedAt '2026-09-06T10:00:00Z'
    $staleApprovalPath=Join-Path $tempRoot 'stale-approval.json';$staleApprovalSha=New-Approval -LiteralPath $staleApprovalPath -ProposalSha256 $staleProposalSha -AllowedRoot $allowedRoot -TargetPath $targetPath
    $stale=Resolve-Chain -ProposalPath $staleProposalPath -ProposalSha256 $staleProposalSha -ApprovalPath $staleApprovalPath -ApprovalSha256 $staleApprovalSha -AllowedRoot $allowedRoot
    Assert-True ($stale.State -eq 'UNKNOWN') 'Stale proposal was not UNKNOWN.';Assert-GatesExactly -Result $stale -Expected @('ProposalFreshness') -Message 'Stale proposal gate changed.'

    $expiredApprovalPath=Join-Path $tempRoot 'expired-approval.json';$expiredApprovalSha=New-Approval -LiteralPath $expiredApprovalPath -ProposalSha256 $proposalSha -AllowedRoot $allowedRoot -TargetPath $targetPath -ExpiresAt '2026-09-06T12:04:00Z'
    $expired=Resolve-Chain -ProposalPath $proposalPath -ProposalSha256 $proposalSha -ApprovalPath $expiredApprovalPath -ApprovalSha256 $expiredApprovalSha -AllowedRoot $allowedRoot
    Assert-True ($expired.State -eq 'UNKNOWN') 'Expired approval was not UNKNOWN.';Assert-GatesExactly -Result $expired -Expected @('ApprovalFreshness') -Message 'Expired approval gate changed.'

    $outsidePath=Join-Path $tempRoot 'outside.txt';[IO.File]::WriteAllText($outsidePath,'outside',$utf8)
    $outsideProposalPath=Join-Path $tempRoot 'outside-proposal.json';$outsideProposalSha=New-Proposal -LiteralPath $outsideProposalPath -TargetPath $outsidePath
    $outsideApprovalPath=Join-Path $tempRoot 'outside-approval.json';$outsideApprovalSha=New-Approval -LiteralPath $outsideApprovalPath -ProposalSha256 $outsideProposalSha -AllowedRoot $allowedRoot -TargetPath $outsidePath
    $outside=Resolve-Chain -ProposalPath $outsideProposalPath -ProposalSha256 $outsideProposalSha -ApprovalPath $outsideApprovalPath -ApprovalSha256 $outsideApprovalSha -AllowedRoot $allowedRoot
    Assert-True ($outside.State -eq 'CONFLICT') 'Root escape was not CONFLICT.';Assert-GatesExactly -Result $outside -Expected @('TargetWithinRoot') -Message 'Root escape gate changed.'

    $bindingApprovalPath=Join-Path $tempRoot 'binding-approval.json';$bindingApprovalSha=New-Approval -LiteralPath $bindingApprovalPath -ProposalSha256 ('e'*64) -AllowedRoot $allowedRoot -TargetPath $targetPath
    $binding=Resolve-Chain -ProposalPath $proposalPath -ProposalSha256 $proposalSha -ApprovalPath $bindingApprovalPath -ApprovalSha256 $bindingApprovalSha -AllowedRoot $allowedRoot
    Assert-True ($binding.State -eq 'CONFLICT') 'Approval binding mismatch was not CONFLICT.';Assert-GatesExactly -Result $binding -Expected @('ApprovalProposalBinding') -Message 'Approval binding gate changed.'

    $driftTargetPath=Join-Path $allowedRoot 'drift.txt';[IO.File]::WriteAllText($driftTargetPath,'before',$utf8)
    $driftProposalPath=Join-Path $tempRoot 'drift-proposal.json';$driftProposalSha=New-Proposal -LiteralPath $driftProposalPath -TargetPath $driftTargetPath
    $driftApprovalPath=Join-Path $tempRoot 'drift-approval.json';$driftApprovalSha=New-Approval -LiteralPath $driftApprovalPath -ProposalSha256 $driftProposalSha -AllowedRoot $allowedRoot -TargetPath $driftTargetPath
    [IO.File]::WriteAllText($driftTargetPath,'after',$utf8)
    $drift=Resolve-Chain -ProposalPath $driftProposalPath -ProposalSha256 $driftProposalSha -ApprovalPath $driftApprovalPath -ApprovalSha256 $driftApprovalSha -AllowedRoot $allowedRoot
    Assert-True ($drift.State -eq 'CONFLICT') 'Target drift was not CONFLICT.';Assert-GatesExactly -Result $drift -Expected @('TargetEvidence') -Message 'Target drift gate changed.'

    $reparseTarget=Join-Path $tempRoot 'reparse-target';New-Item -ItemType Directory -Path $reparseTarget | Out-Null
    $reparseFile=Join-Path $reparseTarget 'linked.txt';[IO.File]::WriteAllText($reparseFile,'linked',$utf8)
    $reparseLink=Join-Path $allowedRoot 'linked';New-Item -ItemType Junction -Path $reparseLink -Target $reparseTarget | Out-Null
    $linkedPath=Join-Path $reparseLink 'linked.txt';$reparseProposalPath=Join-Path $tempRoot 'reparse-proposal.json';$reparseProposalSha=New-Proposal -LiteralPath $reparseProposalPath -TargetPath $linkedPath
    $reparseApprovalPath=Join-Path $tempRoot 'reparse-approval.json';$reparseApprovalSha=New-Approval -LiteralPath $reparseApprovalPath -ProposalSha256 $reparseProposalSha -AllowedRoot $allowedRoot -TargetPath $linkedPath
    $reparse=Resolve-Chain -ProposalPath $reparseProposalPath -ProposalSha256 $reparseProposalSha -ApprovalPath $reparseApprovalPath -ApprovalSha256 $reparseApprovalSha -AllowedRoot $allowedRoot
    Assert-True ($reparse.State -eq 'CONFLICT') 'Reparse target was not CONFLICT.';Assert-GatesExactly -Result $reparse -Expected @('TargetReparseSafe') -Message 'Reparse target gate changed.'

    $tamperedObservation=Get-Content -LiteralPath $executed.ObservationPath -Raw|ConvertFrom-Json
    $tamperedObservation.effects.transportPerformed=$true
    $tamperedPath=Join-Path $tempRoot 'tampered-observation.json';Write-Json -LiteralPath $tamperedPath -Value $tamperedObservation;$tamperedSha=Get-Sha256 -LiteralPath $tamperedPath
    $tampered=Resolve-Chain -ProposalPath $proposalPath -ProposalSha256 $proposalSha -ApprovalPath $approvalPath -ApprovalSha256 $approvalSha -AllowedRoot $allowedRoot -ObservationPath $tamperedPath -ObservationSha256 $tamperedSha -AllowedEvidenceRoot $tempRoot
    Assert-True ($tampered.State -eq 'CONFLICT') 'Forbidden observation effect was not CONFLICT.';Assert-GatesExactly -Result $tampered -Expected @('ObservationEffects') -Message 'Observation effects gate changed.'
    $outsideSlicePath=Join-Path $tempRoot 'outside-slice.bin';[IO.File]::WriteAllBytes($outsideSlicePath,[byte[]](1,2,3))
    $outsideSliceObservation=Get-Content -LiteralPath $executed.ObservationPath -Raw|ConvertFrom-Json
    $outsideSliceObservation.slice.path=$outsideSlicePath;$outsideSliceObservation.slice.bytes=3;$outsideSliceObservation.slice.sha256=Get-Sha256 -LiteralPath $outsideSlicePath
    $outsideSliceObservationPath=Join-Path $evidenceRoot 'outside-slice-observation.json';Write-Json -LiteralPath $outsideSliceObservationPath -Value $outsideSliceObservation;$outsideSliceObservationSha=Get-Sha256 -LiteralPath $outsideSliceObservationPath
    $outsideSlice=Resolve-Chain -ProposalPath $proposalPath -ProposalSha256 $proposalSha -ApprovalPath $approvalPath -ApprovalSha256 $approvalSha -AllowedRoot $allowedRoot -ObservationPath $outsideSliceObservationPath -ObservationSha256 $outsideSliceObservationSha -AllowedEvidenceRoot $evidenceRoot
    Assert-True ($outsideSlice.State -eq 'CONFLICT') 'Outside slice was not CONFLICT.';Assert-GatesExactly -Result $outsideSlice -Expected @('SliceWithinEvidenceRoot') -Message 'Outside-slice gate changed.'
}finally{
    if(Test-Path -LiteralPath $tempRoot){Remove-Item -LiteralPath $tempRoot -Recurse -Force}
}
'PowerShell Workbench read-only tool contracts passed.'
