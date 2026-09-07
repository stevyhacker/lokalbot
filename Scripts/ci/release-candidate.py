#!/usr/bin/env python3
"""Fail-closed release gates and trusted, exact-commit archive preparation reuse."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

GATES = {
    'build.yml': ['xcodebuild (macOS)', 'xcodebuild test (macOS)'],
    'ui-tests.yml': ['XCUITest (macOS)'],
    'lint.yml': ['SwiftLint'],
    'xcodegen.yml': ['project.yml generates cleanly'],
}


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def api(path):
    return json.loads(command('gh', 'api', f"repos/{os.environ['GITHUB_REPOSITORY']}/{path}"))


def checkout_identity():
    info = plistlib.loads(Path('LokalBot/Info.plist').read_bytes())
    lock = Path('LokalBot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved')
    return dict(commit=command('git', 'rev-parse', 'HEAD'), tree=command('git', 'rev-parse', 'HEAD^{tree}'),
                xcode=command('xcodebuild', '-version'), architecture=command('uname', '-m'),
                version=info['CFBundleShortVersionString'], build=info['CFBundleVersion'],
                lock=hashlib.sha256(lock.read_bytes()).hexdigest(), repository=os.environ['GITHUB_REPOSITORY'])


def trusted_tip():
    sha = command('git', 'rev-parse', 'HEAD')
    if api('git/ref/heads/master')['object']['sha'] != sha:
        raise ValueError('Release candidate is not the current trusted master commit')
    return sha


def successful_gate(runs, jobs, sha, required):
    # The newest push run on this exact master SHA is authoritative. An older
    # successful attempt cannot hide a running or failed rerun.
    candidates = [run for run in runs if run['head_sha'] == sha and run['head_branch'] == 'master'
                  and run['event'] == 'push']
    if not candidates:
        raise ValueError('No trusted master push validation for this exact commit')
    run = max(candidates, key=lambda item: (item['run_number'], item.get('run_attempt', 1)))
    if run['status'] != 'completed' or run['conclusion'] != 'success':
        raise ValueError('Latest exact-commit validation is not successful')
    actual = jobs(run['id'])
    for name in required:
        matches = [job for job in actual if job['name'] == name]
        if len(matches) != 1 or matches[0]['conclusion'] != 'success':
            raise ValueError(f'Missing or unsuccessful release gate: {name}')
    return run['id']


def gates():
    sha = trusted_tip()
    for workflow, required in GATES.items():
        runs = api(f'actions/workflows/{workflow}/runs?head_sha={sha}&event=push&per_page=100')['workflow_runs']
        run_id = successful_gate(runs, lambda run: api(f'actions/runs/{run}/jobs?filter=latest&per_page=100')['jobs'], sha, required)
        print(f"Verified {workflow} run {run_id}: {', '.join(required)}")


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def validate_prepared(saved, current, run_id, archive):
    if saved['identity'] != current or saved['run'] != str(run_id) or saved['sha256'] != digest(archive):
        raise ValueError('Prepared app commit, metadata, toolchain, run or digest mismatch')


def prepare():
    trusted_tip()
    if os.environ['GITHUB_EVENT_NAME'] != 'workflow_dispatch' or os.environ['GITHUB_REF'] != 'refs/heads/master':
        raise ValueError('Archive preparation requires an explicit dispatch on master')
    subprocess.run(['python3', 'Scripts/release-preflight.py', '--candidate', '--version', os.environ['CANDIDATE_VERSION']], check=True)


def pack():
    archive = Path('build/prepared/app.zip')
    archive.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['ditto', '-c', '-k', '--keepParent', 'build/export/LokalBot.app', str(archive)], check=True)
    saved = dict(identity=checkout_identity(), run=os.environ['GITHUB_RUN_ID'],
                 attempt=os.environ['GITHUB_RUN_ATTEMPT'], sha256=digest(archive))
    archive.with_suffix('.json').write_text(json.dumps(saved, indent=2))


def restore():
    identity = checkout_identity()
    sha = identity['commit']
    runs = api(f'actions/workflows/release.yml/runs?head_sha={sha}&event=workflow_dispatch&per_page=100')['workflow_runs']
    for run in sorted(runs, key=lambda item: item['run_number'], reverse=True):
        if (run['head_sha'], run['head_branch'], run['event'], run['status'], run['conclusion']) != (
                sha, 'master', 'workflow_dispatch', 'completed', 'success'):
            continue
        name = 'prepared-app-' + sha
        artifacts = api(f"actions/runs/{run['id']}/artifacts?per_page=100")['artifacts']
        matches = [a for a in artifacts if a['name'] == name and not a['expired']]
        if not matches:
            continue
        if len(matches) != 1:
            raise ValueError('Ambiguous prepared archive')
        subprocess.run(['gh', 'run', 'download', str(run['id']), '--repo', os.environ['GITHUB_REPOSITORY'],
                        '--name', name, '--dir', 'build/prepared'], check=True)
        archive = Path('build/prepared/app.zip')
        validate_prepared(json.loads(archive.with_suffix('.json').read_text()), identity, run['id'], archive)
        subprocess.run(['ditto', '-x', '-k', str(archive), 'build/export'], check=True)
        with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
            stream.write('reused=true\n')
        print(f"Reusing verified prepared app from run {run['id']}")
        return
    print('No trusted exact-commit prepared app; use the cold archive path.')


if __name__ == '__main__':
    try:
        {'gates': gates, 'prepare': prepare, 'pack': pack, 'restore': restore}[sys.argv[1]]()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
