// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IExitFeeController} from "../../src/ExitFeeController.sol";

/// @dev Test fixture ONLY. NOT a real upgrade candidate.
///
///      Models a SAFE upgrade that adds storage after the controller's
///      existing state: one full-slot field in the first reserved slot (268),
///      then two uint128 fields that Solidity packs into the next slot (269, at
///      offsets 0 and 16). The __gap therefore shrinks by exactly 2 slots,
///      NOT 3.
///
///      The naive accounting (sum of per-entry slot spans) would see "3 new
///      entries, span 1 each = 3 slots reclaimed" and reject this as
///      inconsistent with a 2-slot gap shrinkage. The correct accounting
///      (UNION of slot ranges) sees [268, 270) = 2 slots.
///
///      tools/diff-storage-layouts.py MUST accept this layout as
///      upgrade-safe.
///
///      HOW TO REGENERATE (do this whenever ExitFeeController's storage
///      changes): mirror `forge inspect ExitFeeController storageLayout`
///      EXACTLY — every own variable (slots 251..267 today), in the same
///      order, with the same labels and the same struct types (imported from
///      IExitFeeController so the type definitions are byte-identical) —
///      then add the new fields at the first reserved slot and shrink __gap
///      by the number of slots they occupy (33 -> 31).
contract GoodPackedV2 is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    uint16 public constant MAX_BPS = 10_000;

    // ── Mirror of ExitFeeController own storage, slots 251..267 ──────────

    // slot 251 (packed: bool@0, address@1)
    bool public exitFeeEnabled;
    address public feeReceiver;

    // slots 252..256
    mapping(bytes32 => IExitFeeController.RatePolicy) internal _surfacePolicy;
    mapping(bytes32 => mapping(address => IExitFeeController.RatePolicy)) internal _subProductPolicy;
    mapping(bytes32 => mapping(address => IExitFeeController.RatePolicy)) internal _actorPolicy;
    mapping(bytes32 => EnumerableSet.AddressSet) internal _subProductKeys;
    mapping(bytes32 => EnumerableSet.AddressSet) internal _actorKeys;

    // slot 257 — `admin` alone.
    address public admin;

    // slots 258..266
    mapping(bytes32 => IExitFeeController.DelayBypassPolicy) internal _surfaceBypass;
    mapping(bytes32 => mapping(address => IExitFeeController.DelayBypassPolicy)) internal _subProductBypass;
    mapping(bytes32 => mapping(address => IExitFeeController.DelayBypassPolicy)) internal _actorBypass;
    EnumerableSet.Bytes32Set internal _surfaceBypassKeys; // slots 261..262 (2 slots)
    mapping(bytes32 => EnumerableSet.AddressSet) internal _subProductBypassKeys;
    mapping(bytes32 => EnumerableSet.AddressSet) internal _actorBypassKeys;
    EnumerableSet.Bytes32Set internal _bypassSurfaceIds; // slots 265..266 (2 slots)

    // slot 267 (packed: bool@0, uint32@1) — the delay scalars.
    bool public securityPerimeterEnabled;
    uint32 public globalDelaySeconds;

    // A full-slot field at 268, then two uint128 packed into slot 269 at
    // offset 0 and offset 16.
    uint256 public newFull;
    uint128 public newA;
    uint128 public newB;

    // __gap shrinks by exactly 2 slots: 33 -> 31.
    uint256[31] private __gap;

    function _authorizeUpgrade(address) internal view override onlyOwner {}
}
