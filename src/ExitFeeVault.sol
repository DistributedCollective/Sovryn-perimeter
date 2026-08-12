// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IExitFeeVault} from "./interfaces/IExitFeeVault.sol";

/// @title  ExitFeeVault
/// @notice Passive holder for collected ExitFee balances. Accepts native
///         RBTC and any ERC20 transfer in; releases only via admin-signed
///         `sweep*` calls. The vault itself never pulls -- product hooks
///         do `transfer` / `to.call{value: ...}` directly. UUPS upgradeable;
///         only the owner can authorize a new impl.
//
// The `payable` flag from UUPSUpgradeable.upgradeToAndCall is the only
// non-receive payable surface on this contract; it's owner-gated by
// _authorizeUpgrade. The intentional receive() below is documented (vault
// is a passive holder by design -- accepting RBTC is the whole point).
// aderyn-ignore-next-line(contract-locks-ether)
contract ExitFeeVault is
    IExitFeeVault,
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    // ─── Own storage ────────────────────────────────────────────────────
    // Verified via `forge inspect ExitFeeVault storageLayout`. The vault's
    // "own" slot 0 sits at proxy slot 301 after the inherited OZ namespaces:
    //
    //   0          Initializable (_initialized + _initializing packed)
    //   1   .. 50  Initializable.__gap
    //   51  .. 100 UUPSUpgradeable.__gap
    //   101 .. 150 ContextUpgradeable.__gap
    //   151        OwnableUpgradeable._owner
    //   152 .. 200 OwnableUpgradeable.__gap
    //   201        Ownable2StepUpgradeable._pendingOwner
    //   202 .. 250 Ownable2StepUpgradeable.__gap
    //   251        ReentrancyGuardUpgradeable._status
    //   252 .. 300 ReentrancyGuardUpgradeable.__gap
    //   301        ExitFeeVault.defaultRecipient (address, 20 bytes;
    //                                             slot offset 0, 12 bytes free).
    //   302        ExitFeeVault.admin            (address, 20 bytes;
    //                                             slot offset 0, 12 bytes free).
    //   303 .. 350 ExitFeeVault.__gap[48] -- preserves the OZ-style 50-slot
    //                                       namespace (50 - 2 own slots used).
    //
    // Upgrades that add storage to THIS contract MUST consume from __gap
    // and reduce its length by exactly the number of slots added. They
    // MUST NOT reorder, insert, or change the type of any preceding slot.

    /// @notice Convenience default for the sweep overloads that omit the
    ///         recipient. The 3-arg `sweepERC20(...)` / 2-arg `sweepRBTC(...)`
    ///         variants always honor their explicit `to` and ignore this
    ///         field. Set or rotated via `setDefaultRecipient`, which rejects
    ///         `address(0)`. Until first set it reads `address(0)`, and the
    ///         no-recipient sweep overloads revert `DefaultRecipientUnset` in
    ///         that state; once set it stays non-zero (clearing it would
    ///         require a contract upgrade).
    address payable public defaultRecipient;

    /// @notice Fast operational guardian. A SINGLE stored address checked by
    ///         `onlyAdminOrOwner` -- NOT an OZ AccessControl role (the vault
    ///         stays single-Owner for configuration). It authorizes the
    ///         operational surface (`setDefaultRecipient` and every `sweep*`
    ///         overload); `setAdmin` itself and UUPS upgrades stay
    ///         `onlyOwner`. MAY equal the owner -- nothing requires the two
    ///         authorities to be distinct. Unset (`address(0)`) until the
    ///         owner appoints one; while unset, `onlyAdminOrOwner` admits
    ///         only the owner.
    address public admin;

    // aderyn-ignore-next-line(unused-state-variable)
    uint256[48] private __gap;

    // ─── Custom errors ──────────────────────────────────────────────────

    error SweepToZero();
    error RBTCSweepFailed();
    error OwnershipCannotBeRenounced();
    error UpgradeImplZero();
    error DefaultRecipientZero();
    error DefaultRecipientUnset();
    error NotAdminOrOwner(address caller); // onlyAdminOrOwner gate
    error AdminZero(); //                     setAdmin(address(0))

    // ─── Modifiers ──────────────────────────────────────────────────────

    /// @dev The `admin` guardian OR the `Ownable2Step` owner. Gates the
    ///      operational surface (`setDefaultRecipient`, `sweep*`); upgrades
    ///      and `setAdmin` stay `onlyOwner`.
    modifier onlyAdminOrOwner() {
        if (msg.sender != admin && msg.sender != owner()) revert NotAdminOrOwner(msg.sender);
        _;
    }

    // ─── Construction / initialization ──────────────────────────────────

    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the proxy. `__Ownable_init` makes the caller the
    ///         initial owner; `newOwner_` decides whether ownership moves
    ///         on immediately or stays with the caller.
    /// @param  newOwner_ Address to take ownership.
    ///         - `address(0)` or `msg.sender`: the caller stays owner, so
    ///           it can set `defaultRecipient` and hand ownership off later.
    ///         - Any other address: ownership transfers immediately and no
    ///           `defaultRecipient` is set here.
    function initialize(address newOwner_) external initializer {
        __Ownable_init();
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        if (newOwner_ != address(0) && newOwner_ != msg.sender) {
            _transferOwnership(newOwner_);
        }
    }

    // ─── Admin role ─────────────────────────────────────────────────────

    /// @notice Appoint (or rotate) the operational guardian checked by
    ///         `onlyAdminOrOwner`. Owner-only. `address(0)` is rejected --
    ///         clearing the guardian would silently drop the fast
    ///         operational path; to disable it, rotate to a held-but-inert
    ///         address instead. MAY equal the owner.
    /// @param  newAdmin Non-zero address.
    // aderyn-ignore-next-line(centralization-risk)
    function setAdmin(address newAdmin) external onlyOwner {
        if (newAdmin == address(0)) revert AdminZero();
        admin = newAdmin;
        emit AdminSet(newAdmin);
    }

    // ─── Default recipient ──────────────────────────────────────────────

    /// @notice Set (or rotate) the default sweep recipient used by the
    ///         no-recipient `sweepERC20(asset, amount)` and `sweepRBTC(amount)`
    ///         overloads. Reverts on `address(0)` -- to "unset" the default,
    ///         leave it at the initial zero state (or upgrade the contract).
    ///         Admin-or-owner: rotating the payout destination is an
    ///         operational move, not a configuration change.
    /// @param  newRecipient Non-zero address.
    // aderyn-ignore-next-line(centralization-risk)
    function setDefaultRecipient(address newRecipient) external onlyAdminOrOwner {
        if (newRecipient == address(0)) revert DefaultRecipientZero();
        address previous = defaultRecipient;
        defaultRecipient = payable(newRecipient);
        emit DefaultRecipientSet(previous, newRecipient);
    }

    // ─── Sweeps ─────────────────────────────────────────────────────────

    /// @inheritdoc IExitFeeVault
    // aderyn-ignore-next-line(centralization-risk)
    function sweepERC20(address asset, address to, uint256 amount) external nonReentrant onlyAdminOrOwner {
        _sweepERC20(asset, to, amount);
    }

    /// @inheritdoc IExitFeeVault
    // aderyn-ignore-next-line(centralization-risk)
    function sweepERC20(address asset, uint256 amount) external nonReentrant onlyAdminOrOwner {
        address recipient = defaultRecipient;
        if (recipient == address(0)) revert DefaultRecipientUnset();
        _sweepERC20(asset, recipient, amount);
    }

    /// @inheritdoc IExitFeeVault
    // aderyn-ignore-next-line(centralization-risk)
    function sweepRBTC(address payable to, uint256 amount) external nonReentrant onlyAdminOrOwner {
        _sweepRBTC(to, amount);
    }

    /// @inheritdoc IExitFeeVault
    // aderyn-ignore-next-line(centralization-risk)
    function sweepRBTC(uint256 amount) external nonReentrant onlyAdminOrOwner {
        address payable recipient = defaultRecipient;
        if (recipient == address(0)) revert DefaultRecipientUnset();
        _sweepRBTC(recipient, amount);
    }

    function _sweepERC20(address asset, address to, uint256 amount) internal {
        if (to == address(0)) revert SweepToZero();
        IERC20(asset).safeTransfer(to, amount);
        emit Swept(asset, to, amount);
    }

    function _sweepRBTC(address payable to, uint256 amount) internal {
        if (to == address(0)) revert SweepToZero();
        // Low-level call so we can forward to either an EOA or a contract.
        // Whole tx reverts on failure so the funds stay in the vault rather
        // than being silently lost.
        // aderyn-ignore-next-line(arbitrary-low-level-call)
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert RBTCSweepFailed();
        emit RBTCSwept(to, amount);
    }

    // ─── Native receive ─────────────────────────────────────────────────

    /// @notice Accepts plain RBTC transfers. Product hooks send the fee leg
    ///         here directly via `feeReceiver.call{value: feeAmount}("")`.
    receive() external payable {}

    // ─── Upgrade authorization (UUPS) ───────────────────────────────────

    // aderyn-ignore-next-line(centralization-risk)
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (newImplementation == address(0)) revert UpgradeImplZero();
    }

    // ─── Disable renounceOwnership ──────────────────────────────────────

    /// @dev Disabled to prevent permanent loss of admin. Without an owner,
    ///      held balances would be locked forever -- no sweeps, no upgrades.
    ///      The 2-step transferOwnership is the only way to move admin.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }
}
