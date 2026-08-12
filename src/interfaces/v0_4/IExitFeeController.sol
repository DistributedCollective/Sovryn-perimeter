// SPDX-License-Identifier: MIT
// Pragma is pinned exactly: 0.4.26 is the only compiler that consumes this
// file, and the range pragma on the unified interface cannot reach back
// this far.
// aderyn-ignore-next-line(unspecific-solidity-pragma)
pragma solidity 0.4.26;
// `pragma experimental ABIEncoderV2;` is required on 0.4.26 for any function
// returning or accepting a struct across the ABI boundary. Same rationale as
// the unified `../IExitFeeController.sol` -- this file exists solely because
// 0.4.x refuses to allow type declarations inside an `interface` body AND
// refuses file-level declarations, so the enum and structs live in a
// sibling `ExitFeeTypes` library. The ABI signatures are identical -- the
// library/interface split is structural; the encoding doesn't differ.
// aderyn-ignore-next-line(experimental-encoder)
pragma experimental ABIEncoderV2;

/// @title  ExitFeeTypes
/// @notice Holds the enum + structs referenced by `IExitFeeController` on
///         Solidity 0.4.26. Same fields and ordinals as the unified file's
///         in-interface types.
library ExitFeeTypes {
    enum SkipReason {
        NONE,
        INACTIVE,
        DISABLED,
        INVALID_QUOTE,
        CONTROLLER_REVERT,
        VAULT_REVERT
    }

    struct RatePolicy {
        bool active;
        uint16 rateBps;
    }

    struct ExitFeeQuote {
        bool active;
        uint16 rateBps;
        uint256 feeAmount;
        uint256 netAmount;
        address feeReceiver;
        uint8 reason;
    }
}

/// @title  IExitFeeController (Solidity 0.4.26 variant)
/// @notice ABI-equivalent to `../IExitFeeController.sol`, for consumers
///         pinned to 0.4.26. Those consumers reach the controller by
///         low-level `staticcall` regardless of typed interface, so the
///         structural mismatch (types in a sibling library, no
///         `memory`/`calldata` keywords) is contained to this declaration.
interface IExitFeeController {
    // ─── Events ──────────────────────────────────────────────────────────

    event ExitFeeEnabledSet(bool enabled);
    event FeeReceiverSet(address indexed feeReceiver);
    event SurfacePolicySet(bytes32 indexed surfaceId, bool active, uint16 rateBps);
    event SubProductPolicySet(
        bytes32 indexed surfaceId, address indexed subProduct, bool active, uint16 rateBps
    );
    event ActorPolicySet(bytes32 indexed surfaceId, address indexed actor, bool active, uint16 rateBps);
    event SubProductPolicyRemoved(bytes32 indexed surfaceId, address indexed subProduct);
    event ActorPolicyRemoved(bytes32 indexed surfaceId, address indexed actor);

    // ─── Quote ───────────────────────────────────────────────────────────

    function quoteExitFee(bytes32 surfaceId, address subProduct, address actor, uint256 grossAmount)
        external
        view
        returns (ExitFeeTypes.ExitFeeQuote);

    // ─── State views ─────────────────────────────────────────────────────

    function exitFeeEnabled() external view returns (bool);
    function feeReceiver() external view returns (address);
    function surfacePolicy(bytes32 surfaceId) external view returns (ExitFeeTypes.RatePolicy);
    function subProductPolicy(bytes32 surfaceId, address subProduct)
        external
        view
        returns (ExitFeeTypes.RatePolicy);
    function actorPolicy(bytes32 surfaceId, address actor) external view returns (ExitFeeTypes.RatePolicy);
    function subProductKeys(bytes32 surfaceId) external view returns (address[]);
    function actorKeys(bytes32 surfaceId) external view returns (address[]);

    // ─── Admin (no `calldata` keyword on 0.4.x; `memory` is the location) ─

    function setExitFeeEnabled(bool enabled) external;
    function setFeeReceiver(address newReceiver) external;
    function setSurfacePolicy(bytes32 surfaceId, ExitFeeTypes.RatePolicy policy) external;
    function setSubProductPolicy(bytes32 surfaceId, address subProduct, ExitFeeTypes.RatePolicy policy)
        external;
    function setSubProductPolicies(
        bytes32 surfaceId,
        address[] subProducts,
        ExitFeeTypes.RatePolicy[] policies
    ) external;
    function setActorPolicy(bytes32 surfaceId, address actor, ExitFeeTypes.RatePolicy policy) external;
    function setActorPolicies(bytes32 surfaceId, address[] actors, ExitFeeTypes.RatePolicy[] policies)
        external;
    function removeSubProductPolicy(bytes32 surfaceId, address subProduct) external;
    function removeSubProductPolicies(bytes32 surfaceId, address[] subProducts) external;
    function removeActorPolicy(bytes32 surfaceId, address actor) external;
    function removeActorPolicies(bytes32 surfaceId, address[] actors) external;
}
