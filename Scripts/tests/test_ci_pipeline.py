"""Negative controls for artifact reuse, complete coverage, and publication gates."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import struct
import plistlib
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'Scripts/ci' / file)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


release = module('release_candidate', 'release-candidate.py')
shards = module('ui_shards', 'ui-shards.py')
products = module('test_products', 'test-products.py')


class PublicationGateTests(unittest.TestCase):
    def setUp(self):
        self.run = dict(id=1, head_sha='candidate', head_branch='master', event='push',
                        status='completed', conclusion='success', run_number=7, run_attempt=1)
        self.jobs = lambda run: [dict(name='Build', conclusion='success')]

    def check(self, runs=None, jobs=None):
        return release.successful_gate(runs or [self.run], jobs or self.jobs, 'candidate', ['Build'])

    def test_success_requires_trusted_exact_commit_and_job(self):
        self.assertEqual(self.check(), 1)
        for change in [dict(head_sha='old'), dict(head_branch='dev'), dict(event='pull_request'),
                       dict(status='in_progress'), dict(conclusion='failure')]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.check([dict(self.run, **change)])
        with self.assertRaises(ValueError):
            self.check(jobs=lambda run: [])
        with self.assertRaises(ValueError):
            self.check(jobs=lambda run: [dict(name='Build', conclusion='skipped')])

    def test_new_failed_run_or_attempt_overrides_old_success(self):
        for newer in [dict(self.run, id=2, run_number=8, conclusion='failure'),
                      dict(self.run, run_attempt=2, conclusion='failure')]:
            with self.assertRaises(ValueError):
                self.check([self.run, newer])

    def test_superseded_candidate_fails_before_gates(self):
        with patch.object(release, 'command', return_value='old'), patch.object(
                release, 'api', return_value={'object': {'sha': 'new'}}):
            with self.assertRaises(ValueError):
                release.gates()

    def test_prepared_artifact_rejects_metadata_run_and_byte_changes(self):
        with tempfile.TemporaryDirectory() as temp:
            archive = Path(temp) / 'app.zip'
            archive.write_bytes(b'candidate')
            identity = dict(commit='exact', tree='source', version='0.8.1', build='31', xcode='26.3')
            saved = dict(identity=identity, run='12', attempt='1', sha256=release.digest(archive))
            release.validate_prepared(saved, identity, 12, archive, 1)
            for key in identity:
                changed = dict(identity, **{key: 'different'})
                with self.assertRaises(ValueError):
                    release.validate_prepared(saved, changed, 12, archive, 1)
            with self.assertRaises(ValueError):
                release.validate_prepared(saved, identity, 13, archive, 1)
            archive.write_bytes(b'tampered')
            with self.assertRaises(ValueError):
                release.validate_prepared(saved, identity, 12, archive, 1)

    def test_no_prepare_artifact_uses_explicit_cold_fallback(self):
        with patch.object(release, 'checkout_identity', return_value={'commit': 'sha'}), patch.object(
                release, 'api', return_value={'workflow_runs': []}), patch.object(release.subprocess, 'run') as run:
            release.restore()
            run.assert_not_called()


class CompleteCoverageTests(unittest.TestCase):
    def setUp(self):
        self.original = Path.cwd()
        os.chdir(ROOT)
        self.addCleanup(os.chdir, self.original)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.plan = shards.plan()
        self.env = patch.dict(os.environ, GITHUB_RUN_ID='42', GITHUB_RUN_ATTEMPT='1')
        self.env.start()
        self.addCleanup(self.env.stop)
        self.sha = patch.object(shards.subprocess, 'check_output', return_value='candidate')
        self.sha.start()
        self.addCleanup(self.sha.stop)
        for phase, tests in self.plan.items():
            (self.root / f'{phase}.json').write_text(json.dumps(dict(
                commit='candidate', run='42', attempt='1', exit=0, tests=[[t, 'Passed'] for t in tests])))
        captures = self.root / 'captures'
        captures.mkdir()
        for size in shards.SIZES:
            for appearance in ['light', 'dark']:
                for route in shards.ROUTES:
                    header = b'\x89PNG\r\n\x1a\n' + b'\0' * 8 + struct.pack('>II', *map(int, size.split('x')))
                    (captures / f'{size}-{appearance}-{route}.png').write_bytes(header)

    def verify(self):
        shards.verify(self.root, self.plan)

    def test_partition_is_complete_without_duplicate_functional_tests(self):
        tests = [test for phase, selected in self.plan.items() if not phase.startswith('visual-') for test in selected]
        self.assertEqual(len(tests), len(set(tests)))
        self.assertEqual(set(tests) | {shards.VISUAL}, set(shards.inventory()))
        self.verify()

    def test_missing_failed_skipped_stale_or_duplicate_test_rejected(self):
        path = self.root / 'smoke.json'
        original = json.loads(path.read_text())
        variants = [dict(original, commit='old'), dict(original, attempt='2'), dict(original, exit=65),
                    dict(original, tests=original['tests'][1:]),
                    dict(original, tests=original['tests'] + [original['tests'][0]])]
        for status in ['Failed', 'Skipped']:
            changed = copy.deepcopy(original)
            changed['tests'][0][1] = status
            variants.append(changed)
        for variant in variants:
            path.write_text(json.dumps(variant))
            with self.assertRaises(ValueError):
                self.verify()
        path.unlink()
        with self.assertRaises(ValueError):
            self.verify()

    def test_missing_or_wrong_sized_capture_fails(self):
        path = next((self.root / 'captures').glob('*.png'))
        original = path.read_bytes()
        path.write_bytes(original[:16] + struct.pack('>II', 20, 30))
        with self.assertRaises(ValueError):
            self.verify()
        path.unlink()
        with self.assertRaises(ValueError):
            self.verify()

    def test_nested_test_sources_are_included(self):
        nested = self.root / 'LokalBotUITests/Navigation/NestedTests.swift'
        nested.parent.mkdir(parents=True)
        nested.write_text('final class NestedTests: XCTestCase {\n    func testNewRoute() {}\n}\n')
        self.assertEqual(shards.inventory(self.root), ['NestedTests/testNewRoute'])

    def test_test_result_parser_reads_leaf_statuses(self):
        tree = {'testNodes': [{'children': [{'nodeType': 'Test Case', 'nodeIdentifier': 'Suite/testOne()',
                                          'result': 'Passed'}]}]}
        self.assertEqual(list(shards.test_results(tree)), [('Suite/testOne', 'Passed')])


class TestArtifactTests(unittest.TestCase):
    def test_identity_ignores_only_runner_location_and_job(self):
        identity = dict(root='/producer', job='build', commit='sha', xcode='26.3', lock='hash',
                        architecture='arm64', signing='NO', run='42', attempt='1')
        with patch.object(products.stamp, 'identity', return_value=dict(identity)):
            actual = products.identity()
        self.assertEqual(set(actual), set(identity) - {'root', 'job'})

    def test_tar_round_trip_preserves_executables_and_rejects_stale_or_tampered_products(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            producer, consumer = root / 'producer', root / 'consumer'
            source = producer / '.build/dd/Build/Products'
            source.mkdir(parents=True)
            binary = source / 'Debug/Runner.app/Contents/MacOS/Runner'
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b'compiled executable')
            binary.chmod(0o755)
            (source / 'Fixture.xctestrun').write_bytes(plistlib.dumps({'path': str(binary)}))
            original = Path.cwd()
            identity = dict(commit='sha', run='42', attempt='1', xcode='26.3')
            try:
                os.chdir(producer)
                with patch.object(products, 'identity', return_value=identity):
                    products.transfer('pack', 'unit')
                import shutil
                shutil.copytree(producer / '.build/transfer', consumer / '.build/transfer')
                os.chdir(consumer)
                with patch.object(products, 'identity', return_value=dict(identity, attempt='2')):
                    with self.assertRaises(ValueError):
                        products.transfer('unpack', 'unit')
                self.assertFalse((consumer / '.build/dd').exists())
                with patch.object(products, 'identity', return_value=identity):
                    products.transfer('unpack', 'unit')
                restored = consumer / '.build/dd/Build/Products'
                self.assertTrue(os.access(restored / binary.relative_to(source), os.X_OK))
                self.assertEqual(plistlib.loads((restored / 'Fixture.xctestrun').read_bytes())['path'],
                                 '__TESTROOT__/Debug/Runner.app/Contents/MacOS/Runner')
                (consumer / '.build/transfer/unit.tar').write_bytes(b'tampered')
                with patch.object(products, 'identity', return_value=identity):
                    with self.assertRaises(ValueError):
                        products.transfer('unpack', 'unit')
            finally:
                os.chdir(original)


if __name__ == '__main__':
    unittest.main()
