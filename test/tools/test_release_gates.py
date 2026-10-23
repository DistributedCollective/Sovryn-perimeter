"""Exercise campaign verdicts with deterministic tools, without running fuzzers."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
FORGE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
if os.environ.get('FOUNDRY_NO_MATCH_CONTRACT') or os.environ.get('FOUNDRY_PROFILE') != 'default':
    sys.exit('inherited contract filter or profile narrowed this campaign')
if '--list' in sys.argv:
    print(json.dumps({'test/invariant/Fixture.t.sol': {'Fixture':
        ['invariant_backing', 'testFuzz_conservation']}}))
    sys.exit(0)
case = os.environ['CAMPAIGN_CASE']
print('Ran 2 tests for test/invariant/Fixture.t.sol:Fixture')
print('[PASS] testFuzz_conservation(uint256) (runs: 20000, μ: 1, ~: 1)')
if case != 'missing-invariant':
    status = 'FAIL: assertion failed' if case == 'failed-zero-exit' else 'PASS'
    runs, calls = (2, 6) if case == 'short-foundry' else (2000, 400000)
    suffix = 'oops' if case == 'malformed-counts' else ''
    print(f'[{status}] invariant_backing() (runs: {runs}{suffix}, calls: {calls}, reverts: 0)')
failed = int(case == 'failed-zero-exit')
passed = 1 if failed or case == 'missing-invariant' else 2
print(f'Ran 1 test suite in 1s: {passed} tests passed, {failed} failed, 0 skipped ({passed+failed} total tests)')
if case == 'dirty-harness':
    pathlib.Path('test/echidna/EchidnaExitDelayQueue.sol').write_text('// changed\n')
sys.exit(0)
'''
ECHIDNA = r'''#!/usr/bin/env python3
import os, sys
case = os.environ['CAMPAIGN_CASE']
reach = 'EchidnaExitDelayQueueReach' in sys.argv
names = ['echidna_backing', 'echidna_conservation']
if case == 'wrong-properties': names = ['echidna_unrelated_a', 'echidna_unrelated_b']
if case == 'duplicate-property': names = ['echidna_backing', 'echidna_backing']
for name in names: print(f'{name}: passing')
if reach:
    state = 'passing' if case == 'unreached' else 'failed!'
    print(f'echidna_levers_not_reached: {state}')
print('Total calls: ' + ('20' if case == 'short-echidna' else '500000oops' if case == 'malformed-counts' else '500000'))
sys.exit(2 if reach and case == 'reach-tool-error' else 1 if reach else 0)
'''


class ReleaseGateTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='perimeter-gate-test-')
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.root, self.output = base / 'source', base / 'output'
        (self.root / 'tools').mkdir(parents=True)
        (self.root / 'src').mkdir()
        (self.root / 'test/echidna').mkdir(parents=True)
        for name in ['release-gates.sh', 'verify-release-campaign.py']:
            if (REPO / 'tools' / name).exists():
                shutil.copyfile(REPO / 'tools' / name, self.root / 'tools' / name)
        (self.root / 'test/echidna/EchidnaExitDelayQueue.sol').write_text(
            'function echidna_backing() external view returns (bool) {}\n'
            'function echidna_conservation() external view returns (bool) {}\n'
        )
        (self.root / 'test/echidna/EchidnaExitDelayQueueReach.sol').write_text(
            'function echidna_levers_not_reached() external view returns (bool) {}\n'
        )
        self.env = os.environ.copy()
        self.env['TZ'] = 'UTC'
        binary = base / 'bin'
        binary.mkdir()
        for name, body in [('forge', FORGE), ('echidna', ECHIDNA)]:
            path = binary / name
            path.write_text(body)
            path.chmod(0o755)
        self.env['PATH'] = str(binary) + os.pathsep + self.env['PATH']
        for args in [
            ['init', '-q'], ['add', '.'],
            ['-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
             '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'Campaign fixture'],
        ]:
            subprocess.run(['git', *args], cwd=self.root, env=self.env, check=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def gate(self, phase, case='healthy'):
        self.env['CAMPAIGN_CASE'] = case
        result = subprocess.run(
            ['bash', 'tools/release-gates.sh', str(self.output), phase],
            cwd=self.root, env=self.env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        return result.returncode, result.stdout

    def assert_rejected(self, phase, case):
        status, log = self.gate(phase, case)
        self.assertNotEqual(status, 0, log)

    def test_complete_foundry_passes(self):
        status, log = self.gate('foundry')
        self.assertEqual(status, 0, log)

    def test_short_foundry_is_rejected(self):
        self.assert_rejected('foundry', 'short-foundry')

    def test_missing_invariant_is_rejected(self):
        self.assert_rejected('foundry', 'missing-invariant')

    def test_failed_foundry_with_zero_exit_is_rejected(self):
        self.assert_rejected('foundry', 'failed-zero-exit')

    def test_changed_harness_is_rejected(self):
        self.assert_rejected('foundry', 'dirty-harness')

    def test_inherited_contract_filter_is_cleared(self):
        self.env['FOUNDRY_NO_MATCH_CONTRACT'] = 'Fixture'
        status, log = self.gate('foundry')
        self.assertEqual(status, 0, log)

    def test_profile_is_pinned(self):
        self.env['FOUNDRY_PROFILE'] = 'narrow'
        status, log = self.gate('foundry')
        self.assertEqual(status, 0, log)

    def test_malformed_foundry_counts_are_rejected(self):
        self.assert_rejected('foundry', 'malformed-counts')

    def test_complete_echidna_passes(self):
        status, log = self.gate('echidna')
        self.assertEqual(status, 0, log)

    def test_wrong_property_names_are_rejected(self):
        self.assert_rejected('echidna', 'wrong-properties')

    def test_duplicate_property_is_rejected(self):
        self.assert_rejected('echidna', 'duplicate-property')

    def test_short_echidna_is_rejected(self):
        self.assert_rejected('echidna', 'short-echidna')

    def test_malformed_echidna_counts_are_rejected(self):
        self.assert_rejected('echidna', 'malformed-counts')

    def test_meaningful_reach_failure_passes(self):
        status, log = self.gate('reach')
        self.assertEqual(status, 0, log)

    def test_reach_tool_error_is_rejected(self):
        self.assert_rejected('reach', 'reach-tool-error')

    def test_unreached_levers_are_rejected(self):
        self.assert_rejected('reach', 'unreached')


if __name__ == '__main__':
    unittest.main()
