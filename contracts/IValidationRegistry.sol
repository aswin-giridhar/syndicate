// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ERC-8004 Validation Registry
/// @notice Interface transcribed verbatim from the ERC-8004 specification
///         (https://eips.ethereum.org/EIPS/eip-8004). Syndicate writes to this
///         registry as a validator, so its verdicts are readable by any agent
///         already speaking the standard rather than living in a private silo.
interface IValidationRegistry {
    event ValidationRequest(
        address indexed validatorAddress,
        uint256 indexed agentId,
        string requestURI,
        bytes32 indexed requestHash
    );

    event ValidationResponse(
        address indexed validatorAddress,
        uint256 indexed agentId,
        bytes32 indexed requestHash,
        uint8 response,
        string responseURI,
        bytes32 responseHash,
        string tag
    );

    function validationRequest(
        address validatorAddress,
        uint256 agentId,
        string calldata requestURI,
        bytes32 requestHash
    ) external;

    function validationResponse(
        bytes32 requestHash,
        uint8 response,
        string calldata responseURI,
        bytes32 responseHash,
        string calldata tag
    ) external;

    function getValidationStatus(bytes32 requestHash)
        external
        view
        returns (
            address validatorAddress,
            uint256 agentId,
            uint8 response,
            bytes32 responseHash,
            string memory tag,
            uint256 lastUpdate
        );

    function getSummary(uint256 agentId, address[] calldata validatorAddresses, string calldata tag)
        external
        view
        returns (uint64 count, uint8 averageResponse);

    function getAgentValidations(uint256 agentId) external view returns (bytes32[] memory requestHashes);

    function getValidatorRequests(address validatorAddress) external view returns (bytes32[] memory requestHashes);

    function getIdentityRegistry() external view returns (address identityRegistry);
}
