// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

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
///      a saved ExitFeeController.json.
contract BadV3 is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    // Same struct NAME, different member ORDER. (active before rateBps in the
    // real ExitFeeController; here we swap them.)
    struct RatePolicy {
        uint16 rateBps;
        bool active;
    }

    uint16 public constant MAX_BPS = 10_000;

    bool public exitFeeEnabled;
    address public feeReceiver;

    mapping(bytes32 => RatePolicy) internal _surfacePolicy;
    mapping(bytes32 => mapping(address => RatePolicy)) internal _subProductPolicy;
    mapping(bytes32 => mapping(address => RatePolicy)) internal _actorPolicy;
    mapping(bytes32 => EnumerableSet.AddressSet) internal _subProductKeys;
    mapping(bytes32 => EnumerableSet.AddressSet) internal _actorKeys;

    address public admin;

    uint256[43] private __gap;

    function _authorizeUpgrade(address) internal view override onlyOwner {}
}
