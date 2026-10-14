#!/usr/bin/env python3
"""Validate complete campaign inventories and counts; fail closed on tool errors."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def source_snapshot():
    root = Path.cwd()
    files, heads = {}, {}

    def visit(directory):
        top = subprocess.check_output([
            "git", "-C", str(directory), "rev-parse", "--show-toplevel",
        ]).decode().strip()
        require(Path(top).resolve() == directory.resolve(), f"uninitialized dependency: {directory}")
        status = subprocess.check_output([
            "git", "-C", str(directory), "status", "--porcelain",
            "--untracked-files=normal", "--ignore-submodules=none",
        ])
        require(not status.strip(), f"source is not pristine: {directory}")
        relative = directory.relative_to(root).as_posix()
        heads[relative] = subprocess.check_output([
            "git", "-C", str(directory), "rev-parse", "HEAD",
        ]).decode().strip()
        paths = subprocess.check_output([
            "git", "-C", str(directory), "ls-files", "-z",
        ]).decode().split("\0")
        for name in filter(None, paths):
            path = directory / name
            if path.is_dir():
                visit(path)
            else:
                require(not path.is_symlink(), f"tracked symlink needs explicit review: {path}")
                files[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()

    visit(root)
    payload = {"heads": heads, "files": files}
    digest = hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()
    return {**payload, "sha256": digest}


def check_foundry(args, text):
    require(args.exit_code == 0, f"Foundry tool exited {args.exit_code}")
    inventory = json.loads(Path(args.inventory).read_text())
    require(isinstance(inventory, dict), "invalid Foundry inventory")
    expected = set()
    for file, contracts in inventory.items():
        require(isinstance(contracts, dict), "invalid contract inventory")
        for contract, names in contracts.items():
            require(isinstance(names, list), "invalid test inventory")
            for name in names:
                require(isinstance(name, str) and name.startswith(("testFuzz_", "invariant_")), "invalid test name")
                key = (file, contract, name)
                require(key not in expected, f"duplicate inventory entry: {key}")
                expected.add(key)
    require(any(key[2].startswith("testFuzz_") for key in expected), "no fuzz tests in inventory")
    require(any(key[2].startswith("invariant_") for key in expected), "no invariants in inventory")
    actual, suite = {}, None
    for line in text.splitlines():
        header = re.fullmatch(r"Ran \d+ tests? for (.+):([^:]+)", line)
        if header:
            suite = tuple(header.groups())
        result = re.fullmatch(
            r"\[([^]]+)\] ((?:testFuzz_|invariant_)\w+)\(.*\) \((.*)\)", line
        )
        if not result:
            continue
        status, name, counts = result.groups()
        require(suite is not None, "test result without suite identity")
        key = (*suite, name)
        require(key not in actual, f"duplicate Foundry result: {key}")
        require(status == "PASS", f"nonpassing Foundry result: {key}: {status}")
        runs = re.search(r"\bruns:\s*(\d+)(?=\s*(?:,|$))", counts)
        require(runs is not None, f"missing run count: {key}")
        runs = int(runs[1])
        minimum = args.fuzz_runs if name.startswith("testFuzz_") else args.invariant_runs
        require(runs >= minimum, f"short run count: {key}: {runs} < {minimum}")
        values = {"runs": runs}
        if name.startswith("invariant_"):
            calls = re.search(r"\bcalls:\s*(\d+)(?=\s*(?:,|$))", counts)
            reverts = re.search(r"\breverts:\s*(\d+)(?=\s*(?:,|$))", counts)
            require(calls is not None and reverts is not None, f"missing invariant counters: {key}")
            values.update(calls=int(calls[1]), reverts=int(reverts[1]))
            require(values["calls"] >= runs * args.invariant_depth, f"short invariant depth: {key}")
            require(values["reverts"] == 0, f"unexpected handler reverts: {key}")
        actual[key] = values
    require(actual.keys() == expected, f"Foundry inventory mismatch: missing={expected-actual.keys()}, extra={actual.keys()-expected}")
    summaries = re.findall(
        r"^Ran \d+ test suites? .*?: (\d+) tests passed, (\d+) failed, (\d+) skipped(?: \((\d+) total tests\))?$",
        text, re.MULTILINE,
    )
    require(len(summaries) == 1, "missing or duplicate final Foundry summary")
    passed, failed, skipped, total = summaries[0]
    require(int(passed) == len(expected) and int(failed) == int(skipped) == 0, "Foundry final summary mismatch")
    require(not total or int(total) == len(expected), "Foundry total count mismatch")
    return {"tests": [{"file": key[0], "contract": key[1], "name": key[2], **values}
                      for key, values in sorted(actual.items())]}


def check_echidna(args, text):
    required_exit = 1 if args.failure else 0
    require(args.exit_code == required_exit, f"Echidna tool exited {args.exit_code}; expected {required_exit}")
    expected = set()
    for path in args.harness:
        names = re.findall(r"\bfunction\s+(echidna_\w+)\s*\(", Path(path).read_text())
        require(not expected.intersection(names), "duplicate declared property")
        expected.update(names)
    require(expected, "empty property inventory")
    require(not args.failure or args.failure in expected, "expected reach property absent from inventory")
    actual = {}
    for name, status in re.findall(r"^(echidna_\w+):\s*(passing|failed!?(?:💥)?|FAILED!?(?:💥)?)\s*$", text, re.MULTILINE):
        require(name not in actual, f"duplicate property verdict: {name}")
        actual[name] = status == "passing"
    require(actual.keys() == expected, f"Echidna inventory mismatch: missing={expected-actual.keys()}, extra={actual.keys()-expected}")
    failed = {name for name, passing in actual.items() if not passing}
    require(failed == ({args.failure} if args.failure else set()), f"unexpected failed properties: {failed}")
    counts = re.findall(r"^Total calls:\s*(\d+)\s*$", text, re.MULTILINE)
    require(len(counts) == 1, "missing or duplicate completed-call summary")
    calls = int(counts[0])
    require(calls >= args.limit, f"truncated Echidna: {calls} < {args.limit}")
    return {"calls": calls, "properties": actual}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=["snapshot", "foundry", "echidna"])
    parser.add_argument("--log")
    parser.add_argument("--report")
    parser.add_argument("--exit-code", type=int)
    parser.add_argument("--inventory")
    parser.add_argument("--fuzz-runs", type=int, default=20000)
    parser.add_argument("--invariant-runs", type=int, default=2000)
    parser.add_argument("--invariant-depth", type=int, default=200)
    parser.add_argument("--harness", action="append", default=[])
    parser.add_argument("--failure")
    parser.add_argument("--limit", type=int, default=500000)
    args = parser.parse_args()
    try:
        if args.phase == "snapshot":
            result = source_snapshot()
        else:
            require(args.log is not None and args.exit_code is not None, "log and tool exit are required")
            text = ANSI.sub("", Path(args.log).read_text())
            result = check_foundry(args, text) if args.phase == "foundry" else check_echidna(args, text)
        if args.report:
            Path(args.report).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        print(result["sha256"] if args.phase == "snapshot" else json.dumps(result, sort_keys=True))
        return 0
    except (ValueError, OSError, subprocess.CalledProcessError, TypeError) as error:
        print(f"release-campaign: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
