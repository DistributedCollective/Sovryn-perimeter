// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ExitFeeController} from "../../src/ExitFeeController.sol";

/// @dev Test fixture ONLY. NOT a real upgrade candidate.
///      Adds a state variable WITHOUT consuming __gap properly: declares
///      a new uint256 in this child contract, which Solidity places at
///      the END of the inherited storage namespace -- AFTER ExitFeeController's
///      __gap. This means the new variable sits at a slot that was NEVER
///      reserved by the saved layout. tools/check-upgrade-safety.sh must
///      flag this as unsafe.
///
///      Used by tools/test-upgrade-safety-rejects-bad.sh to verify the
///      script's gap-enforcement actually catches a real violation.
contract BadV2 is ExitFeeController {
    // New variable at slot 301 -- OUTSIDE the saved namespace [0, 300].
    // No accompanying __gap reduction. This is exactly what we want to
    // reject.
    uint256 public somethingNew;
}
