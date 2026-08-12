// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ExitFeeVault} from "../../src/ExitFeeVault.sol";

/// @dev V2 mock used to prove UUPS upgrades preserve storage and admit a new
///      public function. Same pattern as the controller's V2 mock.
contract ExitFeeVaultV2Mock is ExitFeeVault {
    function version() external pure returns (string memory) {
        return "v2";
    }
}

/// @dev Minimal ERC20 used to test sweepERC20 without pulling a stablecoin
///      mock. Mints to whomever the test asks.
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ExitFeeVaultTest is Test {
    // Event signatures redeclared locally so `vm.expectEmit` can resolve them.
    // Solidity 0.8.20 doesn't support `emit InterfaceName.EventName` (that
    // landed in 0.8.21). These declarations must match IExitFeeVault.sol
    // exactly -- signature hash mismatch would silently break the assertion.
    event Swept(address indexed asset, address indexed to, uint256 amount);
    event RBTCSwept(address indexed to, uint256 amount);
    event AdminSet(address indexed admin);

    ExitFeeVault vault;
    MockERC20 token;

    // NOTE: `ADMIN` predates the contract's admin role -- it is the proxy
    // OWNER throughout this file. The operational guardian stored in
    // `ExitFeeVault.admin` is `GUARDIAN` below.
    address constant ADMIN = address(0xA1);
    address constant GUARDIAN = address(0xAD);
    address constant RECIPIENT = address(0xBE);
    address constant OUTSIDER = address(0xC0);

    function setUp() public {
        ExitFeeVault impl = new ExitFeeVault();
        bytes memory init = abi.encodeWithSelector(ExitFeeVault.initialize.selector, ADMIN);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        vault = ExitFeeVault(payable(address(proxy)));

        token = new MockERC20();
    }

    // ─── Initialization ──────────────────────────────────────────────────

    function test_constructor_disables_initializers() public {
        ExitFeeVault freshImpl = new ExitFeeVault();
        vm.expectRevert("Initializable: contract is already initialized");
        freshImpl.initialize(ADMIN);
    }

    function test_initialize_zero_newOwner_keeps_deployer_as_owner() public {
        // Sentinel behavior: passing address(0) means "leave deployer
        // (msg.sender at init time) as owner" -- used by the bootstrap
        // flow to defer the Safe handoff until defaultRecipient is set.
        ExitFeeVault freshImpl = new ExitFeeVault();
        bytes memory init = abi.encodeWithSelector(ExitFeeVault.initialize.selector, address(0));
        ERC1967Proxy proxy = new ERC1967Proxy(address(freshImpl), init);
        ExitFeeVault freshVault = ExitFeeVault(payable(address(proxy)));
        // This test contract is the deployer here (no vm.prank), so it
        // should be the initial owner.
        assertEq(freshVault.owner(), address(this));
    }

    function test_initialize_msg_sender_keeps_deployer_as_owner() public {
        // Same sentinel behavior when caller passes themselves explicitly.
        ExitFeeVault freshImpl = new ExitFeeVault();
        bytes memory init = abi.encodeWithSelector(ExitFeeVault.initialize.selector, address(this));
        ERC1967Proxy proxy = new ERC1967Proxy(address(freshImpl), init);
        ExitFeeVault freshVault = ExitFeeVault(payable(address(proxy)));
        assertEq(freshVault.owner(), address(this));
    }

    function test_initialize_other_owner_transfers_immediately() public {
        // Legacy "Safe is owner from deploy" path: passing a non-zero,
        // non-self address triggers the immediate _transferOwnership.
        ExitFeeVault freshImpl = new ExitFeeVault();
        bytes memory init = abi.encodeWithSelector(ExitFeeVault.initialize.selector, ADMIN);
        ERC1967Proxy proxy = new ERC1967Proxy(address(freshImpl), init);
        ExitFeeVault freshVault = ExitFeeVault(payable(address(proxy)));
        assertEq(freshVault.owner(), ADMIN);
    }

    function test_owner_set_after_initialize() public view {
        assertEq(vault.owner(), ADMIN);
    }

    // ─── ERC20 sweep ─────────────────────────────────────────────────────

    function test_owner_can_sweep_erc20() public {
        token.mint(address(vault), 1_000);

        vm.prank(ADMIN);
        vault.sweepERC20(address(token), RECIPIENT, 400);

        assertEq(token.balanceOf(address(vault)), 600);
        assertEq(token.balanceOf(RECIPIENT), 400);
    }

    function test_stranger_cannot_sweep_erc20() public {
        token.mint(address(vault), 1_000);
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(ExitFeeVault.NotAdminOrOwner.selector, OUTSIDER));
        vault.sweepERC20(address(token), RECIPIENT, 400);
    }

    function test_sweep_erc20_to_zero_reverts() public {
        token.mint(address(vault), 1_000);
        vm.prank(ADMIN);
        vm.expectRevert(ExitFeeVault.SweepToZero.selector);
        vault.sweepERC20(address(token), address(0), 400);
    }

    function test_sweep_erc20_emits_event() public {
        token.mint(address(vault), 1_000);
        vm.prank(ADMIN);
        vm.expectEmit(true, true, false, true, address(vault));
        emit Swept(address(token), RECIPIENT, 400);
        vault.sweepERC20(address(token), RECIPIENT, 400);
    }

    // ─── Native RBTC sweep ───────────────────────────────────────────────

    function test_vault_accepts_native_via_receive() public {
        // Vault must accept RBTC sent without calldata so the product hook
        // can `to.call{value: ...}("")` the fee leg directly to the vault.
        vm.deal(OUTSIDER, 5 ether);
        vm.prank(OUTSIDER);
        (bool ok,) = address(vault).call{value: 5 ether}("");
        assertTrue(ok);
        assertEq(address(vault).balance, 5 ether);
    }

    function test_owner_can_sweep_rbtc() public {
        vm.deal(address(vault), 5 ether);

        vm.prank(ADMIN);
        vault.sweepRBTC(payable(RECIPIENT), 2 ether);

        assertEq(address(vault).balance, 3 ether);
        assertEq(RECIPIENT.balance, 2 ether);
    }

    function test_stranger_cannot_sweep_rbtc() public {
        vm.deal(address(vault), 5 ether);
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(ExitFeeVault.NotAdminOrOwner.selector, OUTSIDER));
        vault.sweepRBTC(payable(RECIPIENT), 2 ether);
    }

    function test_sweep_rbtc_to_zero_reverts() public {
        vm.deal(address(vault), 5 ether);
        vm.prank(ADMIN);
        vm.expectRevert(ExitFeeVault.SweepToZero.selector);
        vault.sweepRBTC(payable(address(0)), 2 ether);
    }

    function test_sweep_rbtc_failed_recipient_reverts() public {
        // A recipient whose receive() reverts must cause sweep to revert
        // with RBTCSweepFailed (not silently leave the funds in vault).
        RevertingReceiver bad = new RevertingReceiver();
        vm.deal(address(vault), 5 ether);
        vm.prank(ADMIN);
        vm.expectRevert(ExitFeeVault.RBTCSweepFailed.selector);
        vault.sweepRBTC(payable(address(bad)), 2 ether);

        // The point of reverting is that the funds stay put.
        assertEq(address(vault).balance, 5 ether, "failed sweep must not move funds");
        assertEq(address(bad).balance, 0);
    }

    function test_sweep_rbtc_emits_event() public {
        vm.deal(address(vault), 5 ether);
        vm.prank(ADMIN);
        vm.expectEmit(true, false, false, true, address(vault));
        emit RBTCSwept(RECIPIENT, 2 ether);
        vault.sweepRBTC(payable(RECIPIENT), 2 ether);
    }

    // ─── Reentrancy guard ────────────────────────────────────────────────

    /// @dev Fresh `ReenteringReceiver` wired as BOTH the vault's `admin` and
    ///      its `defaultRecipient`, with the vault seeded in native and
    ///      tokens. Being `admin` is the load-bearing part: it lets the
    ///      re-entrant call clear `onlyAdminOrOwner` on its own merits, so
    ///      `nonReentrant` is the only thing left that can stop it. Against a
    ///      non-privileged attacker every one of these tests would still see
    ///      a revert with the guard removed, and could never fail.
    function _seedAttacker() private returns (ReenteringReceiver attacker) {
        attacker = new ReenteringReceiver(vault, address(token));

        vm.startPrank(ADMIN);
        vault.setAdmin(address(attacker));
        vault.setDefaultRecipient(address(attacker));
        vm.stopPrank();

        vm.deal(address(vault), 5 ether);
        token.mint(address(vault), 1_000);
    }

    /// @dev `__ReentrancyGuard_init()` must actually run on the proxy. No
    ///      behavioral test can prove that: OZ 4.9 checks
    ///      `_status != _ENTERED (2)`, so an uninitialized `_status == 0`
    ///      still blocks re-entry -- a vault that skipped the init would pass
    ///      every test below and only differ in first-entry gas. The
    ///      initialized state is observable in storage alone: slot 251 is
    ///      `ReentrancyGuardUpgradeable._status` (per
    ///      `forge inspect ExitFeeVault storageLayout`; see the layout map in
    ///      ExitFeeVault.sol) and must read `_NOT_ENTERED == 1`.
    function test_reentrancy_guard_initialized_on_proxy() public view {
        uint256 status = uint256(vm.load(address(vault), bytes32(uint256(251))));
        assertEq(status, 1, "guard must be _NOT_ENTERED, not the zero a skipped init leaves");
    }

    function test_sweepRBTC_reentrancy_guard_blocks_reentrant_sweep() public {
        ReenteringReceiver attacker = _seedAttacker();

        // Negative control, same fixture, re-entry disarmed: the sweep must
        // go through. Without it the test could not tell "the guard fired"
        // from "sweeping to this recipient is simply broken" -- both surface
        // as the same RBTCSweepFailed.
        attacker.arm(ReenteringReceiver.Mode.NONE);
        vm.prank(ADMIN);
        vault.sweepRBTC(payable(address(attacker)), 1 ether);
        assertEq(address(vault).balance, 4 ether, "disarmed sweep must go through");
        assertEq(address(attacker).balance, 1 ether);

        // Armed: receive() calls straight back into sweepRBTC. nonReentrant
        // rejects the inner call, that revert propagates out of receive(),
        // and the vault reports the failed transfer as RBTCSweepFailed.
        attacker.arm(ReenteringReceiver.Mode.SWEEP_RBTC);
        vm.prank(ADMIN);
        vm.expectRevert(ExitFeeVault.RBTCSweepFailed.selector);
        vault.sweepRBTC(payable(address(attacker)), 1 ether);

        // Reverting is what keeps the funds in place -- including the outer
        // leg the attacker had already received before re-entering.
        assertEq(address(vault).balance, 4 ether, "reentrant sweep must not move funds");
        assertEq(address(attacker).balance, 1 ether);
    }

    function test_sweepRBTC_default_reentrancy_guard_blocks_reentrant_sweep() public {
        // Same attack through the no-recipient overload, which carries its
        // own nonReentrant. _seedAttacker made the attacker the
        // defaultRecipient, so both legs route to it.
        ReenteringReceiver attacker = _seedAttacker();
        attacker.arm(ReenteringReceiver.Mode.SWEEP_RBTC_DEFAULT);

        vm.prank(ADMIN);
        vm.expectRevert(ExitFeeVault.RBTCSweepFailed.selector);
        vault.sweepRBTC(1 ether);

        assertEq(address(vault).balance, 5 ether, "reentrant sweep must not move funds");
        assertEq(address(attacker).balance, 0);
    }

    function test_sweepERC20_reentrancy_guard_blocks_cross_function_reentry() public {
        // The guard is a single shared flag, so the in-flight RBTC sweep
        // already holds it when receive() reaches across for sweepERC20.
        // That is what covers the ERC20 overloads' own nonReentrant: drop it
        // from either side of this pair and the re-entry lands.
        ReenteringReceiver attacker = _seedAttacker();
        attacker.arm(ReenteringReceiver.Mode.SWEEP_ERC20);

        vm.prank(ADMIN);
        vm.expectRevert(ExitFeeVault.RBTCSweepFailed.selector);
        vault.sweepRBTC(payable(address(attacker)), 1 ether);

        assertEq(token.balanceOf(address(vault)), 1_000, "reentrant sweep must not move tokens");
        assertEq(token.balanceOf(address(attacker)), 0);
        assertEq(address(vault).balance, 5 ether);
    }

    function test_sweepERC20_default_reentrancy_guard_blocks_cross_function_reentry() public {
        ReenteringReceiver attacker = _seedAttacker();
        attacker.arm(ReenteringReceiver.Mode.SWEEP_ERC20_DEFAULT);

        vm.prank(ADMIN);
        vm.expectRevert(ExitFeeVault.RBTCSweepFailed.selector);
        vault.sweepRBTC(payable(address(attacker)), 1 ether);

        assertEq(token.balanceOf(address(vault)), 1_000, "reentrant sweep must not move tokens");
        assertEq(token.balanceOf(address(attacker)), 0);
        assertEq(address(vault).balance, 5 ether);
    }

    // ─── UUPS upgrade ────────────────────────────────────────────────────

    function test_owner_can_upgrade_through_proxy() public {
        // Pre-load the vault's OWN storage -- defaultRecipient (slot 301) and
        // admin (slot 302). These are the slots an impl swap could actually
        // shift; balances below are account state and would survive any impl.
        vm.startPrank(ADMIN);
        vault.setDefaultRecipient(RECIPIENT);
        vault.setAdmin(GUARDIAN);
        vm.stopPrank();

        token.mint(address(vault), 1_000);
        vm.deal(address(vault), 3 ether);

        ExitFeeVaultV2Mock v2impl = new ExitFeeVaultV2Mock();
        vm.prank(ADMIN);
        vault.upgradeTo(address(v2impl));

        // New function reachable at the same proxy address.
        ExitFeeVaultV2Mock asV2 = ExitFeeVaultV2Mock(payable(address(vault)));
        assertEq(asV2.version(), "v2");

        // Balances preserved (vault state is not in slots; balances are part
        // of the proxy's account state and unaffected by impl swap -- this
        // is mostly a sanity check that the upgrade didn't break anything).
        assertEq(token.balanceOf(address(vault)), 1_000);
        assertEq(address(vault).balance, 3 ether);

        // Owner preserved, and so is the vault's own-slot state.
        assertEq(vault.owner(), ADMIN);
        assertEq(vault.defaultRecipient(), RECIPIENT);
        assertEq(vault.admin(), GUARDIAN);

        // Sweep still works through the upgraded impl.
        vm.prank(ADMIN);
        vault.sweepERC20(address(token), RECIPIENT, 200);
        assertEq(token.balanceOf(RECIPIENT), 200);
    }

    function test_non_owner_cannot_upgrade() public {
        ExitFeeVaultV2Mock v2impl = new ExitFeeVaultV2Mock();
        vm.prank(OUTSIDER);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.upgradeTo(address(v2impl));
    }

    function test_upgrade_to_zero_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(ExitFeeVault.UpgradeImplZero.selector);
        vault.upgradeTo(address(0));
    }

    // ─── renounceOwnership lockout ───────────────────────────────────────

    function test_renounce_ownership_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(ExitFeeVault.OwnershipCannotBeRenounced.selector);
        vault.renounceOwnership();
        assertEq(vault.owner(), ADMIN);
    }

    // ─── Ownable2Step transfer flow ──────────────────────────────────────

    function test_transferOwnership_two_step_flow() public {
        // Step 1: current owner nominates; ownership does NOT move yet.
        vm.prank(ADMIN);
        vault.transferOwnership(OUTSIDER);
        assertEq(vault.owner(), ADMIN);
        assertEq(vault.pendingOwner(), OUTSIDER);

        // Step 2: nominee accepts; ownership moves and pending clears.
        vm.prank(OUTSIDER);
        vault.acceptOwnership();
        assertEq(vault.owner(), OUTSIDER);
        assertEq(vault.pendingOwner(), address(0));
    }

    function test_acceptOwnership_non_pending_reverts() public {
        vm.prank(ADMIN);
        vault.transferOwnership(OUTSIDER);

        vm.prank(RECIPIENT);
        vm.expectRevert("Ownable2Step: caller is not the new owner");
        vault.acceptOwnership();

        // Nothing moved: owner and nominee are unchanged.
        assertEq(vault.owner(), ADMIN);
        assertEq(vault.pendingOwner(), OUTSIDER);
    }

    // ─── Default recipient + no-recipient sweep overloads ────────────────

    event DefaultRecipientSet(address indexed previous, address indexed current);

    function test_default_recipient_unset_at_init() public view {
        assertEq(vault.defaultRecipient(), address(0));
    }

    function test_setDefaultRecipient_zero_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(ExitFeeVault.DefaultRecipientZero.selector);
        vault.setDefaultRecipient(address(0));
    }

    function test_setDefaultRecipient_stranger_reverts() public {
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(ExitFeeVault.NotAdminOrOwner.selector, OUTSIDER));
        vault.setDefaultRecipient(RECIPIENT);
    }

    function test_setDefaultRecipient_sets_and_emits() public {
        vm.expectEmit(true, true, false, false);
        emit DefaultRecipientSet(address(0), RECIPIENT);
        vm.prank(ADMIN);
        vault.setDefaultRecipient(RECIPIENT);

        assertEq(vault.defaultRecipient(), RECIPIENT);
    }

    function test_setDefaultRecipient_rotates() public {
        address NEXT = address(0xBE2);

        vm.prank(ADMIN);
        vault.setDefaultRecipient(RECIPIENT);

        vm.expectEmit(true, true, false, false);
        emit DefaultRecipientSet(RECIPIENT, NEXT);
        vm.prank(ADMIN);
        vault.setDefaultRecipient(NEXT);

        assertEq(vault.defaultRecipient(), NEXT);
    }

    function test_sweepERC20_default_unset_reverts() public {
        token.mint(address(vault), 1_000);
        vm.prank(ADMIN);
        vm.expectRevert(ExitFeeVault.DefaultRecipientUnset.selector);
        vault.sweepERC20(address(token), 100);
    }

    function test_sweepERC20_default_recipient() public {
        token.mint(address(vault), 1_000);

        vm.prank(ADMIN);
        vault.setDefaultRecipient(RECIPIENT);

        vm.prank(ADMIN);
        vault.sweepERC20(address(token), 100);

        assertEq(token.balanceOf(RECIPIENT), 100);
        assertEq(token.balanceOf(address(vault)), 900);
    }

    function test_sweepERC20_default_stranger_reverts() public {
        vm.prank(ADMIN);
        vault.setDefaultRecipient(RECIPIENT);

        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(ExitFeeVault.NotAdminOrOwner.selector, OUTSIDER));
        vault.sweepERC20(address(token), 100);
    }

    function test_sweepRBTC_default_unset_reverts() public {
        vm.deal(address(vault), 10 ether);
        vm.prank(ADMIN);
        vm.expectRevert(ExitFeeVault.DefaultRecipientUnset.selector);
        vault.sweepRBTC(1 ether);
    }

    function test_sweepRBTC_default_recipient() public {
        vm.deal(address(vault), 10 ether);

        vm.prank(ADMIN);
        vault.setDefaultRecipient(RECIPIENT);

        uint256 balBefore = RECIPIENT.balance;
        vm.prank(ADMIN);
        vault.sweepRBTC(1 ether);

        assertEq(RECIPIENT.balance, balBefore + 1 ether);
        assertEq(address(vault).balance, 9 ether);
    }

    function test_sweepRBTC_default_stranger_reverts() public {
        vm.prank(ADMIN);
        vault.setDefaultRecipient(RECIPIENT);
        vm.deal(address(vault), 10 ether);

        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(ExitFeeVault.NotAdminOrOwner.selector, OUTSIDER));
        vault.sweepRBTC(1 ether);
    }

    function test_explicit_sweep_ignores_default_recipient() public {
        // Even when defaultRecipient is set, the 3-arg / 2-arg overloads
        // honor their explicit `to` and route there.
        address OTHER = address(0xBE3);
        token.mint(address(vault), 1_000);

        vm.prank(ADMIN);
        vault.setDefaultRecipient(RECIPIENT);

        vm.prank(ADMIN);
        vault.sweepERC20(address(token), OTHER, 100);

        assertEq(token.balanceOf(OTHER), 100);
        assertEq(token.balanceOf(RECIPIENT), 0, "default not used when explicit recipient given");
    }

    // ─── Admin role (operational guardian) ───────────────────────────────

    function test_admin_unset_at_init() public view {
        assertEq(vault.admin(), address(0));
    }

    function test_setAdmin_sets_and_emits() public {
        vm.expectEmit(true, false, false, false, address(vault));
        emit AdminSet(GUARDIAN);
        vm.prank(ADMIN);
        vault.setAdmin(GUARDIAN);

        assertEq(vault.admin(), GUARDIAN);
    }

    function test_setAdmin_non_owner_reverts() public {
        // setAdmin stays owner-only -- the guardian cannot appoint itself
        // or a successor.
        vm.prank(OUTSIDER);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.setAdmin(GUARDIAN);
    }

    function test_setAdmin_zero_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(ExitFeeVault.AdminZero.selector);
        vault.setAdmin(address(0));
    }

    function test_setAdmin_may_equal_owner() public {
        // admin == owner is a supported shape: one address may hold both roles.
        vm.prank(ADMIN);
        vault.setAdmin(ADMIN);
        assertEq(vault.admin(), ADMIN);
    }

    function test_admin_can_setDefaultRecipient() public {
        vm.prank(ADMIN);
        vault.setAdmin(GUARDIAN);

        vm.prank(GUARDIAN);
        vault.setDefaultRecipient(RECIPIENT);
        assertEq(vault.defaultRecipient(), RECIPIENT);
    }

    function test_admin_can_sweep_erc20_explicit() public {
        token.mint(address(vault), 1_000);
        vm.prank(ADMIN);
        vault.setAdmin(GUARDIAN);

        vm.prank(GUARDIAN);
        vault.sweepERC20(address(token), RECIPIENT, 400);

        assertEq(token.balanceOf(RECIPIENT), 400);
        assertEq(token.balanceOf(address(vault)), 600);
    }

    function test_admin_can_sweep_erc20_default() public {
        token.mint(address(vault), 1_000);
        vm.prank(ADMIN);
        vault.setAdmin(GUARDIAN);

        vm.prank(GUARDIAN);
        vault.setDefaultRecipient(RECIPIENT);
        vm.prank(GUARDIAN);
        vault.sweepERC20(address(token), 100);

        assertEq(token.balanceOf(RECIPIENT), 100);
    }

    function test_admin_can_sweep_rbtc_explicit() public {
        vm.deal(address(vault), 5 ether);
        vm.prank(ADMIN);
        vault.setAdmin(GUARDIAN);

        vm.prank(GUARDIAN);
        vault.sweepRBTC(payable(RECIPIENT), 2 ether);

        assertEq(RECIPIENT.balance, 2 ether);
        assertEq(address(vault).balance, 3 ether);
    }

    function test_admin_can_sweep_rbtc_default() public {
        vm.deal(address(vault), 5 ether);
        vm.prank(ADMIN);
        vault.setAdmin(GUARDIAN);

        vm.prank(GUARDIAN);
        vault.setDefaultRecipient(RECIPIENT);
        uint256 balBefore = RECIPIENT.balance;
        vm.prank(GUARDIAN);
        vault.sweepRBTC(1 ether);

        assertEq(RECIPIENT.balance, balBefore + 1 ether);
        assertEq(address(vault).balance, 4 ether);
    }

    function test_admin_cannot_touch_owner_only_surfaces() public {
        // The admin's authority is BOUNDED to the operational surface.
        // Owner-only: rotating the admin itself and UUPS upgrades.
        vm.prank(ADMIN);
        vault.setAdmin(GUARDIAN);

        vm.prank(GUARDIAN);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.setAdmin(OUTSIDER);

        ExitFeeVaultV2Mock v2 = new ExitFeeVaultV2Mock();
        vm.prank(GUARDIAN);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.upgradeTo(address(v2));
    }

    // ─── Fuzz: sweep monotonicity ────────────────────────────────────────

    /// @dev Property: no address other than the owner (or an appointed
    ///      admin -- unset in this fixture, and `attacker != address(0)`
    ///      excludes the unset sentinel) can decrease the vault's native
    ///      balance via sweepRBTC. Asserted across a fuzzed `attacker`
    ///      (any EOA-like address) and `amount` (any value, even one larger
    ///      than the vault's balance -- the revert fires before any
    ///      balance check). Counterpart unit test:
    ///      `test_stranger_cannot_sweep_rbtc`.
    function testFuzz_sweepRBTC_only_owner_decreases_balance(address attacker, uint256 amount) public {
        vm.assume(attacker != ADMIN);
        vm.assume(attacker != address(0));
        // Skip contract addresses to avoid `expectRevert` swallowing a
        // fallback() revert from the attacker contract itself rather than
        // the Ownable check we want to observe.
        vm.assume(attacker.code.length == 0);

        // Seed the vault with native so a successful sweep WOULD measurably
        // change balance -- makes the "balance unchanged" assertion meaningful.
        vm.deal(address(vault), 10 ether);
        uint256 balBefore = address(vault).balance;

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ExitFeeVault.NotAdminOrOwner.selector, attacker));
        vault.sweepRBTC(payable(attacker), amount);

        assertEq(address(vault).balance, balBefore, "non-owner must not move balance");
    }
}

/// @dev Test fixture: a contract that always rejects native RBTC. Used to
///      exercise the sweepRBTC failure path.
contract RevertingReceiver {
    receive() external payable {
        revert("nope");
    }
}

/// @dev Test fixture: a sweep recipient that calls back into the vault from
///      its `receive()`, to prove `nonReentrant` on the `sweep*` overloads
///      actually engages. Tests appoint it the vault's `admin` so the
///      re-entrant call passes `onlyAdminOrOwner` and the guard is the only
///      thing standing in its way.
///
///      Re-entry is attempted at most ONCE per outer sweep (`attempted`).
///      Unbounded recursion would exhaust the gas and revert the outer call
///      for that reason alone, which would make an unguarded vault look
///      exactly like a guarded one.
contract ReenteringReceiver {
    /// @dev Which vault entry point `receive()` calls back into. `NONE`
    ///      makes this a plain, well-behaved recipient -- the negative
    ///      control that shows the sweep path itself is sound.
    enum Mode {
        NONE,
        SWEEP_RBTC,
        SWEEP_RBTC_DEFAULT,
        SWEEP_ERC20,
        SWEEP_ERC20_DEFAULT
    }

    ExitFeeVault public vault;
    address public token;
    Mode public mode;
    bool private attempted;

    constructor(ExitFeeVault vault_, address token_) {
        vault = vault_;
        token = token_;
    }

    /// @notice Select the re-entry target and re-arm the one-shot latch.
    function arm(Mode mode_) external {
        mode = mode_;
        attempted = false;
    }

    receive() external payable {
        if (mode == Mode.NONE || attempted) return;
        attempted = true;

        if (mode == Mode.SWEEP_RBTC) {
            vault.sweepRBTC(payable(address(this)), msg.value);
        } else if (mode == Mode.SWEEP_RBTC_DEFAULT) {
            vault.sweepRBTC(msg.value);
        } else if (mode == Mode.SWEEP_ERC20) {
            vault.sweepERC20(token, address(this), 1);
        } else {
            vault.sweepERC20(token, 1);
        }
    }
}
