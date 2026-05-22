// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Receipt as RiscZeroReceipt} from "risc0/IRiscZeroVerifier.sol";
import {RiscZeroMockVerifier} from "risc0/test/RiscZeroMockVerifier.sol";
import {CrossingCounterZK} from "./CrossingCounterZK.sol";

contract CrossingCounterZKTest is Test {
    bytes4 constant MOCK_SELECTOR = bytes4(0);

    RiscZeroMockVerifier private mockVerifier;
    CrossingCounterZK private target;
    bytes32 private imageId;

    function setUp() public {
        mockVerifier = new RiscZeroMockVerifier(MOCK_SELECTOR);
        imageId = bytes32(uint256(0xdeadbeef));
        target = new CrossingCounterZK(mockVerifier, imageId);
    }

    /// @dev Build a 136-byte risc0-serde journal:
    ///      8 bytes u64 LE crossing_count + 32 × 4-byte u32 LE words for inputHash.
    function _makeJournal(uint64 crossingCount, bytes32 inputHash) internal pure returns (bytes memory) {
        bytes memory j = new bytes(136);
        // Write u64 LE (8 bytes).
        for (uint256 i = 0; i < 8; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            j[i] = bytes1(uint8(crossingCount >> (8 * i)));
        }
        // Write each hash byte as a u32 LE word (low byte set, 3 zero bytes).
        for (uint256 i = 0; i < 32; i++) {
            j[8 + i * 4] = inputHash[i];
            // bytes at 8+i*4+1, +2, +3 are already zero
        }
        return j;
    }

    function testVerifyOptimal() public {
        bytes32 inputHash = keccak256("k13-optimal");
        bytes memory journal = _makeJournal(229, inputHash);

        RiscZeroReceipt memory receipt = mockVerifier.mockProve(imageId, sha256(journal));
        uint256 crossings = target.verify(receipt.seal, journal);

        assertEq(crossings, 229);
        assertEq(target.bestCrossings(), 229);
        assertEq(target.bestSolver(), address(this));
        assertEq(target.bestInputHash(), inputHash);
    }

    function testVerifyConvex() public {
        bytes32 inputHash = keccak256("k13-convex");
        bytes memory journal = _makeJournal(715, inputHash);

        RiscZeroReceipt memory receipt = mockVerifier.mockProve(imageId, sha256(journal));
        uint256 crossings = target.verify(receipt.seal, journal);

        assertEq(crossings, 715);
    }

    function testBestSolutionUpdate() public {
        // Submit a worse solution first (715 crossings).
        bytes32 hash1 = keccak256("submission-1");
        bytes memory journal1 = _makeJournal(715, hash1);
        RiscZeroReceipt memory receipt1 = mockVerifier.mockProve(imageId, sha256(journal1));
        target.verify(receipt1.seal, journal1);
        assertEq(target.bestCrossings(), 715);

        // Submit a better solution (229 crossings).
        bytes32 hash2 = keccak256("submission-2");
        bytes memory journal2 = _makeJournal(229, hash2);
        RiscZeroReceipt memory receipt2 = mockVerifier.mockProve(imageId, sha256(journal2));
        target.verify(receipt2.seal, journal2);
        assertEq(target.bestCrossings(), 229);
        assertEq(target.bestInputHash(), hash2);
    }

    function testWorseSolutionDoesNotUpdate() public {
        // Submit optimal first.
        bytes32 hash1 = keccak256("optimal");
        bytes memory journal1 = _makeJournal(229, hash1);
        RiscZeroReceipt memory receipt1 = mockVerifier.mockProve(imageId, sha256(journal1));
        target.verify(receipt1.seal, journal1);

        // Submit worse solution.
        bytes32 hash2 = keccak256("worse");
        bytes memory journal2 = _makeJournal(715, hash2);
        RiscZeroReceipt memory receipt2 = mockVerifier.mockProve(imageId, sha256(journal2));
        target.verify(receipt2.seal, journal2);

        // Best should remain 229.
        assertEq(target.bestCrossings(), 229);
        assertEq(target.bestInputHash(), hash1);
    }

    function testInvalidJournalLength() public {
        bytes memory shortJournal = new bytes(40);
        RiscZeroReceipt memory receipt = mockVerifier.mockProve(imageId, sha256(shortJournal));

        vm.expectRevert("invalid journal length");
        target.verify(receipt.seal, shortJournal);
    }

    function testInvalidProofReverts() public {
        bytes memory journal = _makeJournal(229, keccak256("test"));
        // Construct a bogus seal (wrong claim digest).
        bytes memory badSeal = abi.encodePacked(MOCK_SELECTOR, bytes32(uint256(0x1)));

        vm.expectRevert();
        target.verify(badSeal, journal);
    }

    function testLargeCrossingCount() public {
        // Verify u64 LE decoding works for values > 255.
        uint64 count = 2380;
        bytes32 inputHash = keccak256("k17-convex");
        bytes memory journal = _makeJournal(count, inputHash);

        RiscZeroReceipt memory receipt = mockVerifier.mockProve(imageId, sha256(journal));
        uint256 crossings = target.verify(receipt.seal, journal);

        assertEq(crossings, count);
    }
}
