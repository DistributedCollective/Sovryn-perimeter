#!/usr/bin/env python3
"""Finalize a controller upgrade from real chain receipts; never submit transactions."""

import argparse
import datetime
import fcntl
from functools import lru_cache
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.request


IMPL_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'
SURFACES = [
    'PERIMETER_SURFACE_LENDING_LENDER_WITHDRAW',
    'PERIMETER_SURFACE_LENDING_BORROWER_WITHDRAW',
    'PERIMETER_SURFACE_ZERO_WITHDRAW_COLL',
    'PERIMETER_SURFACE_ZERO_CLAIM_SURPLUS',
    'PERIMETER_SURFACE_AMM_REMOVE_LIQUIDITY',
]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def hex_value(value, size=None):
    require(isinstance(value, str) and re.fullmatch(r'0x[0-9a-fA-F]*', value), 'invalid hex value')
    require(len(value) % 2 == 0, 'odd hex length')
    value = value.lower()
    require(size is None or len(value) == 2 + size * 2, 'unexpected hex length')
    return value


def address(value):
    value = hex_value(value, 20)
    require(int(value, 16) != 0, 'zero address')
    return value


def quantity(value):
    require(isinstance(value, str) and re.fullmatch(r'0x[0-9a-fA-F]+', value), 'invalid RPC quantity')
    return int(value, 16)


@lru_cache(maxsize=None)
def cast(*args):
    return subprocess.check_output(['cast', *args], text=True).strip().lower()


def word(value):
    return f'{value:064x}'


def address_word(value):
    return '0' * 24 + value[2:]


def decode_address(raw):
    raw = hex_value(raw, 32)
    require(raw[2:26] == '0' * 24, 'noncanonical address word')
    return '0x' + raw[-40:]


def decode_uint(raw):
    return int(hex_value(raw, 32), 16)


def decode_addresses(raw):
    raw = bytes.fromhex(hex_value(raw)[2:])
    require(len(raw) >= 64 and int.from_bytes(raw[:32], 'big') == 32, 'invalid address array')
    count = int.from_bytes(raw[32:64], 'big')
    require(len(raw) == 64 + 32 * count, 'invalid address array length')
    result = [decode_address('0x' + raw[64 + 32 * i:96 + 32 * i].hex()) for i in range(count)]
    require(len(result) == len(set(result)), 'duplicate address array entry')
    return result


def decode_transaction(raw):
    raw = bytes.fromhex(hex_value(raw)[2:])
    require(len(raw) >= 160 and int.from_bytes(raw[64:96], 'big') == 128, 'invalid wallet transaction ABI')
    size = int.from_bytes(raw[128:160], 'big')
    require(len(raw) == 160 + ((size + 31) // 32) * 32, 'invalid wallet transaction length')
    require(not any(raw[160 + size:]), 'nonzero wallet transaction padding')
    executed = int.from_bytes(raw[96:128], 'big')
    require(executed in (0, 1), 'invalid executed boolean')
    return {'destination': decode_address('0x' + raw[:32].hex()),
            'value': int.from_bytes(raw[32:64], 'big'),
            'data': '0x' + raw[160:160 + size].hex(), 'executed': bool(executed)}


class Rpc:
    METHODS = {'eth_chainId', 'eth_getTransactionByHash', 'eth_getTransactionReceipt',
               'eth_getBlockByNumber', 'eth_getCode', 'eth_getStorageAt', 'eth_call'}

    def __init__(self, url):
        require(url.startswith(('http://', 'https://')), 'HTTP(S) RPC URL required')
        self.url, self.sequence = url, 0

    def read(self, method, params=None):
        require(method in self.METHODS, 'non-read-only RPC method refused')
        self.sequence += 1
        payload = {'jsonrpc': '2.0', 'id': self.sequence, 'method': method, 'params': params or []}
        request = urllib.request.Request(self.url, json.dumps(payload).encode(),
                                         {'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=30) as response:
            data = json.load(response)
        require(data.get('id') == self.sequence and 'error' not in data and 'result' in data,
                f'RPC read failed: {method}')
        return data['result']

    def call(self, target, signature, args, block):
        data = cast('calldata', signature, *map(str, args))
        return hex_value(self.read('eth_call', [{'to': target, 'data': data}, block]))


def checked_file(spec, base):
    require(set(spec) == {'path', 'sha256'}, 'unknown/missing file binding fields')
    path = Path(spec['path'])
    path = path if path.is_absolute() else base / path
    require(not path.is_symlink(), 'symlinked input/record refused')
    raw = path.read_bytes()
    require(sha(raw) == spec['sha256'], f'file hash mismatch: {path.name}')
    return path, raw, json.loads(raw)


def block(rpc, number):
    result = rpc.read('eth_getBlockByNumber', [number, False])
    require(isinstance(result, dict), 'missing block')
    hex_value(result['hash'], 32)
    if number != 'latest':
        require(quantity(result['number']) == quantity(number), 'wrong block number')
    return result


def receipt(rpc, tx_hash):
    result = rpc.read('eth_getTransactionReceipt', [tx_hash])
    require(isinstance(result, dict), 'missing transaction receipt')
    require(result['transactionHash'].lower() == tx_hash and quantity(result['status']) == 1,
            'unsuccessful/wrong receipt')
    header = block(rpc, result['blockNumber'])
    require(header['hash'].lower() == result['blockHash'].lower(), 'noncanonical receipt block')
    tx = rpc.read('eth_getTransactionByHash', [tx_hash])
    require(isinstance(tx, dict) and tx['hash'].lower() == tx_hash, 'missing/wrong transaction')
    for key in ['blockHash', 'blockNumber', 'transactionIndex', 'from', 'to']:
        require(tx[key] == result[key], f'transaction/receipt mismatch: {key}')
    for log in result['logs']:
        require(not log.get('removed', False), 'removed receipt log')
        for key, expected in [('transactionHash', tx_hash), ('blockHash', result['blockHash']),
                              ('blockNumber', result['blockNumber']), ('transactionIndex', result['transactionIndex'])]:
            require(log.get(key) == expected, f'log/receipt mismatch: {key}')
    indices = [quantity(log['logIndex']) for log in result['logs']]
    require(indices == sorted(set(indices)), 'unordered/duplicate receipt logs')
    return tx, result, header


def runtime(artifact, implementation):
    raw = bytearray.fromhex(hex_value(artifact['deployedBytecode']['object'])[2:])
    refs = artifact['deployedBytecode'].get('immutableReferences', {})
    locations = [item for group in refs.values() for item in group]
    require(len(locations) == 5, 'unexpected controller self immutable profile')
    used = set()
    for item in locations:
        start, length = item['start'], item['length']
        require(length == 32 and 0 <= start <= len(raw) - length, 'invalid immutable location')
        span = set(range(start, start + length))
        require(not used.intersection(span) and not any(raw[start:start + length]), 'invalid immutable template')
        used.update(span)
        raw[start:start + length] = bytes.fromhex(address_word(implementation))
    return '0x' + raw.hex()


def state(rpc, proxy, expected, tag):
    values = {}
    for key in ['owner', 'pendingOwner', 'admin', 'feeReceiver']:
        actual = decode_address(rpc.call(proxy, key + '()', [], tag))
        require(actual == expected[key].lower(), f'controller {key} mismatch')
        values[key] = actual
    enabled = decode_uint(rpc.call(proxy, 'exitFeeEnabled()', [], tag))
    require(enabled in (0, 1) and bool(enabled) == expected['exitFeeEnabled'], 'controller fee switch mismatch')
    values['exitFeeEnabled'] = bool(enabled)
    return values


def fee_policies(rpc, proxy, surfaces, tag):
    result = {}
    for surface in surfaces:
        result[surface] = {'surface': rpc.call(proxy, 'surfacePolicy(bytes32)', [surface], tag)}
        for getter, policy in [('subProductKeys', 'subProductPolicy'), ('actorKeys', 'actorPolicy')]:
            raw = rpc.call(proxy, getter + '(bytes32)', [surface], tag)
            keys = decode_addresses(raw)
            result[surface][getter] = {'keys': raw, 'policies': {
                key: rpc.call(proxy, policy + '(bytes32,address)', [surface, key], tag) for key in keys}}
    return result


def raw_slots(rpc, proxy, layout, tag):
    slots = set()
    for item in layout['storage']:
        if item['label'] != '__gap':
            size = int(layout['types'][item['type']]['numberOfBytes'])
            slots.update(range(int(item['slot']), int(item['slot']) + (size + 31) // 32))
    return {str(slot): hex_value(rpc.read('eth_getStorageAt', [proxy, hex(slot), tag]), 32)
            for slot in sorted(slots)}


def wallet_state(rpc, wallet, identifier, owners, required, tag):
    actual = decode_addresses(rpc.call(wallet, 'getOwners()', [], tag))
    require(set(actual) == set(owners), 'wallet owner set mismatch')
    require(decode_uint(rpc.call(wallet, 'required()', [], tag)) == required, 'wallet threshold mismatch')
    confirmations = decode_addresses(rpc.call(wallet, 'getConfirmations(uint256)', [identifier], tag))
    require(set(confirmations).issubset(owners), 'non-owner confirmation')
    require(decode_uint(rpc.call(wallet, 'getConfirmationCount(uint256)', [identifier], tag)) == len(confirmations),
            'wallet confirmation count mismatch')
    confirmed = decode_uint(rpc.call(wallet, 'isConfirmed(uint256)', [identifier], tag))
    require(confirmed in (0, 1) and bool(confirmed) == (len(confirmations) >= required), 'wallet confirmation state mismatch')
    return {'owners': actual, 'required': required, 'confirmations': confirmations,
            'transaction': decode_transaction(rpc.call(wallet, 'transactions(uint256)', [identifier], tag))}


def finalize(args):
    manifest_path = Path(args.manifest).resolve()
    raw = manifest_path.read_bytes()
    require(sha(raw) == args.manifest_sha256, 'manifest hash mismatch')
    spec = json.loads(raw)
    required_fields = {'schemaVersion', 'contractName', 'chainId', 'proxyAddress', 'implementationAddress',
                       'implementationDeploymentTx', 'wallet', 'proxyRuntimeCodeHash', 'previousRecord',
                       'artifact', 'profile', 'expectedState'}
    require(required_fields <= spec.keys() and spec.keys() <= required_fields | {'extraSurfaceIds'},
            'unknown/missing manifest fields')
    require(spec['schemaVersion'] == 1 and spec['contractName'] == 'ExitFeeController', 'unsupported manifest/contract')
    chain = spec['chainId']
    require(type(chain) is int and chain > 0, 'invalid expected chain')
    proxy, implementation = address(spec['proxyAddress']), address(spec['implementationAddress'])
    wallet_spec = spec['wallet']
    require(set(wallet_spec) == {'address', 'transactionId', 'executionTx', 'required', 'owners', 'runtimeCodeHash'},
            'unknown/missing wallet fields')
    require(set(spec['expectedState']) == {'owner', 'pendingOwner', 'admin', 'feeReceiver', 'exitFeeEnabled'},
            'unknown/missing expected state fields')
    require(set(spec['previousRecord']) == {'path', 'sha256'}, 'unknown/missing previous record fields')
    wallet, identifier = address(wallet_spec['address']), wallet_spec['transactionId']
    require(type(identifier) is int and 0 <= identifier < 2**256, 'invalid wallet transaction ID')
    owners = [address(a) for a in wallet_spec['owners']]
    require(wallet_spec['required'] == 3 and len(owners) == len(set(owners)) == 7, 'expected wallet must be 3 of 7')
    execution_hash, creation_hash = hex_value(wallet_spec['executionTx'], 32), hex_value(spec['implementationDeploymentTx'], 32)
    base = manifest_path.parent
    record_path = Path(spec['previousRecord']['path'])
    record_path = record_path if record_path.is_absolute() else base / record_path
    require(not record_path.is_symlink(), 'symlinked deployment record refused')
    current_raw = record_path.read_bytes()
    current = json.loads(current_raw)
    already = sha(current_raw) != spec['previousRecord']['sha256']
    if already:
        proof = current.get('finalization', {})
        require(proof.get('mode') == 'multisig-upgrade' and proof.get('manifestSha256') == args.manifest_sha256,
                'conflicting deployment record')
        previous_raw = proof['rollback']['originalJson'].encode()
    else:
        previous_raw = current_raw
    require(sha(previous_raw) == spec['previousRecord']['sha256'], 'rollback record hash mismatch')
    previous = json.loads(previous_raw)
    require(previous['contractName'] == spec['contractName'] and previous['chainId'] == chain
            and previous['proxyAddress'].lower() == proxy, 'previous record target/chain mismatch')
    old_impl = address(previous['implAddress'])
    require(old_impl != implementation, 'implementation did not change')
    artifact_path, artifact_raw, artifact = checked_file(spec['artifact'], base)
    _, profile_raw, profile = checked_file(spec['profile'], base)
    entries = [c for c in profile['contracts'] if c['contract'] == spec['contractName']]
    require(len(entries) == 1, 'ambiguous artifact profile')
    entry = entries[0]
    require(entry['artifact_sha256'] == sha(artifact_raw), 'artifact/profile hash mismatch')
    metadata = artifact['metadata']
    metadata = json.loads(metadata) if isinstance(metadata, str) else metadata
    require(metadata['compiler']['version'] == entry['compiler'] == '0.8.20+commit.a1b79de6', 'compiler profile mismatch')
    require(metadata['settings']['optimizer'] == entry['optimizer'] == {'enabled': True, 'runs': 200}
            and metadata['settings']['evmVersion'] == entry['evm_version'] == 'paris'
            and not metadata['settings'].get('viaIR', False)
            and metadata['settings']['metadata']['bytecodeHash'] == 'ipfs', 'artifact settings mismatch')
    require(entry['immutable_references'] == artifact['deployedBytecode']['immutableReferences'], 'immutable profile mismatch')
    require(entry['runtime_template_keccak256'] == cast('keccak', artifact['deployedBytecode']['object']), 'template hash mismatch')
    replay = [c for c in profile['native_compiler_replay']['checks'] if c['contract'] == spec['contractName']]
    require(len(replay) == 1 and replay[0]['creation_exact_match'] is True and replay[0]['runtime_exact_match'] is True,
            'reviewed profile lacks exact native compiler replay')
    require(re.fullmatch(r'[0-9a-f]{40}', profile['source_pin']), 'invalid profile source pin')
    require(isinstance(artifact['abi'], list) and isinstance(artifact['storageLayout']['storage'], list), 'missing ABI/layout')
    with tempfile.TemporaryDirectory(prefix='perimeter-layout-') as directory:
        old_path = Path(directory) / 'old.json'
        new_path = Path(directory) / 'candidate.json'
        old_path.write_bytes(previous_raw)
        new_path.write_bytes(artifact_raw)
        result = subprocess.run([sys.executable, str(Path(__file__).with_name('diff-storage-layouts.py')),
                                 str(old_path), str(new_path)], capture_output=True, text=True)
        require(result.returncode == 0, 'unsafe storage layout: ' + result.stdout + result.stderr)
    expected_runtime = runtime(artifact, implementation)
    rpc = Rpc(args.rpc_url)
    require(quantity(rpc.read('eth_chainId')) == chain, 'RPC chain mismatch')
    tx, execution, execution_block = receipt(rpc, execution_hash)
    deployment, creation, creation_block = receipt(rpc, creation_hash)
    for transaction in [tx, deployment]:
        if 'chainId' in transaction:
            require(quantity(transaction['chainId']) == chain, 'transaction chain mismatch')
    require((deployment.get('to') is None and address(creation['contractAddress']) == implementation
             and quantity(deployment['value']) == 0 and deployment['input'].lower() == artifact['bytecode']['object'].lower()),
            'wrong implementation creation transaction/profile')
    require(quantity(creation['blockNumber']) < quantity(execution['blockNumber']), 'implementation not deployed before upgrade')
    require(hex_value(rpc.read('eth_getCode', [implementation, creation['blockNumber']])) == expected_runtime,
            'implementation creation runtime/profile mismatch')
    pre_tag = hex(quantity(execution['blockNumber']) - 1)
    pre_block = block(rpc, pre_tag)
    require(execution_block['parentHash'].lower() == pre_block['hash'].lower(), 'pre-upgrade block is not parent')
    require(address(tx['to']) == wallet and quantity(tx['value']) == 0 and address(tx['from']) in owners,
            'wrong wallet execution envelope')
    calls = [cast('calldata', fn + '(uint256)', str(identifier)) for fn in ['confirmTransaction', 'executeTransaction']]
    require(tx['input'].lower() in calls, 'wrong wallet transaction calldata/ID')
    exact_upgrade = cast('calldata', 'upgradeTo(address)', implementation)
    before_wallet = wallet_state(rpc, wallet, identifier, owners, 3, pre_tag)
    after_wallet = wallet_state(rpc, wallet, identifier, owners, 3, execution['blockNumber'])
    for snapshot, executed in [(before_wallet, False), (after_wallet, True)]:
        require(snapshot['transaction'] == {'destination': proxy, 'value': 0, 'data': exact_upgrade, 'executed': executed},
                'wallet target/value/data/execution mismatch')
    require(len(after_wallet['confirmations']) >= 3 and tx['from'].lower() in after_wallet['confirmations'], 'insufficient confirmations')
    if tx['input'].lower() == calls[0]:
        require(tx['from'].lower() not in before_wallet['confirmations'], 'confirm sender already confirmed before receipt')
    else:
        require(tx['from'].lower() in before_wallet['confirmations'], 'execute sender was not confirmed')
    execution_topic, failure_topic = cast('keccak', 'Execution(uint256)'), cast('keccak', 'ExecutionFailure(uint256)')
    matching = [log for log in execution['logs'] if log['address'].lower() == wallet
                and log['topics'] == [execution_topic, '0x' + word(identifier)] and log['data'] == '0x']
    require(len(matching) == 1, 'missing/duplicate wallet Execution event')
    require(not any(log['address'].lower() == wallet and log['topics'][:1] == [failure_topic]
                    for log in execution['logs']), 'wallet ExecutionFailure present')
    upgrades = [log for log in execution['logs'] if log['address'].lower() == proxy
                and log['topics'] == [cast('keccak', 'Upgraded(address)'), '0x' + address_word(implementation)]
                and log['data'] == '0x']
    require(len(upgrades) == 1, 'missing/duplicate proxy Upgraded event')
    require(quantity(upgrades[0]['logIndex']) < quantity(matching[0]['logIndex']),
            'proxy upgrade did not precede wallet Execution')
    if tx['input'].lower() == calls[0]:
        confirmations = [log for log in execution['logs'] if log['address'].lower() == wallet and log['topics'] ==
                         [cast('keccak', 'Confirmation(address,uint256)'), '0x' + address_word(tx['from'].lower()),
                          '0x' + word(identifier)] and log['data'] == '0x']
        require(len(confirmations) == 1 and quantity(confirmations[0]['logIndex']) < quantity(upgrades[0]['logIndex']),
                'missing/out-of-order confirming owner event')
    expected = spec['expectedState']
    require(expected['owner'].lower() == wallet and type(expected['exitFeeEnabled']) is bool, 'invalid expected controller state')
    before_state = state(rpc, proxy, expected, pre_tag)
    after_state = state(rpc, proxy, expected, execution['blockNumber'])
    surfaces = sorted(set([cast('keccak', name) for name in SURFACES] +
                          [hex_value(s, 32) for s in spec.get('extraSurfaceIds', [])]))
    before_policies = fee_policies(rpc, proxy, surfaces, pre_tag)
    after_policies = fee_policies(rpc, proxy, surfaces, execution['blockNumber'])
    require(before_policies == after_policies, 'fee policy/index state changed across upgrade')
    before_slots = raw_slots(rpc, proxy, previous['storageLayout'], pre_tag)
    require(before_slots == raw_slots(rpc, proxy, previous['storageLayout'], execution['blockNumber']),
            'preserved storage changed across upgrade')
    require(decode_uint(rpc.call(proxy, 'securityPerimeterEnabled()', [], execution['blockNumber'])) == 0
            and decode_uint(rpc.call(proxy, 'globalDelaySeconds()', [], execution['blockNumber'])) == 0,
            'unexpected initialized delay state at upgrade')
    latest = block(rpc, 'latest')
    for tag in [pre_tag, execution['blockNumber'], latest['number']]:
        expected_impl = old_impl if tag == pre_tag else implementation
        require(decode_address(rpc.read('eth_getStorageAt', [proxy, IMPL_SLOT, tag])) == expected_impl,
                'implementation slot mismatch')
        require(cast('keccak', hex_value(rpc.read('eth_getCode', [proxy, tag]))) == spec['proxyRuntimeCodeHash'],
                'proxy runtime changed/mismatched')
        require(cast('keccak', hex_value(rpc.read('eth_getCode', [wallet, tag]))) == wallet_spec['runtimeCodeHash'],
                'wallet runtime changed/mismatched')
        require(hex_value(rpc.read('eth_getCode', [implementation, tag])) == expected_runtime,
                'implementation runtime/profile mismatch')
    require(cast('keccak', hex_value(rpc.read('eth_getCode', [old_impl, pre_tag]))) == previous['implBytecodeHash'],
            'rollback implementation hash mismatch')
    current_state = state(rpc, proxy, expected, latest['number'])
    require(wallet_state(rpc, wallet, identifier, owners, 3, latest['number'])['transaction']['executed'],
            'latest wallet execution state conflict')
    for header in [creation_block, pre_block, execution_block, latest]:
        require(block(rpc, header['number'])['hash'] == header['hash'], 'canonical block changed during finalization')
    require(rpc.read('eth_getTransactionReceipt', [execution_hash]) == execution, 'execution receipt changed during finalization')
    require(decode_address(rpc.read('eth_getStorageAt', [proxy, IMPL_SLOT, 'latest'])) == implementation,
            'latest implementation changed during finalization')
    timestamp = quantity(execution_block['timestamp'])
    result = {**previous, 'contractName': spec['contractName'], 'chainId': chain, 'proxyAddress': proxy,
              'implAddress': implementation, 'implBytecodeHash': cast('keccak', expected_runtime),
              'deploymentBlock': quantity(execution['blockNumber']), 'deploymentTx': execution_hash,
              'implementationDeploymentTx': creation_hash, 'timestamp': timestamp * 1000,
              'timestampUnit': 'milliseconds', 'gitSha': profile['source_pin'],
              'abi': artifact['abi'], 'storageLayout': artifact['storageLayout']}
    result['finalization'] = {
        'schemaVersion': 1, 'mode': 'multisig-upgrade', 'manifestSha256': args.manifest_sha256,
        'executedAtUtc': datetime.datetime.fromtimestamp(timestamp, datetime.timezone.utc).isoformat().replace('+00:00', 'Z'),
        'validatedAtUtc': datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z'),
        'wallet': {'address': wallet, 'transactionId': identifier, **after_wallet},
        'executionTransaction': tx, 'executionReceipt': execution,
        'implementationDeploymentTransaction': deployment, 'implementationDeploymentReceipt': creation,
        'blocks': {'creation': creation_block, 'before': pre_block, 'execution': execution_block, 'latest': latest},
        'profile': {'artifactSha256': sha(artifact_raw), 'profileSha256': sha(profile_raw), 'sourceGitSha': profile['source_pin'],
                    'compiler': entry['compiler'], 'optimizer': entry['optimizer'], 'evmVersion': entry['evm_version'],
                    'immutableReferences': entry['immutable_references']},
        'toolHashes': {name: sha(Path(__file__).with_name(name).read_bytes()) for name in
                       ['finalize-multisig-upgrade.py', 'finalize-deployment.sh', 'diff-storage-layouts.py']},
        'preservedState': {'before': before_state, 'after': after_state, 'latest': current_state,
                           'rawStorageSlots': before_slots, 'feeSurfacesAndEnumeratedKeys': before_policies},
        'preservationCoverage': 'All prior non-gap storage words and five canonical fee surfaces plus declared extra IDs and their enumerated policy keys. No claim to discover undeclared arbitrary mapping keys.',
        'rollback': {'recordSha256': sha(previous_raw), 'originalJson': previous_raw.decode(),
                     'implementationAddress': old_impl, 'implementationCodeHash': previous['implBytecodeHash']},
    }
    with open(str(record_path) + '.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        require(record_path.read_bytes() == current_raw, 'deployment record changed during finalization')
        if already:
            for key in ['contractName', 'chainId', 'proxyAddress', 'implAddress', 'implBytecodeHash',
                        'deploymentBlock', 'deploymentTx', 'implementationDeploymentTx', 'timestamp',
                        'timestampUnit', 'gitSha', 'abi', 'storageLayout']:
                require(current.get(key) == result[key], 'conflicting previously finalized record')
            saved_proof, verified_proof = json.loads(json.dumps(current['finalization'])), json.loads(json.dumps(result['finalization']))
            for proof in [saved_proof, verified_proof]:
                proof.pop('validatedAtUtc', None)
                proof['blocks'].pop('latest', None)
            require(saved_proof == verified_proof, 'conflicting previously finalized receipt/provenance')
            print(f'Already finalized matching multisig receipt: {record_path}')
            return
        with tempfile.NamedTemporaryFile(mode='w', dir=record_path.parent, prefix='.finalize-', delete=False) as output:
            temporary = Path(output.name)
            try:
                json.dump(result, output, indent=2)
                output.write('\n')
                output.flush()
                os.fsync(output.fileno())
                os.chmod(temporary, record_path.stat().st_mode & 0o777)
                os.replace(temporary, record_path)
            finally:
                temporary.unlink(missing_ok=True)
    print(f'Finalized real multisig upgrade receipt: {record_path}')


def main():
    if len(sys.argv) > 1 and sys.argv[1] == '--verify-profile':
        parser = argparse.ArgumentParser(description='Check reviewed source/settings before explorer publication')
        parser.add_argument('--record', required=True)
        parser.add_argument('--artifact', required=True)
        args = parser.parse_args(sys.argv[2:])
        try:
            check_verification_profile(Path(args.record), Path(args.artifact))
            return 0
        except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
            print(f'verification profile refused: {error}', file=sys.stderr)
            return 1
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', required=True)
    parser.add_argument('--manifest-sha256', required=True)
    parser.add_argument('--rpc-url', required=True)
    args = parser.parse_args()
    try:
        finalize(args)
        return 0
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        print(f'multisig finalization refused: {error}', file=sys.stderr)
    return 1


def check_verification_profile(record_path, artifact_path):
    record = json.loads(record_path.read_bytes())
    require(record['finalization']['mode'] == 'multisig-upgrade', 'not a finalized multisig record')
    raw = artifact_path.read_bytes()
    require(sha(raw) == record['finalization']['profile']['artifactSha256'], 'verification artifact hash mismatch')
    artifact = json.loads(raw)
    metadata = artifact['metadata']
    metadata = json.loads(metadata) if isinstance(metadata, str) else metadata
    settings = metadata['settings']
    require(settings['compilationTarget'] == {'src/ExitFeeController.sol': 'ExitFeeController'}, 'wrong verification source target')
    cfg = json.loads(subprocess.check_output(['forge', 'config', '--json']))
    require(cfg['optimizer'] == settings['optimizer']['enabled']
            and cfg['optimizer_runs'] == settings['optimizer']['runs']
            and cfg['evm_version'] == settings['evmVersion']
            and cfg['via_ir'] == settings.get('viaIR', False)
            and cfg['bytecode_hash'] == settings['metadata']['bytecodeHash']
            and cfg['cbor_metadata'] == settings['metadata'].get('appendCBOR', True)
            and cfg['use_literal_content'] == settings['metadata'].get('useLiteralContent', False)
            and (cfg.get('optimizer_details') or {}) == (settings['optimizer'].get('details') or {}),
            'effective verification compiler profile mismatch')
    require(sorted(cfg['remappings']) == sorted(settings['remappings']), 'verification remappings differ from artifact')
    root = Path.cwd().resolve()
    require(metadata['sources'], 'missing reviewed source hashes')
    for name, source in metadata['sources'].items():
        path = (root / name).resolve()
        require(path.is_relative_to(root) and path.is_file(), 'verification source outside/missing from checkout')
        require(cast('keccak', '0x' + path.read_bytes().hex()) == source['keccak256'], f'verification source changed: {name}')
    print('Reviewed multisig source and compiler profile match current verification inputs')


if __name__ == '__main__':
    sys.exit(main())
