// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Coordinator} from "./Coordinator.sol";
import {NLVerifier} from "./NLVerifier.sol";
import {RiscZeroMockVerifier} from "risc0/test/RiscZeroMockVerifier.sol";
import {Receipt as RiscZeroReceipt} from "risc0/IRiscZeroVerifier.sol";
import {Test} from "@forge-std/Test.sol";

contract CoordinatorTest is Test {
    Coordinator coordinator;
    NLVerifier nlVerifier;
    RiscZeroMockVerifier mockZk;
    bytes32 imageId;

    address alice;
    address bob;
    address carol;

    /// @dev "min x, s.t. x >= 5", bounds -100 <= x <= 100.
    bytes constant NL_MIN_X = "g3 0 1 0\n" " 1 1 1 0 0\n" " 1 1\n" " 0 0\n" " 1 1 1\n" " 0 0 0 1\n" " 0 0 1 0 0\n"
        " 1 1\n" " 0 0\n" " 0 0 0 0 0\n" "b\n" "0 -100 100\n" "r\n" "2 5\n" "C0\n" "v0\n" "O0 0\n" "v0\n" "k0\n";

    bytes32 immutable NL_MIN_X_HASH = sha256(NL_MIN_X);

    function setUp() public {
        imageId = bytes32(uint256(0x1234));
        nlVerifier = new NLVerifier();
        mockZk = new RiscZeroMockVerifier(bytes4(0));
        coordinator = new Coordinator(nlVerifier, mockZk, imageId);

        alice = makeAddr("Alice");
        bob = makeAddr("Bob");
        carol = makeAddr("Carol");

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);
    }

    bytes32 constant MOCK_BLOB_HASH = bytes32(uint256(0xb10b));

    function _setBlobHash() internal {
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = MOCK_BLOB_HASH;
        vm.blobhashes(hashes);
    }

    function _registerProblem(address sender, uint256 value, uint256 deadline) internal returns (uint256) {
        _setBlobHash();
        vm.prank(sender);
        return coordinator.registerProblem{value: value}(NL_MIN_X_HASH, true, deadline);
    }

    function _makeVars(int256 v) internal pure returns (int256[] memory) {
        int256[] memory vars = new int256[](1);
        vars[0] = v;
        return vars;
    }

    function _commitHash(uint256 problemId, int256[] memory vars, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(problemId, sha256(abi.encodePacked(vars)), salt));
    }

    function _commitAs(address sender, uint256 problemId, int256[] memory vars, bytes32 salt) internal {
        bytes32 h = _commitHash(problemId, vars, salt);
        vm.prank(sender);
        coordinator.commit(h);
        // Reveals must occur in a strictly later block than the commit.
        vm.roll(block.number + 1);
    }

    // registerProblem

    function test_registerProblem_reverts_no_blob() public {
        vm.prank(alice);
        vm.expectRevert(Coordinator.NoBlobAttached.selector);
        coordinator.registerProblem{value: 1 ether}(NL_MIN_X_HASH, true, block.timestamp + 1 days);
    }

    function test_registerProblem_stores_blobHash() public {
        uint256 id = _registerProblem(alice, 1 ether, block.timestamp + 1 days);
        (, bytes32 blobHash,,,,,,,,) = coordinator.problems(id);
        assertEq(blobHash, MOCK_BLOB_HASH);
    }

    function test_registerProblem() public {
        uint256 id = _registerProblem(alice, 1 ether, block.timestamp + 1 days);
        assertEq(id, 0);
        (bytes32 nlHash,, bool isMin,, uint256 b, uint256 d,,,,) = coordinator.problems(id);
        assertEq(nlHash, NL_MIN_X_HASH);
        assertTrue(isMin);
        assertEq(b, 1 ether);
        assertEq(d, block.timestamp + 1 days);
    }

    function test_registerProblem_emits() public {
        _setBlobHash();
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit Coordinator.ProblemRegistered(0, NL_MIN_X_HASH, MOCK_BLOB_HASH, 1 ether, block.timestamp + 1 days);
        coordinator.registerProblem{value: 1 ether}(NL_MIN_X_HASH, true, block.timestamp + 1 days);
    }

    // commit

    function test_commit() public {
        _registerProblem(alice, 1 ether, block.timestamp + 1 days);

        int256[] memory vars = _makeVars(10);
        bytes32 salt = bytes32(uint256(42));

        _commitAs(bob, 0, vars, salt);

        (bytes32 ch, uint64 blockNumber, bool revealed) = coordinator.commitments(bob);
        assertEq(ch, _commitHash(0, vars, salt));
        assertEq(blockNumber, uint64(block.number - 1));
        assertFalse(revealed);
    }

    function test_reveal_same_block_reverts() public {
        _registerProblem(alice, 1 ether, block.timestamp + 1 days);

        int256[] memory vars = _makeVars(10);
        bytes32 salt = bytes32(uint256(42));

        bytes32 h = _commitHash(0, vars, salt);
        vm.prank(bob);
        coordinator.commit(h);

        vm.prank(bob);
        vm.expectRevert(Coordinator.RevealTooEarly.selector);
        coordinator.revealDirect(0, NL_MIN_X, vars, salt);
    }

    // revealDirect

    function test_revealDirect() public {
        _registerProblem(alice, 1 ether, block.timestamp + 1 days);

        int256[] memory vars = _makeVars(10);
        bytes32 salt = bytes32(uint256(42));

        _commitAs(bob, 0, vars, salt);

        vm.prank(bob);
        coordinator.revealDirect(0, NL_MIN_X, vars, salt);

        (,,,,,, address bestSolver, int256 bestObj, bool hasSolution,) = coordinator.problems(0);
        assertEq(bestSolver, bob);
        assertEq(bestObj, 10);
        assertTrue(hasSolution);
    }

    function test_revealDirect_reverts_after_deadline() public {
        _registerProblem(alice, 1 ether, block.timestamp + 1 days);

        int256[] memory vars = _makeVars(10);
        bytes32 salt = bytes32(uint256(42));

        _commitAs(bob, 0, vars, salt);

        vm.warp(block.timestamp + 2 days);
        vm.prank(bob);
        vm.expectRevert(Coordinator.DeadlinePassed.selector);
        coordinator.revealDirect(0, NL_MIN_X, vars, salt);
    }

    function test_revealDirect_nl_hash_mismatch() public {
        _registerProblem(alice, 1 ether, block.timestamp + 1 days);

        int256[] memory vars = _makeVars(10);
        bytes32 salt = bytes32(uint256(42));

        _commitAs(bob, 0, vars, salt);

        vm.prank(bob);
        vm.expectRevert(Coordinator.NlFileHashMismatch.selector);
        coordinator.revealDirect(0, "wrong nl file", vars, salt);
    }

    function test_revealDirect_commitment_mismatch() public {
        _registerProblem(alice, 1 ether, block.timestamp + 1 days);

        int256[] memory vars = _makeVars(10);
        bytes32 salt = bytes32(uint256(42));

        _commitAs(bob, 0, vars, salt);

        int256[] memory wrongVars = _makeVars(999);
        vm.prank(bob);
        vm.expectRevert(Coordinator.CommitmentMismatch.selector);
        coordinator.revealDirect(0, NL_MIN_X, wrongVars, salt);
    }

    function test_revealDirect_double_reveal() public {
        _registerProblem(alice, 1 ether, block.timestamp + 1 days);

        int256[] memory vars = _makeVars(10);
        bytes32 salt = bytes32(uint256(42));

        _commitAs(bob, 0, vars, salt);

        vm.prank(bob);
        coordinator.revealDirect(0, NL_MIN_X, vars, salt);

        vm.prank(bob);
        vm.expectRevert(Coordinator.AlreadyRevealed.selector);
        coordinator.revealDirect(0, NL_MIN_X, vars, salt);
    }

    // Multiple solvers

    function test_two_solvers_best_wins() public {
        _registerProblem(alice, 1 ether, block.timestamp + 1 days);

        int256[] memory vars1 = _makeVars(50);
        bytes32 salt1 = bytes32(uint256(1));
        int256[] memory vars2 = _makeVars(10);
        bytes32 salt2 = bytes32(uint256(2));

        _commitAs(bob, 0, vars1, salt1);
        _commitAs(carol, 0, vars2, salt2);

        vm.prank(bob);
        coordinator.revealDirect(0, NL_MIN_X, vars1, salt1);
        vm.prank(carol);
        coordinator.revealDirect(0, NL_MIN_X, vars2, salt2);

        (,,,,,, address bestSolver, int256 bestObj,,) = coordinator.problems(0);
        assertEq(bestSolver, carol);
        assertEq(bestObj, 10);
    }

    // claimBounty

    function test_claimBounty() public {
        _registerProblem(alice, 1 ether, block.timestamp + 1 days);

        int256[] memory vars = _makeVars(10);
        bytes32 salt = bytes32(uint256(42));

        _commitAs(bob, 0, vars, salt);
        vm.prank(bob);
        coordinator.revealDirect(0, NL_MIN_X, vars, salt);

        vm.warp(block.timestamp + 2 days);

        uint256 balBefore = bob.balance;
        coordinator.claimBounty(0);
        assertEq(bob.balance, balBefore + 1 ether);
    }

    function test_claimBounty_no_solution_refunds_owner() public {
        _registerProblem(alice, 1 ether, block.timestamp + 1 days);

        vm.warp(block.timestamp + 2 days);

        uint256 balBefore = alice.balance;
        coordinator.claimBounty(0);
        assertEq(alice.balance, balBefore + 1 ether);
    }

    function test_claimBounty_reverts_before_deadline() public {
        _registerProblem(alice, 1 ether, block.timestamp + 1 days);

        vm.expectRevert(Coordinator.DeadlineNotPassed.selector);
        coordinator.claimBounty(0);
    }

    function test_claimBounty_reverts_double_claim() public {
        _registerProblem(alice, 1 ether, block.timestamp + 1 days);

        vm.warp(block.timestamp + 2 days);
        coordinator.claimBounty(0);

        vm.expectRevert(Coordinator.ProblemNotOpen.selector);
        coordinator.claimBounty(0);
    }

    // revealIndirect

    /// @dev Build a journal matching the new layout:
    ///      96 bytes Steel commitment (zeros for mock) +
    ///      8 bytes objective (i64 LE) +
    ///      128 bytes nlFileHash (32 u32 LE words) +
    ///      128 bytes solutionHash (32 u32 LE words).
    function _buildJournal(int64 objective, bytes32 nlFileHash, bytes32 solutionHash)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory j = new bytes(96 + 264);

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

    function _mockSeal(bytes memory journal) internal view returns (bytes memory) {
        RiscZeroReceipt memory receipt = mockZk.mockProve(imageId, sha256(journal));
        return receipt.seal;
    }

    function _indirectSetup(int256 v)
        internal
        returns (bytes32 solutionHash, bytes32 salt, bytes memory journal, bytes memory seal)
    {
        _registerProblem(alice, 1 ether, block.timestamp + 1 days);

        int256[] memory vars = _makeVars(v);
        salt = bytes32(uint256(42));
        solutionHash = sha256(abi.encodePacked(vars));

        _commitAs(bob, 0, vars, salt);

        // forge-lint: disable-next-line(unsafe-typecast)
        journal = _buildJournal(int64(v), NL_MIN_X_HASH, solutionHash);
        seal = _mockSeal(journal);
    }

    function test_revealIndirect() public {
        (bytes32 solutionHash, bytes32 salt, bytes memory journal, bytes memory seal) = _indirectSetup(10);

        vm.prank(bob);
        coordinator.revealIndirect(0, seal, journal, solutionHash, salt);

        (,,,,,, address bestSolver, int256 bestObj, bool hasSolution,) = coordinator.problems(0);
        assertEq(bestSolver, bob);
        assertEq(bestObj, 10);
        assertTrue(hasSolution);
    }

    function test_revealIndirect_not_improved() public {
        (bytes32 solutionHash, bytes32 salt, bytes memory journal, bytes memory seal) = _indirectSetup(10);

        vm.prank(bob);
        coordinator.revealIndirect(0, seal, journal, solutionHash, salt);

        // Second solver with worse objective.
        int256[] memory vars2 = _makeVars(50);
        bytes32 salt2 = bytes32(uint256(99));
        _commitAs(carol, 0, vars2, salt2);

        bytes32 solHash2 = sha256(abi.encodePacked(vars2));
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory journal2 = _buildJournal(int64(int256(50)), NL_MIN_X_HASH, solHash2);
        bytes memory seal2 = _mockSeal(journal2);

        vm.prank(carol);
        coordinator.revealIndirect(0, seal2, journal2, solHash2, salt2);

        (,,,,,, address bestSolver, int256 bestObj,,) = coordinator.problems(0);
        assertEq(bestSolver, bob);
        assertEq(bestObj, 10);
    }

    function test_revealIndirect_nl_hash_mismatch() public {
        _registerProblem(alice, 1 ether, block.timestamp + 1 days);

        int256[] memory vars = _makeVars(10);
        bytes32 salt = bytes32(uint256(42));
        bytes32 solHash = sha256(abi.encodePacked(vars));
        _commitAs(bob, 0, vars, salt);

        // Journal with wrong NL file hash.
        bytes32 wrongNlHash = sha256("wrong");
        bytes memory journal = _buildJournal(int64(int256(10)), wrongNlHash, solHash);
        bytes memory seal = _mockSeal(journal);

        vm.prank(bob);
        vm.expectRevert("nl file hash mismatch");
        coordinator.revealIndirect(0, seal, journal, solHash, salt);
    }

    function test_revealIndirect_solution_hash_mismatch() public {
        (bytes32 solutionHash, bytes32 salt,,) = _indirectSetup(10);

        // Build journal with wrong solution hash.
        bytes32 wrongSolHash = sha256(abi.encodePacked(_makeVars(999)));
        bytes memory badJournal = _buildJournal(int64(int256(10)), NL_MIN_X_HASH, wrongSolHash);
        bytes memory badSeal = _mockSeal(badJournal);

        vm.prank(bob);
        vm.expectRevert("solution hash mismatch");
        coordinator.revealIndirect(0, badSeal, badJournal, solutionHash, salt);
    }

    function test_revealIndirect_journal_too_short() public {
        _registerProblem(alice, 1 ether, block.timestamp + 1 days);

        int256[] memory vars = _makeVars(10);
        bytes32 salt = bytes32(uint256(42));
        bytes32 solHash = sha256(abi.encodePacked(vars));
        _commitAs(bob, 0, vars, salt);

        bytes memory shortJournal = new bytes(96 + 10);
        bytes memory seal = _mockSeal(shortJournal);

        vm.prank(bob);
        vm.expectRevert("journal too short");
        coordinator.revealIndirect(0, seal, shortJournal, solHash, salt);
    }

    function test_revealIndirect_commitment_mismatch() public {
        (bytes32 solutionHash,, bytes memory journal, bytes memory seal) = _indirectSetup(10);

        bytes32 wrongSalt = bytes32(uint256(999));
        vm.prank(bob);
        vm.expectRevert(Coordinator.CommitmentMismatch.selector);
        coordinator.revealIndirect(0, seal, journal, solutionHash, wrongSalt);
    }

    function test_revealIndirect_double_reveal() public {
        (bytes32 solutionHash, bytes32 salt, bytes memory journal, bytes memory seal) = _indirectSetup(10);

        vm.prank(bob);
        coordinator.revealIndirect(0, seal, journal, solutionHash, salt);

        vm.prank(bob);
        vm.expectRevert(Coordinator.AlreadyRevealed.selector);
        coordinator.revealIndirect(0, seal, journal, solutionHash, salt);
    }

    function test_revealIndirect_negative_objective() public {
        _registerProblem(alice, 1 ether, block.timestamp + 1 days);

        int256[] memory vars = _makeVars(-50);
        bytes32 salt = bytes32(uint256(42));
        bytes32 solHash = sha256(abi.encodePacked(vars));
        _commitAs(bob, 0, vars, salt);

        bytes memory journal = _buildJournal(int64(-50), NL_MIN_X_HASH, solHash);
        bytes memory seal = _mockSeal(journal);

        vm.prank(bob);
        coordinator.revealIndirect(0, seal, journal, solHash, salt);

        (,,,,,,, int256 bestObj,,) = coordinator.problems(0);
        assertEq(bestObj, -50);
    }

    function test_claimBounty_after_revealIndirect() public {
        (bytes32 solutionHash, bytes32 salt, bytes memory journal, bytes memory seal) = _indirectSetup(10);

        vm.prank(bob);
        coordinator.revealIndirect(0, seal, journal, solutionHash, salt);

        vm.warp(block.timestamp + 2 days);

        uint256 balBefore = bob.balance;
        coordinator.claimBounty(0);
        assertEq(bob.balance, balBefore + 1 ether);
    }
}
