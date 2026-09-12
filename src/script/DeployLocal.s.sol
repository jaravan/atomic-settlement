// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IKYCRegistryV2, Tier} from "kyc-registry/interfaces/IKYCRegistryV2.sol";
import {KYCRegistry} from "kyc-registry/KYCRegistry.sol";
import {KYCRegistryV2} from "kyc-registry/KYCRegistryV2.sol";
import {TokenizedCash} from "../src/TokenizedCash.sol";
import {AssetToken} from "../src/AssetToken.sol";
import {DvPSettlement} from "../src/DvPSettlement.sol";

/// @notice Stands up the whole system on a dev chain: registry, both legs, settlement, two
///         onboarded banks with balances. Every key is a well-known dev key. Never for a
///         network that holds value.
/// @dev The broadcaster is admin of everything and holds every role, the opposite of what
///      both token designs require in section 2. Fine for a sandbox, nowhere else.
contract DeployLocal is Script {
    // Anvil's default accounts 1..4. Account 0 is the broadcaster.
    address internal constant BANK_A = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address internal constant BANK_B = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    bytes32 internal constant ORG = keccak256("SANDBOX_BANK");

    function run() external {
        vm.startBroadcast();
        address me = msg.sender;

        // 1. The registry: V2 implementation behind an ERC-1967 proxy, initialised to us.
        KYCRegistryV2 impl = new KYCRegistryV2();
        KYCRegistryV2 registry =
            KYCRegistryV2(address(new ERC1967Proxy(address(impl), abi.encodeCall(KYCRegistry.initialize, (me)))));
        registry.grantRole(registry.orgOfficerRole(ORG), me);
        registry.grantRole(registry.SANCTIONS_OFFICER_ROLE(), me);

        // 2. The two legs, deployed directly. DeployCash / DeployAsset cannot be reused here:
        //    under broadcast a script becomes a real contract, and one that embeds a token's
        //    creation code is over the EIP-170 size limit. Their checks are for real deploys.
        TokenizedCash cash =
            new TokenizedCash("Tokenized Euro", "tEUR", bytes3("EUR"), IKYCRegistryV2(address(registry)), me);
        AssetToken bond =
            new AssetToken("Bund 2035", "BUND35", bytes12("DE000A1EWWW0"), IKYCRegistryV2(address(registry)), me);
        cash.grantRole(cash.ISSUER_ROLE(), me);
        cash.grantRole(cash.COMPLIANCE_OFFICER_ROLE(), me);
        cash.grantRole(cash.PAUSER_ROLE(), me);
        bond.grantRole(bond.ISSUER_ROLE(), me);
        bond.grantRole(bond.COMPLIANCE_OFFICER_ROLE(), me);
        bond.grantRole(bond.PAUSER_ROLE(), me);

        // 3. Settlement. No configuration: it holds nothing and has no roles.
        DvPSettlement dvp = new DvPSettlement();

        // 4. Policy and onboarding.
        cash.setTierLimits(Tier.INSTITUTIONAL, cash.NO_LIMIT(), cash.NO_LIMIT());
        uint64 expiry = uint64(block.timestamp + 365 days);
        registry.approve(BANK_A, expiry, ORG);
        registry.setTier(BANK_A, Tier.INSTITUTIONAL);
        registry.approve(BANK_B, expiry, ORG);
        registry.setTier(BANK_B, Tier.INSTITUTIONAL);

        // 5. Bank A holds cash, Bank B holds the issue.
        cash.mint(BANK_A, 100_000_000e6);
        bond.mint(BANK_B, 1_000);

        vm.stopBroadcast();

        console2.log("KYCRegistryV2 (proxy) :", address(registry));
        console2.log("TokenizedCash  tEUR   :", address(cash));
        console2.log("AssetToken     BUND35 :", address(bond));
        console2.log("DvPSettlement         :", address(dvp));
        console2.log("");
        console2.log("Bank A (buyer, holds EUR 100m) :", BANK_A);
        console2.log("Bank B (seller, holds 1,000 bonds):", BANK_B);
    }
}
