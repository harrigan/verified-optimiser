// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {NLVerifier} from "./NLVerifier.sol";
import {IERC5732} from "./IERC5732.sol";
import {IRiscZeroVerifier} from "risc0/IRiscZeroVerifier.sol";
import {Steel} from "../steel/Steel.sol";

/// @title Coordinator
/// @notice Central contract for the indirect verification system.  Coordinates
///         problem registration, commit-reveal solution submission, direct and
///         indirect (ZK) verification, and bounty payout.
///
///         Problems are identified by sha256(nlFile).  The NL file is posted to
///         blob space (EIP-4844) for solver retrieval; the coordinator stores
///         only the hash and metadata.  A singleton NLVerifier interprets the
///         NL file directly for both the direct and indirect (Steel) paths.
contract Coordinator is IERC5732 {
    enum Status {
        Open,
        Claimed
    }

    struct Problem {
        bytes32 nlFileHash;
        bytes32 blobHash;
        bool isMin;
        address owner;
        uint256 bounty;
        uint256 deadline;
        address bestSolver;
        int256 bestObjective;
        bool hasSolution;
        Status status;
    }

    struct Commitment {
        bytes32 commitHash;
        uint64 blockNumber;
        bool revealed;
    }

    NLVerifier public immutable NL_VERIFIER;
    IRiscZeroVerifier public immutable ZK_VERIFIER;
    bytes32 public immutable IMAGE_ID;

    uint256 public problemCount;
    mapping(uint256 => Problem) public problems;
    mapping(address => Commitment) public commitments;

    event ProblemRegistered(
        uint256 indexed problemId, bytes32 nlFileHash, bytes32 blobHash, uint256 bounty, uint256 deadline
    );
    event Revealed(uint256 indexed problemId, address indexed solver, int256 objective, bool improved);
    event BountyClaimed(uint256 indexed problemId, address indexed solver, uint256 amount);

    error ProblemNotOpen();
    error DeadlinePassed();
    error DeadlineNotPassed();
    error NoCommitment();
    error AlreadyRevealed();
    error CommitmentMismatch();
    error RevealTooEarly();
    error NlFileHashMismatch();
    error TransferFailed();
    error NoBounty();
    error NoBlobAttached();

    constructor(NLVerifier nlVerifier, IRiscZeroVerifier zkVerifier, bytes32 imageId) {
        NL_VERIFIER = nlVerifier;
        ZK_VERIFIER = zkVerifier;
        IMAGE_ID = imageId;
    }

    /// @notice Register a new problem with an ETH bounty.
    /// @param nlFileHash sha256 of the NL file (canonical problem identifier).
    /// @param isMin True for minimisation, false for maximisation.
    /// @param deadline Block timestamp after which the bounty can be claimed.
    function registerProblem(bytes32 nlFileHash, bool isMin, uint256 deadline)
        external
        payable
        returns (uint256 problemId)
    {
        bytes32 nlBlobHash = blobhash(0);
        if (nlBlobHash == bytes32(0)) revert NoBlobAttached();

        problemId = problemCount++;
        Problem storage p = problems[problemId];
        p.nlFileHash = nlFileHash;
        p.blobHash = nlBlobHash;
        p.isMin = isMin;
        p.owner = msg.sender;
        p.bounty = msg.value;
        p.deadline = deadline;
        p.status = Status.Open;
        p.bestObjective = isMin ? type(int256).max : type(int256).min;

        emit ProblemRegistered(problemId, nlFileHash, nlBlobHash, msg.value, deadline);
    }

    /// @notice Commit a hashed solution (ERC-5732).  The reveal must occur
    ///         in a strictly later block; otherwise an observer of a pending
    ///         reveal could copy the solution, commit, and reveal within the
    ///         same block.
    /// @param _commitment keccak256(abi.encodePacked(problemId, solutionHash, salt))
    ///        where solutionHash = sha256(abi.encodePacked(vars)).
    function commit(bytes32 _commitment) external {
        commitments[msg.sender] =
            Commitment({commitHash: _commitment, blockNumber: uint64(block.number), revealed: false});

        emit Commit(block.number, msg.sender, _commitment);
    }

    /// @notice Reveal via direct on-chain verification.
    /// @param problemId The problem to reveal for.
    /// @param nlFile The NL file bytes (must hash to the registered nlFileHash).
    /// @param vars The solution variables in NL variable order.
    /// @param salt The salt used in the commitment.
    function revealDirect(uint256 problemId, bytes calldata nlFile, int256[] calldata vars, bytes32 salt) external {
        Problem storage p = problems[problemId];
        if (p.status != Status.Open) revert ProblemNotOpen();
        if (block.timestamp > p.deadline) revert DeadlinePassed();

        if (sha256(nlFile) != p.nlFileHash) revert NlFileHashMismatch();

        _verifyCommitment(problemId, sha256(abi.encodePacked(vars)), salt);

        int256 objective = NL_VERIFIER.verify(nlFile, vars);

        bool improved = p.isMin ? objective < p.bestObjective : objective > p.bestObjective;

        _updateBest(p, problemId, objective, improved);
    }

    /// @notice Reveal via indirect ZK (Steel) verification.  The solution
    ///         is not posted to block space; only its hash is checked
    ///         on-chain.  The solver discloses the full solution in blob
    ///         space (EIP-4844) for retrieval by the problem owner.
    /// @param problemId The problem to reveal for.
    /// @param seal The Groth16 proof.
    /// @param journal The Steel journal (96-byte commitment + payload).
    /// @param solutionHash sha256(abi.encodePacked(vars)) binding the proof
    ///        to the disclosed solution.
    /// @param salt The salt used in the commitment.
    function revealIndirect(
        uint256 problemId,
        bytes calldata seal,
        bytes calldata journal,
        bytes32 solutionHash,
        bytes32 salt
    ) external {
        Problem storage p = problems[problemId];
        if (p.status != Status.Open) revert ProblemNotOpen();
        if (block.timestamp > p.deadline) revert DeadlinePassed();

        _verifyCommitment(problemId, solutionHash, salt);

        // Verify the Groth16 proof.
        ZK_VERIFIER.verify(seal, IMAGE_ID, sha256(journal));

        // Journal layout:
        //   bytes   0..95:  Steel Commitment (3 x uint256, ABI-encoded)
        // then payload:
        //   bytes   0..7:   objective as i64 LE
        //   bytes  8..135:  nlFileHash as 32 u32 LE words
        //   bytes 136..263: solutionHash as 32 u32 LE words
        //   bytes 264..343: verifier address as 20 u32 LE words
        require(journal.length >= 96 + 344, "journal too short");

        // Validate the Steel commitment: the guest's EVM execution must have
        // run against a block of this chain (and this chain's config).
        // Without this check the prover can fabricate arbitrary EVM state.
        Steel.Commitment memory commitment = abi.decode(journal[0:96], (Steel.Commitment));
        require(Steel.validateCommitment(commitment), "invalid steel commitment");

        int256 objective = int256(int64(_readI64le(journal, 96)));
        bytes32 journalNlHash = _readHashFromWords(journal, 104);
        bytes32 journalSolHash = _readHashFromWords(journal, 232);
        address journalVerifier = _readAddressFromWords(journal, 360);

        require(journalNlHash == p.nlFileHash, "nl file hash mismatch");
        require(journalSolHash == solutionHash, "solution hash mismatch");
        // The guest commits the address of the contract it executed; without
        // this check the prover could run any contract with a matching
        // selector instead of the canonical NLVerifier.
        require(journalVerifier == address(NL_VERIFIER), "verifier address mismatch");

        bool improved = p.isMin ? objective < p.bestObjective : objective > p.bestObjective;

        _updateBest(p, problemId, objective, improved);
    }

    /// @notice Claim the bounty after the deadline.
    /// @param problemId The problem to claim for.
    function claimBounty(uint256 problemId) external {
        Problem storage p = problems[problemId];
        if (p.status != Status.Open) revert ProblemNotOpen();
        if (block.timestamp <= p.deadline) revert DeadlineNotPassed();

        p.status = Status.Claimed;

        if (p.bounty == 0) revert NoBounty();

        address recipient;
        if (p.hasSolution) {
            recipient = p.bestSolver;
        } else {
            recipient = p.owner;
        }

        uint256 amount = p.bounty;
        p.bounty = 0;

        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit BountyClaimed(problemId, recipient, amount);
    }

    // Internal helpers

    function _verifyCommitment(uint256 problemId, bytes32 solutionHash, bytes32 salt) internal {
        Commitment storage c = commitments[msg.sender];
        if (c.commitHash == bytes32(0)) revert NoCommitment();
        if (c.revealed) revert AlreadyRevealed();
        if (block.number <= c.blockNumber) revert RevealTooEarly();

        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 expected = keccak256(abi.encodePacked(problemId, solutionHash, salt));
        if (expected != c.commitHash) revert CommitmentMismatch();

        c.revealed = true;
    }

    function _updateBest(Problem storage p, uint256 problemId, int256 objective, bool improved) internal {
        if (improved) {
            p.bestObjective = objective;
            p.bestSolver = msg.sender;
            p.hasSolution = true;
        }

        emit Revealed(problemId, msg.sender, objective, improved);
    }

    // Journal decoding

    function _readI64le(bytes calldata data, uint256 offset) internal pure returns (int64 v) {
        uint64 u = uint64(uint8(data[offset])) | (uint64(uint8(data[offset + 1])) << 8)
            | (uint64(uint8(data[offset + 2])) << 16) | (uint64(uint8(data[offset + 3])) << 24)
            | (uint64(uint8(data[offset + 4])) << 32) | (uint64(uint8(data[offset + 5])) << 40)
            | (uint64(uint8(data[offset + 6])) << 48) | (uint64(uint8(data[offset + 7])) << 56);
        // forge-lint: disable-next-line(unsafe-typecast)
        v = int64(u);
    }

    function _readHashFromWords(bytes calldata data, uint256 offset) internal pure returns (bytes32 h) {
        for (uint256 i = 0; i < 32; i++) {
            h |= bytes32(uint256(uint8(data[offset + i * 4])) << (248 - 8 * i));
        }
    }

    function _readAddressFromWords(bytes calldata data, uint256 offset) internal pure returns (address a) {
        uint160 v;
        for (uint256 i = 0; i < 20; i++) {
            v |= uint160(uint8(data[offset + i * 4])) << (152 - 8 * i);
        }
        a = address(v);
    }
}
