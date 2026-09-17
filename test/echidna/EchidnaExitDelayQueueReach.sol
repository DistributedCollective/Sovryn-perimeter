// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {EchidnaExitDelayQueue} from "./EchidnaExitDelayQueue.sol";

/// @dev Non-vacuity gate for the property harness. Every operator-lever property
///      on the base contract is phrased as "this never happened", which a
///      campaign that never enters the guarded path satisfies for free. This
///      contract inherits all of them unchanged and adds one property that is
///      TRUE until the campaign has driven every lever, so a healthy run must
///      report `echidna_levers_not_reached` FALSIFIED while every inherited
///      property still passes. A run in which it stays passing did not reach the
///      paths the other properties guard and certifies nothing.
///
///      Run it as its own campaign (tools/release-gates.sh, phase `reach`);
///      the base contract stays the one the release-scale campaign targets.
contract EchidnaExitDelayQueueReach is EchidnaExitDelayQueue {
    constructor() payable {}

    function echidna_levers_not_reached() external view returns (bool) {
        return !leversReached();
    }
}
