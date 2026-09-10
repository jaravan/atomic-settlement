// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IKYCRegistryV2, Tier} from "kyc-registry/interfaces/IKYCRegistryV2.sol";

/// @notice Stand-in for the real registry, so a test can set the answers a transfer depends
///         on -- approval, sanctions, tier -- instead of onboarding through the real one.
contract MockKYCRegistry is IKYCRegistryV2 {
    mapping(address account => bool) private _approved;
    mapping(address account => bool) private _sanctioned;
    mapping(address account => Tier) private _tier;

    function setApproved(address account, bool value) external {
        _approved[account] = value;
    }

    function setSanctioned(address account, bool value) external {
        _sanctioned[account] = value;
    }

    function setTier(address account, Tier tier) external {
        _tier[account] = tier;
    }

    /// @dev Sanctioned implies not approved, mirroring the real registry. Without that the
    ///      mock could express a state the registry never produces.
    function isApproved(address account) external view returns (bool) {
        return _approved[account] && !_sanctioned[account];
    }

    function isSanctioned(address account) external view returns (bool) {
        return _sanctioned[account];
    }

    function tierOf(address account) external view returns (Tier) {
        return _tier[account];
    }

    function isAttestedBy(address, bytes32) external pure returns (bool) {
        return false;
    }

    function jurisdictionOf(address) external pure returns (bytes2) {
        return bytes2(0);
    }
}
