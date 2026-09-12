// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {DvPSettlement} from "../src/DvPSettlement.sol";

/// @notice Deploys DvPSettlement. It takes no configuration and has no roles (settlement
///         section 9), so this script's job is the broadcast record and a post-deploy check.
/// @dev Not bound to any token: each trade names its own legs. Deploy once per chain.
contract DeploySettlement is Script {
    function run() external returns (DvPSettlement dvp) {
        vm.startBroadcast();
        dvp = deploy();
        vm.stopBroadcast();

        console2.log("DvPSettlement :", address(dvp));
        console2.log("");
        console2.log("Nothing to configure. Each proposal names its own cash and asset token,");
        console2.log("and settle verifies their currency and ISIN against the trade.");
    }

    /// @notice Deploy and confirm fresh state. Public so tests drive it without broadcasting.
    function deploy() public returns (DvPSettlement dvp) {
        dvp = new DvPSettlement();

        require(dvp.nextTradeId() == 1, "not a fresh deployment");
        require(address(dvp).code.length > 0, "no code at address");
    }
}
