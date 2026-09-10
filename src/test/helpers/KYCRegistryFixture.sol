// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Tier} from "kyc-registry/interfaces/IKYCRegistryV2.sol";
import {KYCRegistry} from "kyc-registry/KYCRegistry.sol";
import {KYCRegistryV2} from "kyc-registry/KYCRegistryV2.sol";

/// @notice The real KYC registry behind a real ERC-1967 proxy, with its roles granted and an
///         onboarding helper. Token-agnostic: every contract that reads the registry can
///         build its own integration suite on top of this.
/// @dev Holds no tests. Extend it, deploy your token in an overridden `setUp`, and use
///      `_onboard` to put an address into the state a real client would be in.
abstract contract KYCRegistryFixture is Test {
    KYCRegistryV2 internal registry;

    address internal constant REGISTRY_ADMIN = address(0xAD3114);
    address internal constant ORG_OFFICER = address(0x0126);
    address internal constant SANCTIONS_OFFICER = address(0x5A17);

    /// @notice The org that vouches for every account onboarded by `_onboard`.
    bytes32 internal constant ORG = keccak256("BANK_A");

    /// @notice Approval expiry used by `_onboard`, one year out from the pinned start time.
    uint64 internal expiry;

    function setUp() public virtual {
        // Pinned so expiry arithmetic is meaningful rather than relative to block zero.
        vm.warp(1_700_000_000);
        expiry = uint64(block.timestamp + 365 days);

        KYCRegistryV2 impl = new KYCRegistryV2();
        registry = KYCRegistryV2(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(KYCRegistry.initialize, (REGISTRY_ADMIN))))
        );

        bytes32 orgRole = registry.orgOfficerRole(ORG);
        bytes32 sanctionsRole = registry.SANCTIONS_OFFICER_ROLE();
        vm.startPrank(REGISTRY_ADMIN);
        registry.grantRole(orgRole, ORG_OFFICER);
        registry.grantRole(sanctionsRole, SANCTIONS_OFFICER);
        vm.stopPrank();
    }

    /// @dev The real onboarding sequence: the owning org approves, then classifies.
    function _onboard(address account, Tier tier) internal {
        vm.startPrank(ORG_OFFICER);
        registry.approve(account, expiry, ORG);
        registry.setTier(account, tier);
        vm.stopPrank();
    }
}
