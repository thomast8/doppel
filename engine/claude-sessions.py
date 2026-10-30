"""Copy missing, same-account Claude Code history without sharing login storage."""
from __future__ import annotations

import hashlib
from contextlib import ExitStack
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid

UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", re.I)


class ImportFailure(Exception):
    pass


def open_regular(path: Path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ImportFailure('Session history contains a non-regular file.')
        return os.fdopen(descriptor, 'rb')
    except BaseException:
        os.close(descriptor)
        raise


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with open_regular(path) as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def checked(path: Path, root: Path) -> Path:
    relative = path.relative_to(root)
    current = root
    for part in relative.parts:
        current /= part
        if current.is_symlink():
            raise ImportFailure('Session history contains a symbolic link; nothing will be imported through it.')
    return path


def active_sessions() -> set[str]:
    # Keep command lines private: only session IDs are used, never logged.
    result = subprocess.run(['/bin/ps', '-axo', 'pid=,comm='], capture_output=True, text=True, check=True)
    active = set()
    for line in result.stdout.splitlines():
        fields = line.strip().split(maxsplit=1)
        if len(fields) != 2 or 'claude' not in Path(fields[1]).name.lower():
            continue
        command = subprocess.run(['/bin/ps', '-p', fields[0], '-o', 'command='], capture_output=True, text=True)
        active.update(re.findall(r'--(?:resume|session-id)(?:=|\s+)([0-9a-f-]{36})(?=\s|$)', command.stdout, re.I))
    return active


def plan_import(source_profile: Path, source_code: Path, target_profile: Path, target_code: Path,
                active: set[str] | None = None) -> dict:
    if not all(path.is_absolute() for path in (source_profile, source_code, target_profile, target_code)):
        raise ImportFailure('Profile and Code history directories must be absolute paths.')
    roots = [path.resolve() for path in (source_profile, source_code, target_profile, target_code)]
    source_profile, source_code, target_profile, target_code = roots
    if source_profile == target_profile:
        raise ImportFailure('This instance already uses the original Claude profile.')
    target_registry = target_profile / 'claude-code-sessions'
    scopes = [p for p in target_registry.glob('*/*')
              if UUID.fullmatch(p.parent.name) and UUID.fullmatch(p.name) and p.is_dir()]
    if len(scopes) != 1:
        raise ImportFailure('Sign into one account in this instance and open Code before importing history.')
    target_scope = checked(scopes[0], target_profile)
    scope = target_scope.relative_to(target_registry)
    source_scope = checked(source_profile / 'claude-code-sessions' / scope, source_profile)
    if not source_scope.is_dir():
        raise ImportFailure('The original Claude profile has no Code history for this account and workspace.')
    active = active_sessions() if active is None else active
    files = {}
    metadata = []
    result = dict(sessions=0, existing=0, kept_sessions=len(list(target_scope.glob('local_*.json'))),
                  missing_transcripts=0, missing_folders=0, scope=str(scope))

    def add(source: Path, target: Path, source_root: Path, target_root: Path) -> None:
        checked(source, source_root)
        checked(target, target_root)
        if not source.is_file():
            raise ImportFailure('A session history file is not a regular file.')
        if target.exists():
            if not target.is_file() or digest(source) != digest(target):
                raise ImportFailure('A matching history file already differs in this instance; no files were overwritten.')
            return
        stat = source.stat()
        files[target] = (source, (stat.st_size, stat.st_mtime_ns), source_root, target_root)

    for source in sorted(source_scope.glob('local_*.json')):
        checked(source, source_profile)
        if source.stat().st_size > 10 * 1024 * 1024:
            raise ImportFailure('A session record exceeds Claude\'s supported metadata size.')
        with open_regular(source) as stream:
            raw = stream.read(10 * 1024 * 1024 + 1)
        if len(raw) > 10 * 1024 * 1024:
            raise ImportFailure('A session record grew while it was being read.')
        record = json.loads(raw)
        if not isinstance(record, dict):
            raise ImportFailure('A session record is not an object.')
        session = record.get('sessionId', '')
        cli_session = record.get('cliSessionId', '')
        if not isinstance(session, str) or not UUID.fullmatch(session.removeprefix('local_')) or source.name != session + '.json':
            raise ImportFailure('A local session record has an invalid identity.')
        target = target_scope / source.name
        checked(target, target_profile)
        if target.exists():
            result['existing'] += 1
            continue
        if isinstance(cli_session, str) and cli_session in active:
            raise ImportFailure('An existing Code session is still running in the original profile. Finish it before importing.')
        matches = list((source_code / 'projects').glob(f'*/{cli_session}.jsonl')) if isinstance(cli_session, str) and UUID.fullmatch(cli_session) else []
        if len(matches) != 1:
            result['missing_transcripts'] += 1
            continue
        transcript = matches[0]
        if source_code != target_code:
            add(transcript, target_code / transcript.relative_to(source_code), source_code, target_code)
            for sidecar in [transcript.with_suffix(''), source_code / 'file-history' / cli_session]:
                checked(sidecar, source_code)
                if sidecar.exists():
                    for child in sidecar.rglob('*'):
                        checked(child, source_code)
                        if child.is_file():
                            add(child, target_code / child.relative_to(source_code), source_code, target_code)
        add(source, target, source_profile, target_profile)
        metadata.append(target)
        result['sessions'] += 1
        cwd = record.get('cwd')
        if not isinstance(cwd, str) or not Path(cwd).is_dir():
            result['missing_folders'] += 1
    result['files'] = files
    result['metadata'] = metadata
    return result


def apply_plan(plan: dict, audit_root: Path) -> dict:
    audit_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    summary = {key: value for key, value in plan.items() if key not in ('files', 'metadata')}
    created = []
    metadata = set(plan['metadata'])
    # Publish transcripts before their registry entries, and never replace an existing file.
    ordered = sorted(plan['files'], key=lambda path: (path in metadata, str(path)))
    with ExitStack() as temporary:
        staged = {}
        directories = {}
        for index, target in enumerate(ordered):
            source, fingerprint, source_root, target_root = plan['files'][target]
            checked(source, source_root)
            checked(target, target_root)
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            checked(target, target_root)
            if target.parent not in directories:
                directories[target.parent] = Path(temporary.enter_context(
                    tempfile.TemporaryDirectory(prefix='.doppel-import-', dir=target.parent)))
            stage = directories[target.parent] / str(index)
            with open_regular(source) as original, stage.open('xb') as output:
                shutil.copyfileobj(original, output)
            os.chmod(stage, 0o600)
            staged[target] = stage
        for source, fingerprint, source_root, _ in plan['files'].values():
            checked(source, source_root)
            current = source.stat()
            if (current.st_size, current.st_mtime_ns) != fingerprint:
                raise ImportFailure('Source history changed during the copy. Nothing was published; try again when idle.')
        try:
            for target in ordered:
                target_root = plan['files'][target][3]
                checked(target, target_root)
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                checked(target, target_root)
                os.link(staged[target], target)
                created.append(str(target))
        finally:
            manifest = audit_root / (str(uuid.uuid4()) + '.json')
            manifest.write_text(json.dumps(dict(summary=summary, created=created), indent=2))
            os.chmod(manifest, 0o600)
    return summary


def main() -> int:
    if len(sys.argv) not in (6, 7) or sys.argv[1] not in ('plan', 'apply'):
        raise ImportFailure('Expected plan/apply and the original and destination profile and Code directories.')
    plan = plan_import(*(Path(value) for value in sys.argv[2:6]))
    summary = {key: value for key, value in plan.items() if key not in ('files', 'metadata')}
    if sys.argv[1] == 'plan':
        print(json.dumps(summary))
    else:
        if len(sys.argv) != 7:
            raise ImportFailure('An import audit directory is required.')
        summary = apply_plan(plan, Path(sys.argv[6]))
        print(f"Imported {summary['sessions']} Code sessions. Kept this instance's {summary['kept_sessions']} existing sessions unchanged.")
        if summary['missing_transcripts']:
            print(f"Skipped {summary['missing_transcripts']} records without a unique local transcript.")
        if summary['missing_folders']:
            print(f"{summary['missing_folders']} imported sessions refer to missing working folders; restore those folders before continuing their work.")
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ImportFailure, OSError, ValueError) as error:
        print(f'Claude history import: {error}', file=sys.stderr)
        raise SystemExit(1)
