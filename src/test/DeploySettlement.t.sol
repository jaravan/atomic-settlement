// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {DeploySettlement} from "../script/DeploySettlement.s.sol";
import {DvPSettlement} from "../src/DvPSettlement.sol";

/// @notice The settlement script has almost nothing to check; these pin what little it does.
contract DeploySettlementTest is Test {
    DeploySettlement internal script;

    function setUp() public {
        script = new DeploySettlement();
    }

    function test_deploysFreshContract() public {
        DvPSettlement dvp = script.deploy();

        assertEq(dvp.nextTradeId(), 1);
        assertEq(uint8(dvp.trades(1).status), uint8(DvPSettlement.Status.NONE));
    }

    /// @dev Two deploys are two independent instances: separate trade counters.
    function test_eachDeployIsIndependent() public {
        DvPSettlement a = script.deploy();
        DvPSettlement b = script.deploy();

        assertTrue(address(a) != address(b));
        assertEq(a.nextTradeId(), 1);
        assertEq(b.nextTradeId(), 1);
    }
}
