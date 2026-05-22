// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @title CrossingCounter
/// @notice CrossingCounter with two entry points:
///         - verify(coords): stateful, reads edges from storage, tracks best solution.
///         - verify(coords, flatEdges, isComplete): stateless pure, all data via calldata.
///           Designed for use inside RISC Zero Steel where the EVM bytecode is executed
///           in the zkVM.
contract CrossingCounter {
    struct Edge {
        uint8 a;
        uint8 b;
    }

    Edge[] private _edges;
    bool private _isComplete;

    uint256 public bestCrossings;
    address public bestSolver;
    bytes32 public bestSolutionHash;

    constructor(Edge[] memory edges, bool isComplete) {
        for (uint256 i = 0; i < edges.length; i++) {
            _edges.push(edges[i]);
        }
        _isComplete = isComplete;
        bestCrossings = type(uint256).max;
    }

    /// @notice Stateful verification: reads edges from storage, updates best solution.
    function verify(int256[] calldata coords) external returns (uint256) {
        uint256 n = coords.length / 2;
        require(coords.length % 2 == 0, "coords length must be even");

        int256[] memory c = new int256[](coords.length);
        for (uint256 i = 0; i < coords.length; i++) {
            c[i] = coords[i];
        }

        _requireGeneralPosition(c, n);

        uint256 crossings;
        if (_isComplete) {
            crossings = _countCrossingsComplete(c, n);
        } else {
            crossings = _countCrossingsGeneral(c);
        }

        if (crossings < bestCrossings) {
            bestCrossings = crossings;
            bestSolver = msg.sender;
            bestSolutionHash = keccak256(abi.encodePacked(coords));
        }

        return crossings;
    }

    /// @notice Stateless verification: all data via calldata, no storage access.
    function verify(int256[] calldata coords, uint8[] calldata flatEdges, bool isComplete)
        external
        pure
        returns (uint256 crossings)
    {
        uint256 n = coords.length / 2;
        require(coords.length % 2 == 0, "coords length must be even");

        int256[] memory c = new int256[](coords.length);
        for (uint256 i = 0; i < coords.length; i++) {
            c[i] = coords[i];
        }

        _requireGeneralPosition(c, n);

        if (isComplete) {
            crossings = _countCrossingsComplete(c, n);
        } else {
            crossings = _countCrossingsGeneralPure(c, flatEdges);
        }
    }

    function _requireGeneralPosition(int256[] memory c, uint256 n) internal pure {
        assembly {
            let base := add(c, 0x20)
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                let ix := mload(add(base, mul(mul(i, 2), 0x20)))
                let iy := mload(add(base, mul(add(mul(i, 2), 1), 0x20)))
                for { let j := add(i, 1) } lt(j, n) { j := add(j, 1) } {
                    let jOff := mul(mul(j, 2), 0x20)
                    let dx1 := sub(mload(add(base, jOff)), ix)
                    let dy1 := sub(mload(add(base, add(jOff, 0x20))), iy)
                    for { let k := add(j, 1) } lt(k, n) { k := add(k, 1) } {
                        let kOff := mul(mul(k, 2), 0x20)
                        let dx2 := sub(mload(add(base, kOff)), ix)
                        let dy2 := sub(mload(add(base, add(kOff, 0x20))), iy)
                        if iszero(sub(mul(dx1, dy2), mul(dy1, dx2))) {
                            mstore(0x00, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(0x04, 0x20)
                            mstore(0x24, 24)
                            mstore(0x44, "three collinear vertices")
                            revert(0x00, 0x64)
                        }
                    }
                }
            }
        }
    }

    function _countCrossingsComplete(int256[] memory c, uint256 n) internal pure returns (uint256 crossings) {
        assembly {
            function intersects(aOff, bOff, cOff, dOff) -> result {
                let ax := mload(aOff)
                let ay := mload(add(aOff, 0x20))
                let bx := mload(bOff)
                let by := mload(add(bOff, 0x20))
                let cx := mload(cOff)
                let cy := mload(add(cOff, 0x20))
                let dx := mload(dOff)
                let dy := mload(add(dOff, 0x20))
                let abx := sub(bx, ax)
                let aby := sub(by, ay)
                let d1 := sub(mul(abx, sub(cy, ay)), mul(aby, sub(cx, ax)))
                let d2 := sub(mul(abx, sub(dy, ay)), mul(aby, sub(dx, ax)))
                let cdx := sub(dx, cx)
                let cdy := sub(dy, cy)
                let d3 := sub(mul(cdx, sub(ay, cy)), mul(cdy, sub(ax, cx)))
                let d4 := sub(mul(cdx, sub(by, cy)), mul(cdy, sub(bx, cx)))
                result := and(iszero(eq(sgt(d1, 0), sgt(d2, 0))), iszero(eq(sgt(d3, 0), sgt(d4, 0))))
            }

            let base := add(c, 0x20)
            crossings := 0
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                let iOff := add(base, mul(mul(i, 2), 0x20))
                for { let j := add(i, 1) } lt(j, n) { j := add(j, 1) } {
                    let jOff := add(base, mul(mul(j, 2), 0x20))
                    for { let k := add(j, 1) } lt(k, n) { k := add(k, 1) } {
                        let kOff := add(base, mul(mul(k, 2), 0x20))
                        for { let l := add(k, 1) } lt(l, n) { l := add(l, 1) } {
                            let lOff := add(base, mul(mul(l, 2), 0x20))
                            crossings := add(crossings, intersects(iOff, jOff, kOff, lOff))
                            crossings := add(crossings, intersects(iOff, kOff, jOff, lOff))
                            crossings := add(crossings, intersects(iOff, lOff, jOff, kOff))
                        }
                    }
                }
            }
        }
    }

    /// @dev General edge-pair iteration, edges from storage.
    function _countCrossingsGeneral(int256[] memory c) internal view returns (uint256 crossings) {
        uint256 m = _edges.length;
        uint256[] memory edgeData = new uint256[](m * 2);
        for (uint256 i = 0; i < m; i++) {
            Edge storage e = _edges[i];
            edgeData[i * 2] = e.a;
            edgeData[i * 2 + 1] = e.b;
        }

        crossings = _countCrossingsFromEdgeData(c, edgeData, m);
    }

    /// @dev General edge-pair iteration, edges from calldata.
    function _countCrossingsGeneralPure(int256[] memory c, uint8[] calldata flatEdges)
        internal
        pure
        returns (uint256 crossings)
    {
        uint256 m = flatEdges.length / 2;
        uint256[] memory edgeData = new uint256[](m * 2);
        for (uint256 i = 0; i < m; i++) {
            edgeData[i * 2] = flatEdges[i * 2];
            edgeData[i * 2 + 1] = flatEdges[i * 2 + 1];
        }

        crossings = _countCrossingsFromEdgeData(c, edgeData, m);
    }

    /// @dev Shared assembly for general edge-pair crossing count.
    function _countCrossingsFromEdgeData(int256[] memory c, uint256[] memory edgeData, uint256 m)
        internal
        pure
        returns (uint256 crossings)
    {
        assembly {
            let base := add(c, 0x20)
            let eBase := add(edgeData, 0x20)
            crossings := 0

            for { let i := 0 } lt(i, m) { i := add(i, 1) } {
                let iEdgeOff := mul(mul(i, 2), 0x20)
                let a := mload(add(eBase, iEdgeOff))
                let b := mload(add(eBase, add(iEdgeOff, 0x20)))

                let aOff := add(base, mul(mul(a, 2), 0x20))
                let ax := mload(aOff)
                let ay := mload(add(aOff, 0x20))
                let bOff := add(base, mul(mul(b, 2), 0x20))
                let bx := mload(bOff)
                let by := mload(add(bOff, 0x20))

                let abx := sub(bx, ax)
                let aby := sub(by, ay)

                for { let j := add(i, 1) } lt(j, m) { j := add(j, 1) } {
                    let jEdgeOff := mul(mul(j, 2), 0x20)
                    let cc := mload(add(eBase, jEdgeOff))
                    let d := mload(add(eBase, add(jEdgeOff, 0x20)))

                    if or(or(eq(a, cc), eq(a, d)), or(eq(b, cc), eq(b, d))) { continue }

                    let cOff := add(base, mul(mul(cc, 2), 0x20))
                    let cx := mload(cOff)
                    let cy := mload(add(cOff, 0x20))
                    let dOff := add(base, mul(mul(d, 2), 0x20))
                    let dx := mload(dOff)
                    let dy := mload(add(dOff, 0x20))

                    let d1 := sub(mul(abx, sub(cy, ay)), mul(aby, sub(cx, ax)))
                    let d2 := sub(mul(abx, sub(dy, ay)), mul(aby, sub(dx, ax)))
                    let cdx := sub(dx, cx)
                    let cdy := sub(dy, cy)
                    let d3 := sub(mul(cdx, sub(ay, cy)), mul(cdy, sub(ax, cx)))
                    let d4 := sub(mul(cdx, sub(by, cy)), mul(cdy, sub(bx, cx)))

                    crossings := add(
                        crossings,
                        and(iszero(eq(sgt(d1, 0), sgt(d2, 0))), iszero(eq(sgt(d3, 0), sgt(d4, 0))))
                    )
                }
            }
        }
    }
}
