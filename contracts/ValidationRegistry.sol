// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IValidationRegistry} from "./IValidationRegistry.sol";

/// @title A local reference implementation of the ERC-8004 Validation Registry.
/// @notice On a live network Syndicate points at the canonical deployment. This
///         exists so the local demo genuinely exercises the standard's call path
///         — request, response, summary — rather than asserting compatibility it
///         never executes. It is a reference implementation, not the registry.
contract ValidationRegistry is IValidationRegistry {
    struct Validation {
        address validatorAddress;
        uint256 agentId;
        uint8 response;
        bytes32 responseHash;
        string tag;
        uint256 lastUpdate;
        bool exists;
    }

    address public immutable identityRegistry;

    mapping(bytes32 => Validation) private _validations;
    mapping(uint256 => bytes32[]) private _byAgent;
    mapping(address => bytes32[]) private _byValidator;

    error UnknownRequest();
    error NotTheValidator();

    constructor(address identityRegistry_) {
        identityRegistry = identityRegistry_;
    }

    function validationRequest(
        address validatorAddress,
        uint256 agentId,
        string calldata requestURI,
        bytes32 requestHash
    ) external {
        Validation storage v = _validations[requestHash];
        if (!v.exists) {
            v.exists = true;
            _byAgent[agentId].push(requestHash);
            _byValidator[validatorAddress].push(requestHash);
        }
        v.validatorAddress = validatorAddress;
        v.agentId = agentId;
        v.lastUpdate = block.timestamp;
        emit ValidationRequest(validatorAddress, agentId, requestURI, requestHash);
    }

    function validationResponse(
        bytes32 requestHash,
        uint8 response,
        string calldata responseURI,
        bytes32 responseHash,
        string calldata tag
    ) external {
        Validation storage v = _validations[requestHash];
        if (!v.exists) revert UnknownRequest();
        if (v.validatorAddress != msg.sender) revert NotTheValidator();

        v.response = response;
        v.responseHash = responseHash;
        v.tag = tag;
        v.lastUpdate = block.timestamp;

        emit ValidationResponse(msg.sender, v.agentId, requestHash, response, responseURI, responseHash, tag);
    }

    function getValidationStatus(bytes32 requestHash)
        external
        view
        returns (address, uint256, uint8, bytes32, string memory, uint256)
    {
        Validation storage v = _validations[requestHash];
        if (!v.exists) revert UnknownRequest();
        return (v.validatorAddress, v.agentId, v.response, v.responseHash, v.tag, v.lastUpdate);
    }

    function getSummary(uint256 agentId, address[] calldata validatorAddresses, string calldata tag)
        external
        view
        returns (uint64 count, uint8 averageResponse)
    {
        bytes32[] storage hashes = _byAgent[agentId];
        uint256 total;
        for (uint256 i; i < hashes.length; ++i) {
            Validation storage v = _validations[hashes[i]];
            if (v.lastUpdate == 0) continue;
            if (bytes(tag).length != 0 && keccak256(bytes(v.tag)) != keccak256(bytes(tag))) continue;
            if (validatorAddresses.length != 0 && !_contains(validatorAddresses, v.validatorAddress)) continue;
            total += v.response;
            count += 1;
        }
        averageResponse = count == 0 ? 0 : uint8(total / count);
    }

    function getAgentValidations(uint256 agentId) external view returns (bytes32[] memory) {
        return _byAgent[agentId];
    }

    function getValidatorRequests(address validatorAddress) external view returns (bytes32[] memory) {
        return _byValidator[validatorAddress];
    }

    function getIdentityRegistry() external view returns (address) {
        return identityRegistry;
    }

    function _contains(address[] calldata haystack, address needle) private pure returns (bool) {
        for (uint256 i; i < haystack.length; ++i) {
            if (haystack[i] == needle) return true;
        }
        return false;
    }
}
