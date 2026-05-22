// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {CrossingCounter} from "./CrossingCounter.sol";
import {Fixtures} from "./Fixtures.sol";
import {Test} from "@forge-std/Test.sol";

contract CrossingCounterTest is Test, Fixtures {
    CrossingCounter private _complete;

    function _k13Edges() internal pure returns (CrossingCounter.Edge[] memory) {
        uint256 count = 0;
        for (uint8 i = 0; i < 13; i++) {
            for (uint8 j = i + 1; j < 13; j++) {
                count++;
            }
        }
        CrossingCounter.Edge[] memory edges = new CrossingCounter.Edge[](count);
        uint256 idx = 0;
        for (uint8 i = 0; i < 13; i++) {
            for (uint8 j = i + 1; j < 13; j++) {
                edges[idx] = CrossingCounter.Edge(i, j);
                idx++;
            }
        }
        return edges;
    }

    function _completeEdges(uint8 n) internal pure returns (CrossingCounter.Edge[] memory) {
        uint256 count = 0;
        for (uint8 i = 0; i < n; i++) {
            for (uint8 j = i + 1; j < n; j++) {
                count++;
            }
        }
        CrossingCounter.Edge[] memory edges = new CrossingCounter.Edge[](count);
        uint256 idx = 0;
        for (uint8 i = 0; i < n; i++) {
            for (uint8 j = i + 1; j < n; j++) {
                edges[idx] = CrossingCounter.Edge(i, j);
                idx++;
            }
        }
        return edges;
    }

    function setUp() public {
        CrossingCounter.Edge[] memory edges = _k13Edges();
        _complete = new CrossingCounter(edges, true);
    }

    // Stateful path tests

    function test_Convex13() public {
        assertEq(715, _complete.verify(_convex13()));
    }

    function test_Random13() public {
        assertEq(483, _complete.verify(_random13()));
    }

    function test_Optimal13() public {
        assertEq(229, _complete.verify(_optimal13()));
    }

    function test_BestSolutionUpdated() public {
        _complete.verify(_convex13());
        assertEq(715, _complete.bestCrossings());

        _complete.verify(_random13());
        assertEq(483, _complete.bestCrossings());

        _complete.verify(_optimal13());
        assertEq(229, _complete.bestCrossings());

        _complete.verify(_convex13());
        assertEq(229, _complete.bestCrossings());
    }

    function test_RejectsCollinear() public {
        int256[] memory c = new int256[](6);
        c[0] = 0;
        c[1] = 0;
        c[2] = 1;
        c[3] = 1;
        c[4] = 2;
        c[5] = 2;

        CrossingCounter.Edge[] memory edges = new CrossingCounter.Edge[](3);
        edges[0] = CrossingCounter.Edge(0, 1);
        edges[1] = CrossingCounter.Edge(1, 2);
        edges[2] = CrossingCounter.Edge(0, 2);
        CrossingCounter small = new CrossingCounter(edges, false);

        vm.expectRevert("three collinear vertices");
        small.verify(c);
    }

    function test_GeneralPath() public {
        CrossingCounter.Edge[] memory edges = _k13Edges();
        CrossingCounter general = new CrossingCounter(edges, false);
        assertEq(229, general.verify(_optimal13()));
    }

    // Pure path tests

    function _verifyBothPaths(int256[] memory coords, CrossingCounter.Edge[] memory edges, bool isComplete) internal {
        // Stateful path
        CrossingCounter stateful = new CrossingCounter(edges, isComplete);
        uint256 statefulResult = stateful.verify(coords);

        // Pure path
        uint8[] memory flatEdges;
        if (!isComplete) {
            flatEdges = new uint8[](edges.length * 2);
            for (uint256 i = 0; i < edges.length; i++) {
                flatEdges[i * 2] = edges[i].a;
                flatEdges[i * 2 + 1] = edges[i].b;
            }
        } else {
            flatEdges = new uint8[](0);
        }

        uint256 pureResult = _complete.verify(coords, flatEdges, isComplete);
        assertEq(statefulResult, pureResult);
    }

    function test_PureConvex13Complete() public {
        _verifyBothPaths(_convex13(), _completeEdges(13), true);
    }

    function test_PureConvex13General() public {
        _verifyBothPaths(_convex13(), _completeEdges(13), false);
    }

    function test_PureOptimal13Complete() public {
        _verifyBothPaths(_optimal13(), _completeEdges(13), true);
    }

    function test_PureRandom13Complete() public {
        _verifyBothPaths(_random13(), _completeEdges(13), true);
    }

    // Fixture-based benchmark (pure path)

    function test_FixturesBenchmark() public {
        string memory dir = "benchmark-fixtures/";
        string memory manifestJson;
        try vm.readFile(string.concat(dir, "manifest.json")) returns (string memory j) {
            manifestJson = j;
        } catch {
            return;
        }
        string[] memory slugs = abi.decode(vm.parseJson(manifestJson), (string[]));

        for (uint256 i = 0; i < slugs.length; i++) {
            string memory slug = slugs[i];
            string memory json = vm.readFile(string.concat(dir, slug, ".json"));
            int256[] memory coords = abi.decode(vm.parseJson(json, ".flat_coords"), (int256[]));
            uint256[] memory rawEdges = abi.decode(vm.parseJson(json, ".flat_edges"), (uint256[]));
            bool isComplete = abi.decode(vm.parseJson(json, ".is_complete"), (bool));
            uint256 expectedCrossings = abi.decode(vm.parseJson(json, ".expected_crossings"), (uint256));

            uint8[] memory flatEdges = new uint8[](rawEdges.length);
            for (uint256 j = 0; j < rawEdges.length; j++) {
                flatEdges[j] = uint8(rawEdges[j]);
            }

            uint256 crossings = _complete.verify(coords, flatEdges, isComplete);
            assertEq(expectedCrossings, crossings, string.concat("mismatch for ", slug));
        }
    }
}
