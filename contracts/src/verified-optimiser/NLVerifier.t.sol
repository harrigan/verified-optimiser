// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {NLVerifier} from "./NLVerifier.sol";
import {Test} from "@forge-std/Test.sol";

contract NLVerifierTest is Test {
    NLVerifier private verifier;

    function setUp() public {
        verifier = new NLVerifier();
    }

    // NL file builders

    /// @dev "min x, s.t. x >= 5", bounds -100 <= x <= 100.
    function _nlMinXGeq5() internal pure returns (bytes memory) {
        return bytes(
            string.concat(
                "g3 0 1 0\n",
                " 1 1 1 0 0\n",
                " 1 1\n",
                " 0 0\n",
                " 1 1 1\n",
                " 0 0 0 1\n",
                " 0 0 1 0 0\n",
                " 1 1\n",
                " 0 0\n",
                " 0 0 0 0 0\n",
                "b\n",
                "0 -100 100\n",
                "r\n",
                "2 5\n",
                "C0\n",
                "v0\n",
                "O0 0\n",
                "v0\n",
                "k0\n"
            )
        );
    }

    /// @dev "max x", no constraints, bounds 0 <= x <= 100.
    function _nlMaxX() internal pure returns (bytes memory) {
        return bytes(
            string.concat(
                "g3 0 1 0\n",
                " 1 0 1 0 0\n",
                " 0 1\n",
                " 0 0\n",
                " 0 1 0\n",
                " 0 0 0 1\n",
                " 0 0 1 0 0\n",
                " 0 1\n",
                " 0 0\n",
                " 0 0 0 0 0\n",
                "b\n",
                "0 0 100\n",
                "r\n",
                "O0 1\n",
                "v0\n",
                "k0\n"
            )
        );
    }

    /// @dev "min x + y, s.t. x * y >= 6", bounds 1 <= x,y <= 10.
    function _nlSumProductGeq6() internal pure returns (bytes memory) {
        return bytes(
            string.concat(
                "g3 0 1 0\n",
                " 2 1 1 0 0\n",
                " 1 1\n",
                " 0 0\n",
                " 2 2 2\n",
                " 0 0 0 1\n",
                " 0 0 2 0 0\n",
                " 2 2\n",
                " 0 0\n",
                " 0 0 0 0 0\n",
                "b\n",
                "0 1 10\n",
                "0 1 10\n",
                "r\n",
                "2 6\n",
                "C0\n",
                "o2\n",
                "v0\n",
                "v1\n",
                "O0 0\n",
                "o0\n",
                "v0\n",
                "v1\n",
                "k1\n",
                "1\n"
            )
        );
    }

    /// @dev "min (if x < 0 then 1 else 0)", no constraints, -10 <= x <= 10.
    function _nlIfNegative() internal pure returns (bytes memory) {
        return bytes(
            string.concat(
                "g3 0 1 0\n",
                " 1 0 1 0 0\n",
                " 0 1\n",
                " 0 0\n",
                " 0 1 0\n",
                " 0 0 0 1\n",
                " 0 0 1 0 0\n",
                " 0 1\n",
                " 0 0\n",
                " 0 0 0 0 0\n",
                "b\n",
                "0 -10 10\n",
                "r\n",
                "O0 0\n",
                "o35\n",
                "o22\n",
                "v0\n",
                "n0\n",
                "n1\n",
                "n0\n",
                "k0\n"
            )
        );
    }

    // Tests: basic verification

    function test_verify_min_x() public view {
        int256[] memory vars = new int256[](1);
        vars[0] = 5;
        int256 obj = verifier.verify(_nlMinXGeq5(), vars);

        assertEq(obj, 5);
    }

    function test_verify_sum_product() public view {
        int256[] memory vars = new int256[](2);
        vars[0] = 2;
        vars[1] = 3;
        int256 obj = verifier.verify(_nlSumProductGeq6(), vars);

        assertEq(obj, 5);
    }

    function test_verify_if_negative() public view {
        int256[] memory neg = new int256[](1);
        neg[0] = -5;
        int256 objNeg = verifier.verify(_nlIfNegative(), neg);
        assertEq(objNeg, 1);

        int256[] memory pos = new int256[](1);
        pos[0] = 5;
        int256 objPos = verifier.verify(_nlIfNegative(), pos);
        assertEq(objPos, 0);
    }

    function test_verify_maximise() public view {
        int256[] memory vars = new int256[](1);
        vars[0] = 80;
        int256 obj = verifier.verify(_nlMaxX(), vars);

        assertEq(obj, 80);
    }

    // Tests: error conditions

    function test_revert_wrong_var_count() public {
        int256[] memory bad = new int256[](2);
        bad[0] = 5;
        bad[1] = 6;
        vm.expectRevert(abi.encodeWithSelector(NLVerifier.WrongVarCount.selector, 1, 2));
        verifier.verify(_nlMinXGeq5(), bad);
    }

    function test_revert_bounds_violated() public {
        int256[] memory vars = new int256[](1);
        vars[0] = 200;
        vm.expectRevert(abi.encodeWithSelector(NLVerifier.BoundsViolated.selector, 0));
        verifier.verify(_nlMinXGeq5(), vars);
    }

    function test_revert_constraint_violated() public {
        int256[] memory vars = new int256[](1);
        vars[0] = 3;
        vm.expectRevert(abi.encodeWithSelector(NLVerifier.ConstraintViolated.selector, 0));
        verifier.verify(_nlMinXGeq5(), vars);
    }

    function test_revert_product_constraint() public {
        int256[] memory vars = new int256[](2);
        vars[0] = 2;
        vars[1] = 2;
        vm.expectRevert(abi.encodeWithSelector(NLVerifier.ConstraintViolated.selector, 0));
        verifier.verify(_nlSumProductGeq6(), vars);
    }

    // Tests: real NL file (crossing-count K_5)

    function test_verify_crossing_count_k5() public view {
        bytes memory nl = bytes(vm.readFile("src/verified-optimiser/fixtures/crossing-count-k5.nl"));

        // K_5 convex placement (from crossing-count.dat, B=100).
        // NL variable order: x[1]..x[5], y[1]..y[5].
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

        int256 obj = verifier.verify(nl, vars);

        assertEq(obj, 5);
    }

    function test_verify_crossing_count_k5_gas() public {
        bytes memory nl = bytes(vm.readFile("src/verified-optimiser/fixtures/crossing-count-k5.nl"));

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

        uint256 gasBefore = gasleft();
        verifier.verify(nl, vars);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("k5_verify_gas", gasUsed);
    }

    // Tests: negative constants

    /// @dev "min (x + (-5))", no constraints, -10 <= x <= 10.
    function test_verify_negative_constant() public view {
        bytes memory nl = bytes(
            string.concat(
                "g3 0 1 0\n",
                " 1 0 1 0 0\n",
                " 0 1\n",
                " 0 0\n",
                " 0 1 0\n",
                " 0 0 0 1\n",
                " 0 0 1 0 0\n",
                " 0 1\n",
                " 0 0\n",
                " 0 0 0 0 0\n",
                "b\n",
                "0 -10 10\n",
                "r\n",
                "O0 0\n",
                "o0\n",
                "v0\n",
                "n-5\n",
                "k0\n"
            )
        );
        int256[] memory vars = new int256[](1);
        vars[0] = 7;
        int256 obj = verifier.verify(nl, vars);
        assertEq(obj, 2);
    }

    // Tests: multi-digit variable indices (>= v10)

    /// @dev "min v0 + v10", 11 vars, all unbounded.
    function test_verify_multidigit_var_index() public view {
        bytes memory nl = bytes(
            string.concat(
                "g3 0 1 0\n",
                " 11 0 1 0 0\n",
                " 0 1\n",
                " 0 0\n",
                " 0 11 0\n",
                " 0 0 0 1\n",
                " 0 0 11 0 0\n",
                " 0 11\n",
                " 0 0\n",
                " 0 0 0 0 0\n",
                "b\n",
                "3\n",
                "3\n",
                "3\n",
                "3\n",
                "3\n",
                "3\n",
                "3\n",
                "3\n",
                "3\n",
                "3\n",
                "3\n",
                "r\n",
                "O0 0\n",
                "o0\n",
                "v0\n",
                "v10\n",
                "k0\n"
            )
        );
        int256[] memory vars = new int256[](11);
        vars[0] = 42;
        vars[10] = 58;
        int256 obj = verifier.verify(nl, vars);
        assertEq(obj, 100);
    }

    function test_revert_crossing_count_k5_collinear() public {
        bytes memory nl = bytes(vm.readFile("src/verified-optimiser/fixtures/crossing-count-k5.nl"));

        // Three collinear vertices: (0,0), (1,1), (2,2).
        int256[] memory vars = new int256[](10);
        vars[0] = 0;
        vars[1] = 1;
        vars[2] = 2;
        vars[3] = 3;
        vars[4] = 4;
        vars[5] = 0;
        vars[6] = 1;
        vars[7] = 2;
        vars[8] = 5;
        vars[9] = 6;

        // Should revert: det*det for triple (1,2,3) is 0, violating >= 1.
        vm.expectRevert(abi.encodeWithSelector(NLVerifier.ConstraintViolated.selector, 0));
        verifier.verify(nl, vars);
    }
}
