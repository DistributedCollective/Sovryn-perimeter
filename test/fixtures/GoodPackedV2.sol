// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IExitFeeController} from "../../src/ExitFeeController.sol";

/// @dev Test fixture ONLY. NOT a real upgrade candidate.
///
///      Models a SAFE upgrade that adds two packed uint128 fields after
///      the controller's existing state. Both fields share the FIRST
///      reclaimed __gap slot (Solidity packs uint128 + uint128 into
///      one 32-byte slot at offsets 0 and 16). The __gap should
///      therefore shrink by exactly 1 slot, NOT 2.
///
///      The naive accounting (sum of per-entry slot spans) would see
///      "2 new entries, span 1 each = 2 slots reclaimed" and reject
///      this as inconsistent with a 1-slot gap shrinkage. The correct
///      accounting (UNION of slot ranges) sees both entries at slot
///      271 covering [271, 272) = 1 slot.
///
///      tools/diff-storage-layouts.py MUST accept this layout as
///      upgrade-safe.
///
///      HOW TO REGENERATE (do this whenever ExitFeeController's storage
///      changes): mirror `forge inspect ExitFeeController storageLayout`
///      EXACTLY — every own variable (slots 251..271 today), in the same
///      order, with the same struct types (imported from
///      IExitFeeController so the type definitions are byte-identical) —
///      then place the two packed uint128 fields at the FIRST still-unused
///      __gap slot and shrink __gap by 1 (29 -> 28). The mirror below is
///      current as of the security-perimeter delay extension (admin alone in
///      its shipped slot, bypass tiers, passthrough registry, enumeration
///      sets, then the two delay scalars in a reclaimed gap slot).
contract GoodPackedV2 is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    uint16 public constant MAX_BPS = 10_000;

    // ── Mirror of ExitFeeController own storage, slots 251..270 ──────────

    // slot 251 (packed: bool@0, address@1)
    bool public exitFeeEnabled;
    address public feeReceiver;

    // slots 252..256
    mapping(bytes32 => IExitFeeController.RatePolicy) internal _surfacePolicy;
    mapping(bytes32 => mapping(address => IExitFeeController.RatePolicy)) internal _subProductPolicy;
    mapping(bytes32 => mapping(address => IExitFeeController.RatePolicy)) internal _actorPolicy;
    mapping(bytes32 => EnumerableSet.AddressSet) internal _subProductKeys;
    mapping(bytes32 => EnumerableSet.AddressSet) internal _actorKeys;

    // slot 257 — `admin` alone, exactly as the fee release shipped it.
    address public admin;

    // slots 258..270
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

    // slot 271 (packed: bool@0, uint32@1, uint216@5) — delay scalars, slot
    // fully consumed so an appended field starts at the next whole slot.
    bool public securityPerimeterEnabled;
    uint32 public globalDelaySeconds;
    uint216 private __slot271Reserved;

    // Two packed uint128 fields. Both go at slot 272 (the first slot still
    // inside __gap[29]) at offset 0 and offset 16 of the SAME slot — this is
    // what closing slot 271 buys. The gap should shrink to __gap[28].
    uint128 public newA;
    uint128 public newB;

    // __gap shrinks by exactly 1 slot (one slot reclaimed for the two
    // packed uint128 fields): 29 -> 28.
    uint256[28] private __gap;

    function _authorizeUpgrade(address) internal view override onlyOwner {}
}
