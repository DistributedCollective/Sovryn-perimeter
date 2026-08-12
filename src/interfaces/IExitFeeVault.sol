// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title  IExitFeeVault
/// @notice Passive holder for collected ExitFee balances. Consumed only by
///         the controller's own 0.8.20 tests and the deploy/sweep scripts —
///         the home repos don't import this file. ERC20 and native RBTC are
///         both supported via separate `sweep*` paths; the vault itself never
///         pulls — it only releases on admin-signed sweep calls.
interface IExitFeeVault {
    event Swept(address indexed asset, address indexed to, uint256 amount);
    event RBTCSwept(address indexed to, uint256 amount);
    event DefaultRecipientSet(address indexed previous, address indexed current);
    event AdminSet(address indexed admin);

    /// @notice Appoint (or rotate) the operational guardian admitted by the
    ///         vault's `onlyAdminOrOwner` gate. Owner-only; reverts on
    ///         `address(0)`. May equal the owner.
    /// @param  newAdmin Non-zero address.
    function setAdmin(address newAdmin) external;

    /// @notice Set (or rotate) the default sweep recipient used by the
    ///         no-recipient sweep overloads. Reverts on `address(0)`.
    ///         Caller must be the admin or the owner.
    /// @param  newRecipient Non-zero address.
    function setDefaultRecipient(address newRecipient) external;

    /// @notice Sweep an ERC20 balance to `to`. Caller must be the admin or
    ///         the contract owner. With UUPS there is no separate
    ///         proxy-admin role -- ownership IS the authority for upgrades;
    ///         sweeps additionally admit the operational admin.
    function sweepERC20(address asset, address to, uint256 amount) external;

    /// @notice Sweep an ERC20 balance to `defaultRecipient`. Reverts with
    ///         `DefaultRecipientUnset` if the default has not been set.
    ///         Otherwise behaves like the 3-arg overload.
    function sweepERC20(address asset, uint256 amount) external;

    /// @notice Sweep native RBTC to `to`. Caller must be the admin or the
    ///         contract owner.
    function sweepRBTC(address payable to, uint256 amount) external;

    /// @notice Sweep native RBTC to `defaultRecipient`. Reverts with
    ///         `DefaultRecipientUnset` if the default has not been set.
    ///         Otherwise behaves like the 2-arg overload.
    function sweepRBTC(uint256 amount) external;
}
