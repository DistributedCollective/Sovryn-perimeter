// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title  IExitFeeControllerHost — the controller-pointer surface a product host exposes
/// @notice Minimal interface for the `exitFeeController` pointer read.
///         Each product storage host — the `sovrynProtocol` singleton (lending +
///         loan/margin) and the Zero `BorrowerOperations` proxy — holds its OWN
///         controller address in a NEW EIP-1967-style unstructured slot
///         `keccak256("sovryn.perimeterExitFeeController") - 1`, set by `setExitFeeController`
///         (gated by the SAME host admin as `setExitDelayQueue`, Owner/Timelock,
///         and rotatable) and read back via `exitFeeController()`.
///
/// @dev    The host CONTRACTS live in the product repos (Sovryn-smart-contracts-perimeter
///         / zero-contracts-perimeter) on the 0.5.x / 0.6.x pragmas; this 0.8.20 stub
///         exists ONLY so the perimeter go-live gate (06) can read the pointer back
///         over the cross-pragma ABI when the host addresses are supplied. It
///         intentionally declares nothing else — the controller itself is never a
///         host and never implements this.
interface IExitFeeControllerHost {
    /// @notice The host's current controller pointer (0 = unwired ⇒ fee/delay
    ///         quote is skipped, exit pays direct).
    function exitFeeController() external view returns (address);
}
