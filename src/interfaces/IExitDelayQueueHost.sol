// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title  IExitDelayQueueHost — the queue-pointer surface a product host exposes
/// @notice Minimal interface for the `setExitDelayQueue` pointer.
///         Each product storage host — the `sovrynProtocol` singleton (lending +
///         loan/margin) and the Zero `BorrowerOperations` proxy — holds its OWN
///         queue address in a NEW EIP-1967-style unstructured slot
///         `keccak256("sovryn.perimeterExitDelayQueue") - 1`, set by `setExitDelayQueue`
///         (gated by the SAME host admin as `setExitFeeController`, Owner/Timelock,
///         and rotatable) and read back via `exitDelayQueue()`.
///
/// @dev    The host CONTRACTS live in the product repos (Sovryn-smart-contracts-perimeter
///         / zero-contracts-perimeter) on the 0.5.x / 0.6.x pragmas; this 0.8.20 stub
///         exists ONLY so the perimeter deploy/wire script (05) can call the pointer
///         setter and read it back over the cross-pragma ABI when the host addresses
///         are supplied. It intentionally declares nothing else — the queue itself
///         is never a host and never implements this.
interface IExitDelayQueueHost {
    /// @notice Point this host's exit-delay reroute at `queue` (wire/rotate).
    ///         Owner/Timelock-gated on the host; a no-op in perimeter (hosts are external).
    function setExitDelayQueue(address queue) external;

    /// @notice The host's current queue pointer (0 = reroute unwired ⇒ direct pay).
    function exitDelayQueue() external view returns (address);
}
