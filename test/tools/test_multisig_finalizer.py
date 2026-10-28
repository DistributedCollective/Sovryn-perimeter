"""Receipt-backed finalization controls using a read-only deterministic RPC."""

import copy
import hashlib
import importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[2]
PROXY, NEW, OLD, WALLET, VAULT = ['0x' + f'{n:040x}' for n in range(10, 15)]
OWNERS = ['0x' + f'{n:040x}' for n in range(100, 107)]
ZERO = '0x' + '0' * 40
EXEC_TX, CREATE_TX = ['0x' + f'{n:064x}' for n in [50, 51]]
PRE_HASH, EXEC_HASH, CREATE_HASH = ['0x' + f'{n:064x}' for n in [99, 100, 98]]
SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'


def cast(*args):
    return subprocess.check_output(['cast', *args], text=True).strip()


def word(n):
    return f'{n:064x}'


def address_word(a):
    return '0' * 24 + a[2:]


def addresses(items):
    return '0x' + word(32) + word(len(items)) + ''.join(address_word(a) for a in items)


def wallet_transaction(executed, destination=PROXY, data=None):
    data = data or cast('calldata', 'upgradeTo(address)', NEW)
    raw = data[2:]
    return ('0x' + address_word(destination) + word(0) + word(128) + word(executed)
            + word(len(raw) // 2) + raw.ljust(((len(raw) + 63) // 64) * 64, '0'))


class MultisigFinalizerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='perimeter-ms-finalize-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.original = json.loads((REPO / 'deployments/30/ExitFeeController.json').read_text())
        self.original.update(chainId=31337, proxyAddress=PROXY, implAddress=OLD,
                             implBytecodeHash=cast('keccak', '0x6001'))
        self.record = self.root / 'ExitFeeController.json'
        self.record.write_text(json.dumps(self.original))
        self.before = self.record.read_bytes()
        self.runtime = '0x6000' + '0' * (32 * 5 * 2)
        self.hydrated = '0x6000' + address_word(NEW) * 5
        refs = {'1': [{'start': 2 + 32 * n, 'length': 32} for n in range(5)]}
        artifact = {
            'abi': self.original['abi'], 'storageLayout': self.original['storageLayout'],
            'bytecode': {'object': '0x6002'},
            'deployedBytecode': {'object': self.runtime, 'immutableReferences': refs},
            'metadata': {'compiler': {'version': '0.8.20+commit.a1b79de6'},
                         'settings': {'optimizer': {'enabled': True, 'runs': 200},
                                      'evmVersion': 'paris', 'metadata': {'bytecodeHash': 'ipfs'}}},
        }
        self.artifact = self.root / 'candidate.json'
        self.artifact.write_text(json.dumps(artifact))
        self.profile = self.root / 'profile.json'
        self.profile.write_text(json.dumps({
            'source_pin': 'a' * 40,
            'contracts': [{'contract': 'ExitFeeController',
                           'artifact_sha256': hashlib.sha256(self.artifact.read_bytes()).hexdigest(),
                           'compiler': '0.8.20+commit.a1b79de6',
                           'optimizer': {'enabled': True, 'runs': 200}, 'evm_version': 'paris',
                           'runtime_template_keccak256': cast('keccak', self.runtime),
                           'immutable_references': refs}],
            'native_compiler_replay': {'checks': [{'contract': 'ExitFeeController',
                                                  'creation_exact_match': True,
                                                  'runtime_exact_match': True}]},
        }))
        self.manifest = self.root / 'manifest.json'
        self.spec = {
            'schemaVersion': 1, 'contractName': 'ExitFeeController', 'chainId': 31337,
            'proxyAddress': PROXY, 'implementationAddress': NEW,
            'implementationDeploymentTx': CREATE_TX,
            'wallet': {'address': WALLET, 'transactionId': 7, 'executionTx': EXEC_TX,
                       'required': 3, 'owners': OWNERS,
                       'runtimeCodeHash': cast('keccak', '0x6003')},
            'proxyRuntimeCodeHash': cast('keccak', '0x6004'),
            'previousRecord': {'path': str(self.record),
                               'sha256': hashlib.sha256(self.before).hexdigest()},
            'artifact': {'path': str(self.artifact),
                         'sha256': hashlib.sha256(self.artifact.read_bytes()).hexdigest()},
            'profile': {'path': str(self.profile),
                        'sha256': hashlib.sha256(self.profile.read_bytes()).hexdigest()},
            'expectedState': {'owner': WALLET, 'pendingOwner': ZERO, 'admin': WALLET,
                              'feeReceiver': VAULT, 'exitFeeEnabled': True},
        }
        self.mode = 'healthy'
        self.methods = []
        context = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                context.methods.append(request['method'])
                try:
                    result = context.rpc(request['method'], request['params'])
                    response = {'jsonrpc': '2.0', 'id': request['id'], 'result': result}
                except Exception as error:
                    response = {'jsonrpc': '2.0', 'id': request['id'],
                                'error': {'code': -32000, 'message': str(error)}}
                payload = json.dumps(response).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def rpc(self, method, params):
        if method == 'eth_chainId':
            return hex(1 if self.mode == 'wrong-chain' else 31337)
        if method == 'eth_getBlockByNumber':
            n = 100 if params[0] == 'latest' else int(params[0], 16)
            return {'number': hex(n), 'hash': {98: CREATE_HASH, 99: PRE_HASH, 100: EXEC_HASH}[n],
                    'parentHash': PRE_HASH if n == 100 else CREATE_HASH, 'timestamp': hex(1800000000 + n)}
        if method == 'eth_getTransactionByHash':
            creation = params[0] == CREATE_TX
            return {'hash': params[0], 'to': None if creation else WALLET,
                    'from': OWNERS[2], 'value': '0x1' if self.mode == 'wrong-value' and not creation else '0x0', 'chainId': hex(31337),
                    'blockHash': CREATE_HASH if creation else EXEC_HASH,
                    'blockNumber': '0x62' if creation else '0x64', 'transactionIndex': '0x0',
                    'input': ('0x6006' if self.mode == 'wrong-creation-data' else '0x6002') if creation else cast('calldata', 'confirmTransaction(uint256)',
                                                         '8' if self.mode == 'wrong-id' else '7')}
        if method == 'eth_getTransactionReceipt':
            creation = params[0] == CREATE_TX
            logs = [] if creation else [
                {'address': WALLET, 'topics': [cast('keccak', 'Confirmation(address,uint256)'),
                                             '0x' + address_word(OWNERS[2]), '0x' + word(7)], 'data': '0x'},
                {'address': PROXY, 'topics': [cast('keccak', 'Upgraded(address)'), '0x' + address_word(NEW)], 'data': '0x'},
                {'address': WALLET, 'topics': [cast('keccak', 'Execution(uint256)'), '0x' + word(7)], 'data': '0x'},
            ]
            if not creation and self.mode == 'no-execution':
                logs = logs[:2]
            if not creation and self.mode == 'wrong-proxy-log':
                logs[1]['address'] = VAULT
            if not creation and self.mode == 'wrong-log-order':
                logs.reverse()
            block_hash = CREATE_HASH if creation else EXEC_HASH
            for i, log in enumerate(logs):
                log.update(transactionHash=params[0], blockHash=block_hash,
                           blockNumber='0x62' if creation else '0x64', transactionIndex='0x0',
                           logIndex=hex(i), removed=False)
            return {'transactionHash': params[0], 'status': '0x0' if self.mode == 'failed-receipt' and not creation else '0x1',
                    'blockHash': block_hash, 'blockNumber': '0x62' if creation else '0x64',
                    'transactionIndex': '0x0', 'from': OWNERS[2],
                    'to': None if creation else WALLET, 'contractAddress': NEW if creation else None, 'logs': logs}
        if method == 'eth_getCode':
            return {WALLET: '0x6003', PROXY: '0x6004', OLD: '0x6001',
                    NEW: '0x6005' if self.mode == 'wrong-code' else self.hydrated}[params[0]]
        if method == 'eth_getStorageAt':
            if params[1] == SLOT:
                value = OLD if params[2] == '0x63' or self.mode == 'wrong-slot' else NEW
                return '0x' + address_word(value)
            return '0x' + word(1 if self.mode == 'changed-storage' and params[2] != '0x63' else 0)
        if method == 'eth_call':
            target, data = params[0]['to'], params[0]['data']
            pre = params[1] == '0x63'
            if target == WALLET:
                values = {
                    cast('calldata', 'getOwners()'): addresses(OWNERS),
                    cast('calldata', 'required()'): '0x' + word(2 if self.mode == 'wrong-threshold' else 3),
                    cast('calldata', 'getConfirmations(uint256)', '7'): addresses(OWNERS[:2] if pre or self.mode == 'insufficient-confirmations' else OWNERS[:3]),
                    cast('calldata', 'getConfirmationCount(uint256)', '7'): '0x' + word(2 if pre or self.mode == 'insufficient-confirmations' else 3),
                    cast('calldata', 'isConfirmed(uint256)', '7'): '0x' + word(not pre and self.mode != 'insufficient-confirmations'),
                    cast('calldata', 'transactions(uint256)', '7'): wallet_transaction(not pre, VAULT if self.mode == 'wrong-target' else PROXY,
                        cast('calldata', 'upgradeTo(address)', OLD) if self.mode == 'wrong-data' else None),
                }
                return values[data]
            for signature, key in [('owner()', 'owner'), ('pendingOwner()', 'pendingOwner'),
                                   ('admin()', 'admin'), ('feeReceiver()', 'feeReceiver')]:
                if data == cast('calldata', signature):
                    value = OLD if self.mode == 'wrong-owner' and key == 'owner' else self.spec['expectedState'][key]
                    return '0x' + address_word(value)
            if data == cast('calldata', 'exitFeeEnabled()'):
                return '0x' + word(1)
            if data in [cast('calldata', 'securityPerimeterEnabled()'), cast('calldata', 'globalDelaySeconds()')]:
                return '0x' + word(0)
            if data[:10] in [cast('sig', 'subProductKeys(bytes32)'), cast('sig', 'actorKeys(bytes32)')]:
                return addresses([])
            if data[:10] == cast('sig', 'surfacePolicy(bytes32)'):
                return '0x' + word(1) + word(11 if self.mode == 'changed-policy' and not pre else 10)
            raise AssertionError('unexpected read call')
        raise AssertionError('unexpected RPC method')

    def run_finalizer(self):
        self.manifest.write_text(json.dumps(self.spec))
        env = os.environ.copy()
        env.update(TZ='UTC', PYTHONDONTWRITEBYTECODE='1')
        return subprocess.run([
            'bash', str(REPO / 'tools/finalize-deployment.sh'), '--multisig-upgrade',
            '--manifest', str(self.manifest), '--manifest-sha256', hashlib.sha256(self.manifest.read_bytes()).hexdigest(),
            '--rpc-url', f'http://127.0.0.1:{self.server.server_port}',
        ], text=True, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def test_real_receipt_shape_supported_without_forge_broadcast(self):
        result = self.run_finalizer()
        self.assertEqual(result.returncode, 0, result.stdout)
        saved = json.loads(self.record.read_text())
        self.assertEqual(saved['deploymentTx'], EXEC_TX)
        self.assertEqual(saved['implementationDeploymentTx'], CREATE_TX)
        self.assertEqual(saved['finalization']['mode'], 'multisig-upgrade')
        self.assertEqual(saved['finalization']['rollback']['recordSha256'], hashlib.sha256(self.before).hexdigest())
        self.assertTrue(all(method in ['eth_chainId', 'eth_getBlockByNumber', 'eth_getTransactionByHash',
                                      'eth_getTransactionReceipt', 'eth_getCode', 'eth_getStorageAt', 'eth_call']
                            for method in self.methods))

    def test_invalid_chain_receipt_target_data_slot_and_state_do_not_change_record(self):
        for mode in ['wrong-chain', 'failed-receipt', 'no-execution', 'wrong-proxy-log',
                     'wrong-id', 'wrong-target', 'wrong-data', 'wrong-slot', 'wrong-code',
                     'wrong-owner', 'changed-storage', 'insufficient-confirmations']:
            with self.subTest(mode=mode):
                self.mode = mode
                result = self.run_finalizer()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.record.read_bytes(), self.before)

    def test_value_creation_policy_threshold_and_log_order_controls(self):
        for mode in ['wrong-value', 'wrong-creation-data', 'changed-policy', 'wrong-threshold', 'wrong-log-order']:
            with self.subTest(mode=mode):
                self.mode = mode
                result = self.run_finalizer()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.record.read_bytes(), self.before)

    def test_conflicting_existing_record_is_preserved(self):
        self.record.write_text(self.record.read_text() + '\n')
        conflicting = self.record.read_bytes()
        result = self.run_finalizer()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('conflicting deployment record', result.stdout)
        self.assertEqual(self.record.read_bytes(), conflicting)

    def test_matching_replay_is_idempotent(self):
        result = self.run_finalizer()
        self.assertEqual(result.returncode, 0, result.stdout)
        saved = self.record.read_bytes()
        result = self.run_finalizer()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.record.read_bytes(), saved)

    def test_tampered_proof_replay_is_refused(self):
        result = self.run_finalizer()
        self.assertEqual(result.returncode, 0, result.stdout)
        saved = json.loads(self.record.read_text())
        saved['finalization']['executionReceipt']['status'] = '0x0'
        self.record.write_text(json.dumps(saved))
        tampered = self.record.read_bytes()
        result = self.run_finalizer()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('conflicting previously finalized receipt/provenance', result.stdout)
        self.assertEqual(self.record.read_bytes(), tampered)

    def test_tampered_timestamp_replay_is_refused_without_changing_record(self):
        result = self.run_finalizer()
        self.assertEqual(result.returncode, 0, result.stdout)
        saved = json.loads(self.record.read_text())
        self.assertEqual(saved['timestamp'], 1800000100000)
        self.assertEqual(saved['timestampUnit'], 'milliseconds')
        for changes in [{'timestamp': 0}, {'timestampUnit': 'seconds'},
                        {'timestamp': 0, 'timestampUnit': 'seconds'}]:
            with self.subTest(changes=changes):
                corrupted = copy.deepcopy(saved)
                corrupted.update(changes)
                self.record.write_text(json.dumps(corrupted))
                tampered = self.record.read_bytes()
                result = self.run_finalizer()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn('conflicting previously finalized record', result.stdout)
                self.assertEqual(self.record.read_bytes(), tampered)


class VerificationProfileTest(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('finalizer', REPO / 'tools/finalize-multisig-upgrade.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.temp = tempfile.TemporaryDirectory(prefix='perimeter-profile-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'src').mkdir()
        self.source = self.root / 'src/ExitFeeController.sol'
        self.source.write_text('pragma solidity 0.8.20; contract ExitFeeController {}')
        self.artifact = self.root / 'artifact.json'
        metadata = {'settings': {'compilationTarget': {'src/ExitFeeController.sol': 'ExitFeeController'},
                                 'optimizer': {'enabled': True, 'runs': 200}, 'evmVersion': 'paris',
                                 'metadata': {'bytecodeHash': 'ipfs'}, 'remappings': []},
                    'sources': {'src/ExitFeeController.sol': {'keccak256': cast('keccak', '0x' + self.source.read_bytes().hex())}}}
        self.artifact.write_text(json.dumps({'metadata': metadata}))
        self.record = self.root / 'record.json'
        self.record.write_text(json.dumps({'finalization': {'mode': 'multisig-upgrade', 'profile': {
            'artifactSha256': hashlib.sha256(self.artifact.read_bytes()).hexdigest()}}}))
        self.cfg = {'optimizer': True, 'optimizer_runs': 200, 'evm_version': 'paris',
                    'via_ir': False, 'bytecode_hash': 'ipfs', 'remappings': [],
                    'cbor_metadata': True, 'use_literal_content': False, 'optimizer_details': None}

    def check(self):
        real = self.module.subprocess.check_output

        def execute(args, **kwargs):
            return json.dumps(self.cfg).encode() if args[:2] == ['forge', 'config'] else real(args, **kwargs)

        old = Path.cwd()
        try:
            os.chdir(self.root)
            with patch.object(self.module.subprocess, 'check_output', execute):
                self.module.check_verification_profile(self.record, self.artifact)
        finally:
            os.chdir(old)

    def test_matching_source_and_settings_pass(self):
        self.check()

    def test_changed_source_is_refused(self):
        self.source.write_text('contract Different {}')
        with self.assertRaisesRegex(ValueError, 'verification source changed'):
            self.check()

    def test_changed_optimizer_is_refused(self):
        self.cfg['optimizer_runs'] = 999
        with self.assertRaisesRegex(ValueError, 'compiler profile mismatch'):
            self.check()

    def test_changed_artifact_is_refused(self):
        self.artifact.write_text(self.artifact.read_text() + '\n')
        with self.assertRaisesRegex(ValueError, 'artifact hash mismatch'):
            self.check()

    def test_changed_metadata_and_optimizer_detail_flags_are_refused(self):
        original = copy.deepcopy(self.cfg)
        for key, value in [('cbor_metadata', False), ('use_literal_content', True),
                           ('optimizer_details', {'peephole': False})]:
            with self.subTest(key=key):
                self.cfg = {**original, key: value}
                with self.assertRaisesRegex(ValueError, 'compiler profile mismatch'):
                    self.check()


if __name__ == '__main__':
    unittest.main()
