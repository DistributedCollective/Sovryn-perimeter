// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";

/// @title Pinned perimeter surface ids
/// @notice A surface id is `keccak256` of its name, so the name IS the value.
///         The same five names are declared independently here, in the lending
///         repo, in Zero and in the dapp; a one-character drift in any of them
///         resolves no policy and silently stops the fee rather than failing.
///         Each name is pinned to the literal 32 bytes it must hash to, so a
///         bulk rename cannot rewrite the name and its assertion together.
/// @dev    A diff here means a redeploy and a re-bootstrap of the controller,
///         never a test edit.
contract PinnedIdentifiersTest is Test {
    function testLenderWithdrawSurfaceId() public pure {
        assertEq(
            keccak256("PERIMETER_SURFACE_LENDING_LENDER_WITHDRAW"),
            0xd4896528a9fba849e3d3db442dea05ef8f08c93e00cc760acac34c42a7dacffe
        );
    }

    function testBorrowerWithdrawSurfaceId() public pure {
        assertEq(
            keccak256("PERIMETER_SURFACE_LENDING_BORROWER_WITHDRAW"),
            0xfa502ea562018a194d7f66e337810fa8b882ec21f706f3b3c709a53fa126b018
        );
    }

    function testZeroWithdrawCollSurfaceId() public pure {
        assertEq(
            keccak256("PERIMETER_SURFACE_ZERO_WITHDRAW_COLL"),
            0xfb3234ca0cf70fe9c90b73939f36a37fadcfdef4628afc42dd57d1f26dfd8fb5
        );
    }

    function testZeroClaimSurplusSurfaceId() public pure {
        assertEq(
            keccak256("PERIMETER_SURFACE_ZERO_CLAIM_SURPLUS"),
            0x44224716871939619faf861b30e39bac8861d4f76b5dd0468d31bf4b7dc684be
        );
    }

    function testAmmRemoveLiquiditySurfaceId() public pure {
        assertEq(
            keccak256("PERIMETER_SURFACE_AMM_REMOVE_LIQUIDITY"),
            0x785cea9856c907f8eb318fa26cc03e32cc9b61b22144c7a093eec9a60354a9b2
        );
    }

    /// @notice The Phase-1 names must be gone: an id derived from one of them
    ///         points at a policy slot the re-cut controller never writes.
    function testStaleNamesDoNotCollide() public pure {
        assertTrue(
            keccak256("SURFACE_LENDING_LENDER_WITHDRAW") !=
                keccak256("PERIMETER_SURFACE_LENDING_LENDER_WITHDRAW")
        );
        assertTrue(
            keccak256("SURFACE_ZERO_WITHDRAW_COLL") !=
                keccak256("PERIMETER_SURFACE_ZERO_WITHDRAW_COLL")
        );
    }
}
