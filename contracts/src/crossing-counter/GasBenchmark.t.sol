// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {CrossingCounter} from "./CrossingCounter.sol";
import {Test} from "@forge-std/Test.sol";

contract GasBenchmarkTest is Test {
    function _fixturesDir() internal pure returns (string memory) {
        return "benchmark-fixtures/";
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

    function _loadManifest() internal returns (string[] memory slugs) {
        string memory dir = _fixturesDir();
        try vm.readFile(string.concat(dir, "manifest.json")) returns (string memory json) {
            slugs = abi.decode(vm.parseJson(json), (string[]));
        } catch {
            vm.skip(true);
        }
    }

    function _loadFixture(string memory slug)
        internal
        view
        returns (int256[] memory coords, uint256[] memory flatEdges, bool isComplete, uint256 expectedCrossings)
    {
        string memory dir = _fixturesDir();
        string memory json = vm.readFile(string.concat(dir, slug, ".json"));
        coords = abi.decode(vm.parseJson(json, ".flat_coords"), (int256[]));
        flatEdges = abi.decode(vm.parseJson(json, ".flat_edges"), (uint256[]));
        isComplete = abi.decode(vm.parseJson(json, ".is_complete"), (bool));
        expectedCrossings = abi.decode(vm.parseJson(json, ".expected_crossings"), (uint256));
    }

    function test_benchmark() public {
        string[] memory slugs = _loadManifest();

        for (uint256 i = 0; i < slugs.length; i++) {
            string memory slug = slugs[i];
            (int256[] memory coords, uint256[] memory flatEdges, bool isComplete, uint256 expectedCrossings) =
                _loadFixture(slug);

            CrossingCounter.Edge[] memory edges;
            uint8 n = uint8(coords.length / 2);

            if (flatEdges.length == 0 && isComplete) {
                edges = _completeEdges(n);
            } else {
                edges = new CrossingCounter.Edge[](flatEdges.length / 2);
                for (uint256 j = 0; j < flatEdges.length; j += 2) {
                    edges[j / 2] = CrossingCounter.Edge(uint8(flatEdges[j]), uint8(flatEdges[j + 1]));
                }
            }

            if (isComplete) {
                CrossingCounter cComplete = new CrossingCounter(edges, true);
                uint256 g1 = gasleft();
                uint256 crossings1 = cComplete.verify(coords);
                emit log_named_uint(string.concat(slug, "_Complete_gas"), g1 - gasleft());
                assertEq(expectedCrossings, crossings1);

                CrossingCounter cGeneral = new CrossingCounter(edges, false);
                uint256 g2 = gasleft();
                uint256 crossings2 = cGeneral.verify(coords);
                emit log_named_uint(string.concat(slug, "_General_gas"), g2 - gasleft());
                assertEq(expectedCrossings, crossings2);
            } else {
                CrossingCounter c = new CrossingCounter(edges, false);
                uint256 g = gasleft();
                uint256 crossings = c.verify(coords);
                emit log_named_uint(string.concat(slug, "_gas"), g - gasleft());
                assertEq(expectedCrossings, crossings);
            }
        }
    }
}
