#!/usr/bin/env python3
"""Workbench archive and syntax preflight. Never execute registered source code."""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from xml.parsers import expat

ROOT = Path(__file__).resolve().parent.parent
NAMESPACE = uuid.UUID('80ade983-e156-4eec-b7f1-f972fa3e5b16')
LANGUAGES = ('powershell', 'xml', 'batch', 'cmd', 'lua', 'python', 'javascript',
             'typescript', 'csharp', 'json', 'yaml', 'html', 'css', 'bash', 'sql', 'toc')
MAX_BYTES = 4 * 1024 * 1024


def digest(data):
    return hashlib.sha256(data).hexdigest()


def adapter_id(language):
    return str(uuid.uuid5(NAMESPACE, 'parser:' + language))


def read_bytes(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_BYTES:
        raise ValueError('Expected a regular file of at most 4 MiB')
    with path.open('rb') as source:
        data = source.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise ValueError('Source exceeds 4 MiB')
    return data


def strict_json(text):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('Duplicate JSON key: ' + key)
            result[key] = value
        return result
    def invalid(value):
        raise ValueError('Non-finite JSON value: ' + value)
    return json.loads(text, object_pairs_hook=pairs, parse_constant=invalid)


def parse(language, data, suffix=''):
    result = {'parserComponentId': adapter_id(language), 'language': language,
              'state': 'UNAVAILABLE', 'sourceSha256': digest(data),
              'scope': 'syntax-only', 'sourceExecutionPerformed': False,
              'diagnostics': []}
    if language not in LANGUAGES:
        raise ValueError('Unknown language')
    try:
        if language == 'python':
            ast.parse(data, filename='<component>')
            result.update(state='PASSED', runtime=sys.version.split()[0])
        elif language == 'json':
            strict_json(data.decode('utf-8-sig'))
            result.update(state='PASSED', runtime=sys.version.split()[0])
        elif language == 'xml':
            parser = expat.ParserCreate()
            def reject(*unused):
                raise ValueError('DTD/entity declarations are outside the XML adapter policy')
            parser.StartDoctypeDeclHandler = reject
            parser.EntityDeclHandler = reject
            parser.ExternalEntityRefHandler = reject
            parser.Parse(data, True)
            result.update(state='PASSED', runtime=expat.EXPAT_VERSION,
                          scope='XML well-formedness; DTD/entities prohibited; not XSD validation')
        elif language in ('powershell', 'lua', 'javascript'):
            executable = shutil.which({'powershell': 'pwsh', 'lua': 'luac',
                                       'javascript': 'node'}[language])
            if language == 'powershell' and not executable:
                executable = shutil.which('powershell.exe')
            if not executable:
                result['diagnostics'] = ['Required parser runtime is not installed']
                return result
            with tempfile.TemporaryDirectory(prefix='workbench-parse-') as folder:
                ext = {'powershell': '.ps1', 'lua': '.lua', 'javascript': '.mjs' if suffix == '.mjs' else '.cjs'}[language]
                snapshot = Path(folder) / ('snapshot' + ext)
                snapshot.write_bytes(data)
                if language == 'powershell':
                    command = [executable, '-NoLogo', '-NoProfile', '-NonInteractive',
                               '-File', str(ROOT / 'scripts' / 'Get-PowerShellWorkbenchCodeAnalysis.ps1'),
                               '-Path', str(snapshot)]
                elif language == 'lua':
                    command = [executable, '-p', str(snapshot)]
                else:
                    command = [executable, '--check', str(snapshot)]
                # Inherited runtime startup injection is not part of source parsing.
                env = {k: v for k, v in os.environ.items()
                       if k.upper() not in ('NODE_OPTIONS', 'NODE_PATH', 'LUA_INIT', 'LUA_INIT_5_4', 'LUA_INIT_5_3')}
                completed = subprocess.run(command, capture_output=True, text=True,
                                           timeout=20, cwd=folder, env=env, shell=False)
                result['state'] = 'PASSED' if completed.returncode == 0 else 'FAILED'
                result['runtime'] = executable
                if language == 'powershell' and completed.returncode == 0:
                    analysis = strict_json(completed.stdout.lstrip('\ufeff'))
                    result['analysis'] = analysis
                    result['state'] = 'PASSED' if analysis['passed'] else 'FAILED'
                elif completed.returncode:
                    result['diagnostics'] = [(completed.stderr or completed.stdout)[-4000:]]
        else:
            result['diagnostics'] = ['Adapter contract reserved; no trusted syntax-only implementation bundled. Never run source to validate syntax.']
    except (ValueError, SyntaxError, UnicodeError, expat.ExpatError) as error:
        result.update(state='FAILED', diagnostics=[str(error)])
    except (OSError, subprocess.TimeoutExpired) as error:
        result.update(state='UNAVAILABLE', diagnostics=[str(error)])
    return result


def uuid_text(value):
    normalized = str(uuid.UUID(value))
    if value != normalized:
        raise ValueError('Component ID must be a canonical UUID')
    return normalized


def version_text(value):
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', value):
        raise ValueError('Version must be an explicit x.y.z release')
    return value


def location(archive, component_id, version):
    archive = Path(archive).resolve()
    target = archive / uuid_text(component_id) / version_text(version)
    if any(item.is_symlink() for item in (target.parent, target)):
        raise ValueError('Symlinked component directory')
    return target


@contextmanager
def locked(archive):
    archive = Path(archive).resolve()
    archive.mkdir(parents=True, exist_ok=True)
    lock = archive / '.registration-lock'
    try:
        lock.mkdir()
    except FileExistsError:
        raise ValueError('Archive is locked; inspect the owning registration before retrying')
    try:
        yield archive
    finally:
        lock.rmdir()


def register(archive, source, language, purpose, kind, contract, component_id=None,
             version='1.0.0', dependencies=None, derived_from=None):
    if not purpose.strip():
        raise ValueError('A component purpose is required')
    if language not in LANGUAGES or kind not in ('fragment', 'function', 'script', 'module', 'assembly'):
        raise ValueError('Unknown language or component kind')
    data = read_bytes(source)
    component_id = uuid_text(component_id or str(uuid.uuid4()))
    version_text(version)
    required = {'inputs', 'outputs', 'bindings', 'effects', 'unresolved', 'reviewed'}
    if not isinstance(contract, dict) or not required.issubset(contract):
        raise ValueError('Contract requires inputs, outputs, bindings, effects, unresolved and reviewed')
    if any(not isinstance(contract[key], list) for key in required - {'reviewed'}):
        raise ValueError('Contract collections must be arrays')
    if not isinstance(contract['reviewed'], bool):
        raise ValueError('Contract reviewed must be boolean')
    dependencies = dependencies or []
    derived_from = derived_from or []
    if not isinstance(dependencies, list) or not isinstance(derived_from, list):
        raise ValueError('Dependencies and lineage must be arrays of exact pins')
    for pin in dependencies + derived_from:
        location(archive, pin['componentId'], pin['version'])
        if not re.fullmatch('[0-9a-f]{64}', pin['sha256']):
            raise ValueError('Dependency pin requires SHA-256')
    metadata = {'schemaVersion': '1.0', 'componentId': component_id, 'version': version,
                'language': language, 'kind': kind, 'purpose': purpose,
                'entryPoint': 'code' + Path(source).suffix.lower(), 'sha256': digest(data),
                'contract': contract, 'dependencies': dependencies,
                'derivedFrom': derived_from,
                'provenance': {'source': str(Path(source).resolve()), 'sha256': digest(data),
                               'registeredAtUtc': datetime.now(timezone.utc).isoformat()},
                'validation': parse(language, data, Path(source).suffix.lower())}
    with locked(archive) as archive_path:
        target = location(archive_path, component_id, version)
        if target.exists():
            raise ValueError('Immutable component ID/version already exists')
        target.parent.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='.draft-', dir=archive_path) as temporary:
            stage = Path(temporary) / 'record'
            stage.mkdir()
            (stage / metadata['entryPoint']).write_bytes(data)
            (stage / 'component.json').write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
            stage.rename(target)
    return metadata


def load(archive, component_id, version):
    target = location(archive, component_id, version)
    metadata = strict_json(read_bytes(target / 'component.json').decode('utf-8'))
    if metadata['componentId'] != component_id or metadata['version'] != version or metadata['schemaVersion'] != '1.0':
        raise ValueError('Component identity mismatch')
    name = metadata['entryPoint']
    if not isinstance(name, str) or not re.fullmatch(r'code(?:\.[a-z0-9]+)?', name):
        raise ValueError('Component entry point must be a contained code snapshot')
    data = read_bytes(target / name)
    if digest(data) != metadata['sha256']:
        raise ValueError('Component content hash mismatch')
    return metadata, data


def gate(archive, component_id, version, source=None):
    visited, active, checks, failures = set(), set(), [], []
    def visit(cid, ver, expected=None):
        key = (cid, ver)
        if key in active:
            raise ValueError('Cyclic component dependencies')
        metadata, data = load(archive, cid, ver)
        if expected is not None and metadata['sha256'] != expected:
            raise ValueError('Dependency pin mismatch')
        if key in visited:
            return
        active.add(key)
        contract = metadata['contract']
        if not contract['reviewed'] or contract['unresolved']:
            failures.append({'componentId': cid, 'gate': 'ContractReviewedAndResolved'})
        check = parse(metadata['language'], data, Path(metadata['entryPoint']).suffix)
        checks.append({'componentId': cid, 'version': ver, **check})
        if check['state'] != 'PASSED':
            failures.append({'componentId': cid, 'gate': 'ParserAvailableAndPassed'})
        for pin in metadata['dependencies']:
            visit(pin['componentId'], pin['version'], pin['sha256'])
        active.remove(key)
        visited.add(key)
    visit(component_id, version)
    metadata, data = load(archive, component_id, version)
    if source is not None and read_bytes(source) != data:
        failures.append({'componentId': component_id, 'gate': 'ExecutionSourceMatchesSnapshot'})
    return {'schemaVersion': '1.0', 'passed': not failures, 'componentId': component_id,
            'version': version, 'sha256': metadata['sha256'], 'checks': checks,
            'failedGates': failures, 'sourceExecutionPerformed': False,
            'executionAuthorized': False, 'scope': 'registered bytes, declared dependency pins, syntax and declared contract review; not behavioral proof'}


def search(archive, query):
    archive = Path(archive).resolve()
    results = []
    if not archive.exists():
        return results
    for item in archive.glob('*/*/component.json'):
        metadata, unused = load(archive, item.parent.parent.name, item.parent.name)
        score = sum(word in (metadata['purpose'] + ' ' + metadata['language']).lower()
                    for word in query.lower().split())
        if score:
            results.append({'componentId': metadata['componentId'], 'version': metadata['version'],
                            'purpose': metadata['purpose'], 'score': score,
                            'parserStateAtRegistration': metadata['validation']['state']})
    return sorted(results, key=lambda row: (-row['score'], row['componentId'], row['version']))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    syntax = sub.add_parser('parse')
    syntax.add_argument('--source', required=True)
    syntax.add_argument('--language', choices=LANGUAGES, required=True)
    find = sub.add_parser('search')
    find.add_argument('--archive', required=True)
    find.add_argument('--query', required=True)
    new = sub.add_parser('register')
    for flag in ('archive', 'source', 'language', 'purpose', 'kind', 'contract'):
        new.add_argument('--' + flag, required=True)
    new.add_argument('--component-id')
    new.add_argument('--version', default='1.0.0')
    new.add_argument('--dependencies')
    new.add_argument('--derived-from')
    check = sub.add_parser('gate')
    for flag in ('archive', 'component-id', 'version', 'source'):
        check.add_argument('--' + flag, required=True)
    args = parser.parse_args()
    try:
        if args.command == 'parse':
            result = parse(args.language, read_bytes(args.source), Path(args.source).suffix.lower())
        elif args.command == 'search':
            result = search(args.archive, args.query)
        elif args.command == 'gate':
            result = gate(args.archive, args.component_id, args.version, args.source)
        else:
            read_json = lambda path: strict_json(read_bytes(path).decode('utf-8-sig')) if path else None
            result = register(args.archive, args.source, args.language, args.purpose, args.kind,
                              read_json(args.contract), args.component_id, args.version,
                              read_json(args.dependencies), read_json(args.derived_from))
        print(json.dumps(result, indent=2))
        if isinstance(result, dict) and (result.get('passed') is False or result.get('state') in ('FAILED', 'UNAVAILABLE')):
            return 2
        return 0
    except (ValueError, KeyError, TypeError, OSError, RecursionError) as error:
        print(json.dumps({'passed': False, 'error': str(error), 'sourceExecutionPerformed': False}))
        return 2


if __name__ == '__main__':
    sys.exit(main())
