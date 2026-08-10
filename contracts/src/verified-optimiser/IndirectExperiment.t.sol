// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Coordinator} from "./Coordinator.sol";
import {NLVerifier} from "./NLVerifier.sol";
import {RiscZeroMockVerifier} from "risc0/test/RiscZeroMockVerifier.sol";
import {Receipt as RiscZeroReceipt} from "risc0/IRiscZeroVerifier.sol";
import {ChainSpec, Encoding, Steel} from "../steel/Steel.sol";
import {Test} from "@forge-std/Test.sol";

/// @notice Gas benchmark for the full indirect verification flow using the
///         NLVerifier with a real NL file (crossing-count K_5).
contract IndirectExperimentTest is Test {
    string constant NL_PATH = "src/verified-optimiser/fixtures/crossing-count-k5.nl";

    address owner;
    address solver;

    function setUp() public {
        // Steel commitment validation resolves the expected config ID from
        // block.chainid; use a chain known to the ChainSpec library.
        vm.chainId(1);

        owner = makeAddr("Owner");
        solver = makeAddr("Solver");
    }

    /// @dev Build a version-0 (block hash) Steel commitment to the previous
    ///      block that passes Steel.validateCommitment.
    function _steelCommitment() internal returns (Steel.Commitment memory) {
        uint256 blockNumber = block.number - 1;
        bytes32 blockHash = keccak256(abi.encodePacked("blockhash", blockNumber));
        vm.setBlockhash(blockNumber, blockHash);
        return Steel.Commitment({
            // forge-lint: disable-next-line(unsafe-typecast)
            id: Encoding.encodeVersionedID(uint240(blockNumber), 0),
            digest: blockHash,
            configID: ChainSpec.configID(block.chainid)
        });
    }

    /// @dev Build a journal matching the coordinator's layout:
    ///      96 bytes Steel commitment (ABI-encoded) +
    ///      8 bytes objective (i64 LE) +
    ///      128 bytes nlFileHash (32 u32 LE words) +
    ///      128 bytes solutionHash (32 u32 LE words).
    function _buildJournal(
        Steel.Commitment memory commitment,
        int64 objective,
        bytes32 nlFileHash,
        bytes32 solutionHash
    ) internal pure returns (bytes memory) {
        bytes memory j = bytes.concat(abi.encode(commitment), new bytes(264));

        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 objBits = uint64(objective);
        for (uint256 i = 0; i < 8; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            j[96 + i] = bytes1(uint8(objBits >> (8 * i)));
        }

        for (uint256 i = 0; i < 32; i++) {
            j[104 + i * 4] = nlFileHash[i];
        }

        for (uint256 i = 0; i < 32; i++) {
            j[232 + i * 4] = solutionHash[i];
        }

        return j;
    }

    function test_benchmark() public {
        bytes memory nl = bytes(vm.readFile(NL_PATH));
        bytes32 nlFileHash = sha256(nl);

        // K_5 convex placement in NL variable order.
        int256[] memory vars = new int256[](10);
        vars[0] = 100;
        vars[1] = 30;
        vars[2] = -80;
        vars[3] = -80;
        vars[4] = 30;
        vars[5] = 0;
        vars[6] = 95;
        vars[7] = 58;
        vars[8] = -58;
        vars[9] = -95;

        int256 expectedObjective = int256(5);

        bytes32 imageId = bytes32(uint256(0x1234));

        vm.deal(owner, 10 ether);
        vm.deal(solver, 10 ether);

        NLVerifier nlVerifier = new NLVerifier();
        RiscZeroMockVerifier mockZk = new RiscZeroMockVerifier(bytes4(0));
        Coordinator coordinator = new Coordinator(nlVerifier, mockZk, imageId);

        // Register problem
        bytes32[] memory blobHashes = new bytes32[](1);
        blobHashes[0] = bytes32(uint256(0xb10b));
        vm.blobhashes(blobHashes);

        uint256 deadline = block.timestamp + 1 days;
        vm.prank(owner);
        uint256 g = gasleft();
        uint256 problemId = coordinator.registerProblem{value: 1 ether}(nlFileHash, true, deadline);
        emit log_named_uint("register_gas", g - gasleft());

        // Commit
        bytes32 salt = bytes32(uint256(42));
        bytes32 solutionHash = sha256(abi.encodePacked(vars));
        bytes32 commitHash = keccak256(abi.encodePacked(problemId, solutionHash, salt));

        vm.prank(solver);
        g = gasleft();
        coordinator.commit(commitHash);
        emit log_named_uint("commit_gas", g - gasleft());

        // Reveals must occur in a strictly later block than the commit.
        vm.roll(block.number + 1);

        // Build mock proof
        bytes memory journal = _buildJournal(
            _steelCommitment(),
            // forge-lint: disable-next-line(unsafe-typecast)
            int64(expectedObjective),
            nlFileHash,
            solutionHash
        );
        RiscZeroReceipt memory receipt = mockZk.mockProve(imageId, sha256(journal));

        // Reveal indirect
        vm.prank(solver);
        g = gasleft();
        coordinator.revealIndirect(problemId, receipt.seal, journal, solutionHash, salt);
        emit log_named_uint("revealIndirect_gas", g - gasleft());

        // Verify state
        (,,,,,, address bestSolver, int256 bestObj, bool hasSolution,) = coordinator.problems(problemId);
        assertEq(bestSolver, solver, "bestSolver should be solver");
        assertEq(bestObj, expectedObjective, "bestObjective should match");
        assertTrue(hasSolution, "hasSolution should be true");

        // Advance past deadline
        vm.warp(deadline + 1);

        // Claim bounty
        uint256 balBefore = solver.balance;
        g = gasleft();
        coordinator.claimBounty(problemId);
        emit log_named_uint("claimBounty_gas", g - gasleft());

        assertEq(solver.balance, balBefore + 1 ether, "solver should receive bounty");
    }
}
