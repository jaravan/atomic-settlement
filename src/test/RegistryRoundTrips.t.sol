// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Tier} from "kyc-registry/interfaces/IKYCRegistryV2.sol";
import {KYCRegistryFixture} from "./helpers/KYCRegistryFixture.sol";

/// @notice The seven registry calls a settlement makes, in its order, against the real
///         registry -- isolated from everything else so their share can be stated.
contract RegistryRoundTripsTest is KYCRegistryFixture {
    address internal constant SELLER = address(0x5E11);
    address internal constant BUYER = address(0xB0BB);
    address internal constant DVP = address(0xD0D0);

    function setUp() public override {
        super.setUp();
        _onboard(SELLER, Tier.INSTITUTIONAL);
        _onboard(BUYER, Tier.INSTITUTIONAL);
    }

    function test_gas_sevenRoundTrips() public {
        uint256 g = gasleft();
        // cash transferFrom: spender, from, tier(from), to
        registry.isSanctioned(DVP);
        registry.isApproved(BUYER);
        registry.tierOf(BUYER);
        registry.isApproved(SELLER);
        // asset transferFrom: spender, from, to
        registry.isSanctioned(DVP);
        registry.isApproved(SELLER);
        registry.isApproved(BUYER);
        emit log_named_uint("seven round trips, real registry, from cold", g - gasleft());
    }
}
