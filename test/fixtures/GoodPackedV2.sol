// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

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
///      258 covering [258, 259) = 1 slot.
///
///      tools/diff-storage-layouts.py MUST accept this layout as
///      upgrade-safe.
contract GoodPackedV2 is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    struct RatePolicy {
        bool active;
        uint16 rateBps;
    }

    uint16 public constant MAX_BPS = 10_000;

    // Mirrors the live ExitFeeController layout exactly through slot 257.
    bool public exitFeeEnabled;
    address public feeReceiver;

    mapping(bytes32 => RatePolicy) internal _surfacePolicy;
    mapping(bytes32 => mapping(address => RatePolicy)) internal _subProductPolicy;
    mapping(bytes32 => mapping(address => RatePolicy)) internal _actorPolicy;
    mapping(bytes32 => EnumerableSet.AddressSet) internal _subProductKeys;
    mapping(bytes32 => EnumerableSet.AddressSet) internal _actorKeys;

    address public admin;

    // Two packed uint128 fields. Both go at slot 258 (the first slot
    // previously inside __gap[43]). Solidity puts them at offset 0 and
    // offset 16 of the SAME slot. The gap should shrink to __gap[42].
    uint128 public newA;
    uint128 public newB;

    // __gap shrinks by exactly 1 slot (one slot reclaimed for the two
    // packed uint128 fields).
    uint256[42] private __gap;

    function _authorizeUpgrade(address) internal view override onlyOwner {}
}
