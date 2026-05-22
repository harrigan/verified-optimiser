// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @title IERC5732, Commit Interface (ERC-5732 core)
/// @notice Minimal commit-reveal interface for front-running prevention.
///         See https://eips.ethereum.org/EIPS/eip-5732
interface IERC5732 {
    /// @notice Emitted when a commitment is recorded.
    /// @param timePoint Block number at which the commitment was made.
    /// @param from The committer's address.
    /// @param commitment The opaque commitment hash.
    event Commit(uint256 indexed timePoint, address indexed from, bytes32 indexed commitment);

    /// @notice Record a commitment hash on-chain.
    /// @param commitment The opaque commitment hash.
    function commit(bytes32 commitment) external;
}
