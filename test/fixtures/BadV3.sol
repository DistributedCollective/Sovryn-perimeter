// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IExitFeeController} from "../../src/ExitFeeController.sol";

/// @dev Test fixture ONLY. NOT a real upgrade candidate.
///
///      Models a sneaky-unsafe upgrade where the storage variables KEEP
///      their slots and labels and the struct keeps its NAME -- but the
///      struct's members are reordered. The naive type-string check
///      `t_struct(RatePolicy)<id>_storage` matches because the ID is
///      stripped during normalization; only deep-comparing the type
///      definition's member list catches the violation.
///
///      Solidity ABI-encodes structs positionally, so swapping member
///      order in this RatePolicy would silently misread every saved
///      RatePolicy entry after upgrade.
///
///      tools/diff-storage-layouts.py MUST reject this layout against
///      a saved ExitFeeController.json with "shifted or changed shape".
///
///      HOW TO REGENERATE (do this whenever ExitFeeController's storage
///      changes): mirror `forge inspect ExitFeeController storageLayout`
///      EXACTLY (slots 251..271 today, __gap unchanged at [29]) — the
///      ONLY intentional deviation is the LOCAL RatePolicy below whose
///      two members are swapped. Everything else must match byte-for-byte
///      so the tool rejects for the struct reorder and NOT for a missing
///      or moved variable. DelayBypassPolicy is imported from
///      IExitFeeController so it stays identical; only RatePolicy is
///      redefined locally to carry the reorder.
contract BadV3 is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    // Same struct NAME, different member ORDER. (active before rateBps in the
    // real ExitFeeController; here we swap them.) Both orderings occupy one
    // 32-byte slot, so the OUTER layout is byte-identical — the reorder is
    // only visible by deep-comparing the struct's member list.
    struct RatePolicy {
        uint16 rateBps;
        bool active;
    }

    uint16 public constant MAX_BPS = 10_000;

    // ── Mirror of ExitFeeController own storage, slots 251..270 ──────────

    // slot 251 (packed: bool@0, address@1)
    bool public exitFeeEnabled;
    address public feeReceiver;

    // slots 252..256 — use the LOCAL (reordered) RatePolicy.
    mapping(bytes32 => RatePolicy) internal _surfacePolicy;
    mapping(bytes32 => mapping(address => RatePolicy)) internal _subProductPolicy;
    mapping(bytes32 => mapping(address => RatePolicy)) internal _actorPolicy;
    mapping(bytes32 => EnumerableSet.AddressSet) internal _subProductKeys;
    mapping(bytes32 => EnumerableSet.AddressSet) internal _actorKeys;

    // slot 257 (packed: bool@0, uint32@1, address@5) — DO NOT reorder.
    address public admin;

    // slots 258..270 — DelayBypassPolicy imported so it stays identical.
    mapping(bytes32 => IExitFeeController.DelayBypassPolicy) internal _surfaceBypass;
    mapping(bytes32 => mapping(address => IExitFeeController.DelayBypassPolicy)) internal _subProductBypass;
    mapping(bytes32 => mapping(address => IExitFeeController.DelayBypassPolicy)) internal _actorBypass;
    EnumerableSet.Bytes32Set internal _surfaceBypassKeys; // slots 261..262 (2 slots)
    mapping(bytes32 => EnumerableSet.AddressSet) internal _subProductBypassKeys;
    mapping(bytes32 => EnumerableSet.AddressSet) internal _actorBypassKeys;
    mapping(bytes32 => mapping(address => bool)) internal _passthroughActor;
    mapping(bytes32 => EnumerableSet.AddressSet) internal _passthroughKeys;
    EnumerableSet.Bytes32Set internal _bypassSurfaceIds; // slots 267..268 (2 slots)
    EnumerableSet.Bytes32Set internal _passthroughSurfaceIds; // slots 269..270 (2 slots)

    // __gap unchanged — this fixture adds NO storage; it only reorders a struct.
    bool public securityPerimeterEnabled;
    uint32 public globalDelaySeconds;

    uint256[29] private __gap;

    function _authorizeUpgrade(address) internal view override onlyOwner {}
}
