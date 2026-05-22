// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @title NLVerifier
/// @notice Stateless interpreter for AMPL NL files.  Parses the NL text
///         directly and evaluates constraints and the objective for a given
///         solution.  Deployed once as a singleton; the same instance serves
///         every problem.
///
///         Supported NL subset (integer/piecewise-polynomial):
///           o0  PLUS        o1  MINUS       o2  MULT
///           o16 UMINUS      o20 OR          o21 AND
///           o22 LT          o23 LE          o24 EQ
///           o28 GE          o29 GT          o30 NE
///           o34 NOT         o35 IF          o54 SUMLIST
///           v<n> variable   n<val> constant
contract NLVerifier {
    error WrongVarCount(uint256 expected, uint256 actual);
    error BoundsViolated(uint256 varIndex);
    error ConstraintViolated(uint256 constraintIndex);
    error UnsupportedOpcode(uint256 opcode);

    /// @notice Verify a candidate solution against an NL problem definition.
    ///         Reverts if the solution is infeasible (bounds or constraint
    ///         violation).  Returns the objective value.
    /// @param nl  Raw bytes of the NL file.
    /// @param vars Decision variable values in NL variable order.
    function verify(bytes calldata nl, int256[] calldata vars) external pure returns (int256 objective) {
        // Header (line 1, 0-indexed)
        uint256 pos = _nextLine(nl, 0);
        uint256 numVars;
        uint256 numConstraints;
        {
            int256 nv;
            int256 nc;
            (nv, pos) = _parseInt(nl, pos);
            (nc, pos) = _parseInt(nl, pos);
            // forge-lint: disable-next-line(unsafe-typecast)
            numVars = uint256(nv);
            // forge-lint: disable-next-line(unsafe-typecast)
            numConstraints = uint256(nc);
        }

        if (vars.length != numVars) {
            revert WrongVarCount(numVars, vars.length);
        }

        int256[] memory v = new int256[](numVars);
        for (uint256 i = 0; i < numVars; i++) {
            v[i] = vars[i];
        }

        // Skip remaining header lines (lines 2-9).
        for (uint256 i = 0; i < 8; i++) {
            pos = _nextLine(nl, pos);
        }
        pos = _nextLine(nl, pos);

        // b segment (variable bounds)
        // pos is at the 'b' line.
        pos = _nextLine(nl, pos);
        for (uint256 i = 0; i < numVars; i++) {
            pos = _checkBound(nl, pos, v[i], i);
        }

        // x segment (initial values, optional)
        if (pos < nl.length && nl[pos] == 0x78) {
            int256 xCount;
            (xCount, pos) = _parseInt(nl, pos + 1);
            pos = _nextLine(nl, pos);
            // forge-lint: disable-next-line(unsafe-typecast)
            for (uint256 i = 0; i < uint256(xCount); i++) {
                pos = _nextLine(nl, pos);
            }
        }

        // r segment (constraint ranges)
        pos = _nextLine(nl, pos);
        int256[] memory cLower = new int256[](numConstraints);
        int256[] memory cUpper = new int256[](numConstraints);
        for (uint256 i = 0; i < numConstraints; i++) {
            (cLower[i], cUpper[i], pos) = _parseRange(nl, pos);
        }

        // C segments (constraint expression trees)
        for (uint256 i = 0; i < numConstraints; i++) {
            pos = _nextLine(nl, pos);
            int256 val;
            (val, pos) = _evalExpr(nl, pos, v);
            if (val < cLower[i] || val > cUpper[i]) {
                revert ConstraintViolated(i);
            }
        }

        // O segment (objective)
        // Skip the "O0 0"/"O0 1" line; min/max is the coordinator's concern.
        pos = _nextLine(nl, pos);
        (objective,) = _evalExpr(nl, pos, v);
    }

    // Line navigation

    function _nextLine(bytes calldata nl, uint256 pos) internal pure returns (uint256 newPos) {
        assembly ("memory-safe") {
            let nlOff := nl.offset
            let nlEnd := add(nlOff, nl.length)
            let p := add(nlOff, pos)
            for {} lt(p, nlEnd) { p := add(p, 1) } {
                if eq(byte(0, calldataload(p)), 0x0a) {
                    p := add(p, 1)
                    break
                }
            }
            newPos := sub(p, nlOff)
        }
    }

    // Number parsing

    function _parseInt(bytes calldata nl, uint256 pos) internal pure returns (int256 value, uint256 endPos) {
        assembly ("memory-safe") {
            let nlOff := nl.offset
            let nlEnd := add(nlOff, nl.length)
            let p := add(nlOff, pos)
            // Skip whitespace (0x20 space, 0x09 tab).
            for {} lt(p, nlEnd) { p := add(p, 1) } {
                let b := byte(0, calldataload(p))
                if and(iszero(eq(b, 0x20)), iszero(eq(b, 0x09))) { break }
            }
            // Check for negative sign.
            let neg := 0
            if lt(p, nlEnd) {
                if eq(byte(0, calldataload(p)), 0x2d) {
                    neg := 1
                    p := add(p, 1)
                }
            }
            // Accumulate digits.
            let v := 0
            for {} lt(p, nlEnd) { p := add(p, 1) } {
                let b := byte(0, calldataload(p))
                if or(lt(b, 0x30), gt(b, 0x39)) { break }
                v := add(mul(v, 10), sub(b, 0x30))
            }
            if neg { v := sub(0, v) }
            value := v
            endPos := sub(p, nlOff)
        }
    }

    // Bounds and ranges

    function _checkBound(bytes calldata nl, uint256 pos, int256 val, uint256 varIndex)
        internal
        pure
        returns (uint256 nextPos)
    {
        int256 btype;
        (btype, pos) = _parseInt(nl, pos);

        if (btype == 0) {
            int256 lo;
            int256 hi;
            (lo, pos) = _parseInt(nl, pos);
            (hi, pos) = _parseInt(nl, pos);
            if (val < lo || val > hi) revert BoundsViolated(varIndex);
        } else if (btype == 1) {
            int256 hi;
            (hi, pos) = _parseInt(nl, pos);
            if (val > hi) revert BoundsViolated(varIndex);
        } else if (btype == 2) {
            int256 lo;
            (lo, pos) = _parseInt(nl, pos);
            if (val < lo) revert BoundsViolated(varIndex);
        } else if (btype == 4) {
            int256 fixed_;
            (fixed_, pos) = _parseInt(nl, pos);
            if (val != fixed_) revert BoundsViolated(varIndex);
        }
        // btype 3 = no bounds: nothing to check.
        return _nextLine(nl, pos);
    }

    function _parseRange(bytes calldata nl, uint256 pos)
        internal
        pure
        returns (int256 lower, int256 upper, uint256 nextPos)
    {
        int256 rtype;
        (rtype, pos) = _parseInt(nl, pos);

        if (rtype == 0) {
            (lower, pos) = _parseInt(nl, pos);
            (upper, pos) = _parseInt(nl, pos);
        } else if (rtype == 1) {
            lower = type(int256).min;
            (upper, pos) = _parseInt(nl, pos);
        } else if (rtype == 2) {
            (lower, pos) = _parseInt(nl, pos);
            upper = type(int256).max;
        } else if (rtype == 4) {
            (lower, pos) = _parseInt(nl, pos);
            upper = lower;
        } else {
            lower = type(int256).min;
            upper = type(int256).max;
        }
        return (lower, upper, _nextLine(nl, pos));
    }

    // Expression tree evaluator (iterative, Yul assembly)
    //
    // Evaluates a prefix-notation expression tree without recursion.
    // Uses two explicit memory stacks:
    //   - value stack (vStack): int256 intermediate results
    //   - work stack (wStack): pending operations encoded as single words
    //
    // Work stack entry encoding (256-bit word):
    //   bits [255:248] = tag  (0=EVAL, 1=APPLY_BINARY, 2=APPLY_UNARY,
    //                          3=APPLY_IF, 4=APPLY_SUM)
    //   bits [247:0]   = payload (opcode for BINARY/UNARY, count for SUM)

    function _evalExpr(bytes calldata nl, uint256 pos, int256[] memory v)
        internal
        pure
        returns (int256 result, uint256 nextPos)
    {
        assembly ("memory-safe") {
            // Constants
            let TAG_EVAL := 0
            let TAG_BINARY := 1
            let TAG_UNARY := 2
            let TAG_IF := 3
            let TAG_SUM := 4

            // Allocate stacks in memory
            // Use memory above the free pointer as scratch space.  The stacks
            // are not needed after _evalExpr returns, so we restore the free
            // pointer at the end (no permanent memory expansion cost).
            let freePtr := mload(0x40)
            let vBase := freePtr
            let vTop := freePtr
            // Work stack starts 256 KB above vBase.  The gap must
            // accommodate the value stack, whose maximum height
            // equals the SUMLIST count (one result per completed
            // sub-expression) plus the depth of the active
            // sub-expression (~30 for crossing-number models).
            // 256 KB = 8192 value slots, sufficient for K_14 (3003).
            let wBase := add(freePtr, 0x40000)
            let wTop := wBase

            // Calldata / variable array pointers
            let nlOff := nl.offset
            let nlEnd := add(nlOff, nl.length)
            let p := add(nlOff, pos) // absolute calldata pointer
            let vPtr := add(v, 0x20) // pointer past array length word

            // Inline helper: skip to next line
            // Advances p past the next 0x0a byte.
            function skipLine(ptr, end) -> newPtr {
                for {} lt(ptr, end) { ptr := add(ptr, 1) } {
                    if eq(byte(0, calldataload(ptr)), 0x0a) {
                        newPtr := add(ptr, 1)
                        leave
                    }
                }
                newPtr := ptr
            }

            // Inline helper: parse integer at p
            // Returns (value, newPtr).
            function parseI(ptr, end) -> val, newPtr {
                // skip whitespace
                for {} lt(ptr, end) { ptr := add(ptr, 1) } {
                    let b := byte(0, calldataload(ptr))
                    if and(iszero(eq(b, 0x20)), iszero(eq(b, 0x09))) { break }
                }
                let neg := 0
                if lt(ptr, end) {
                    if eq(byte(0, calldataload(ptr)), 0x2d) {
                        neg := 1
                        ptr := add(ptr, 1)
                    }
                }
                val := 0
                for {} lt(ptr, end) { ptr := add(ptr, 1) } {
                    let b := byte(0, calldataload(ptr))
                    if or(lt(b, 0x30), gt(b, 0x39)) { break }
                    val := add(mul(val, 10), sub(b, 0x30))
                }
                if neg { val := sub(0, val) }
                newPtr := ptr
            }

            // Push initial EVAL task
            mstore(wTop, TAG_EVAL)
            wTop := add(wTop, 0x20)

            // Main loop
            for {} gt(wTop, wBase) {} {
                // Pop work stack
                wTop := sub(wTop, 0x20)
                let task := mload(wTop)
                let tag := shr(248, task)
                let payload := and(task, 0x00ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff)

                switch tag
                case 0 {
                    /* EVAL */
                    let ch := byte(0, calldataload(p))

                    switch ch
                    case 0x76 {
                        /* 'v' - variable */
                        p := add(p, 1)
                        let idx
                        idx, p := parseI(p, nlEnd)
                        p := skipLine(p, nlEnd)
                        // Push v[idx] onto value stack.
                        mstore(vTop, mload(add(vPtr, mul(idx, 0x20))))
                        vTop := add(vTop, 0x20)
                    }
                    case 0x6e {
                        /* 'n' - constant */
                        p := add(p, 1)
                        let val
                        val, p := parseI(p, nlEnd)
                        p := skipLine(p, nlEnd)
                        mstore(vTop, val)
                        vTop := add(vTop, 0x20)
                    }
                    case 0x6f {
                        /* 'o' - opcode */
                        p := add(p, 1)
                        let op
                        op, p := parseI(p, nlEnd)
                        p := skipLine(p, nlEnd)

                        // Dispatch by opcode.
                        switch 1
                        // Binary arithmetic: o0 PLUS, o1 MINUS, o2 MULT
                        case 1 {
                            if lt(op, 3) {
                                // Push APPLY_BINARY(op), then two EVALs.
                                mstore(wTop, or(shl(248, TAG_BINARY), op))
                                wTop := add(wTop, 0x20)
                                mstore(wTop, TAG_EVAL)
                                wTop := add(wTop, 0x20)
                                mstore(wTop, TAG_EVAL)
                                wTop := add(wTop, 0x20)
                                continue
                            }
                            // Unary minus: o16
                            if eq(op, 16) {
                                mstore(wTop, or(shl(248, TAG_UNARY), op))
                                wTop := add(wTop, 0x20)
                                mstore(wTop, TAG_EVAL)
                                wTop := add(wTop, 0x20)
                                continue
                            }
                            // Logical/comparison: o20-o30
                            if and(iszero(lt(op, 20)), iszero(gt(op, 30))) {
                                mstore(wTop, or(shl(248, TAG_BINARY), op))
                                wTop := add(wTop, 0x20)
                                mstore(wTop, TAG_EVAL)
                                wTop := add(wTop, 0x20)
                                mstore(wTop, TAG_EVAL)
                                wTop := add(wTop, 0x20)
                                continue
                            }
                            // NOT: o34
                            if eq(op, 34) {
                                mstore(wTop, or(shl(248, TAG_UNARY), op))
                                wTop := add(wTop, 0x20)
                                mstore(wTop, TAG_EVAL)
                                wTop := add(wTop, 0x20)
                                continue
                            }
                            // IF: o35 (cond, then, else)
                            if eq(op, 35) {
                                mstore(wTop, shl(248, TAG_IF))
                                wTop := add(wTop, 0x20)
                                mstore(wTop, TAG_EVAL)
                                wTop := add(wTop, 0x20)
                                mstore(wTop, TAG_EVAL)
                                wTop := add(wTop, 0x20)
                                mstore(wTop, TAG_EVAL)
                                wTop := add(wTop, 0x20)
                                continue
                            }
                            // SUMLIST: o54
                            if eq(op, 54) {
                                let cnt
                                cnt, p := parseI(p, nlEnd)
                                p := skipLine(p, nlEnd)
                                // Push APPLY_SUM(count).
                                mstore(wTop, or(shl(248, TAG_SUM), cnt))
                                wTop := add(wTop, 0x20)
                                // Push cnt EVAL tasks.
                                for { let i := 0 } lt(i, cnt) { i := add(i, 1) } {
                                    mstore(wTop, TAG_EVAL)
                                    wTop := add(wTop, 0x20)
                                }
                                continue
                            }
                            // Unsupported opcode: revert.
                            mstore(0x00, 0xba41e53700000000000000000000000000000000000000000000000000000000)
                            mstore(0x04, op)
                            revert(0x00, 0x24)
                        }
                    }
                    default {
                        // Unknown token type: revert with UnsupportedOpcode(0).
                        mstore(0x00, 0xba41e53700000000000000000000000000000000000000000000000000000000)
                        mstore(0x04, 0)
                        revert(0x00, 0x24)
                    }
                }
                case 1 {
                    /* APPLY_BINARY */
                    // Pop right (top), then left (below).
                    vTop := sub(vTop, 0x20)
                    let b := mload(vTop)
                    vTop := sub(vTop, 0x20)
                    let a := mload(vTop)
                    let r := 0

                    switch payload
                    case 0 {
                        /* PLUS  */
                        r := add(a, b)
                    }
                    case 1 {
                        /* MINUS */
                        r := sub(a, b)
                    }
                    case 2 {
                        /* MULT  */
                        r := mul(a, b)
                    }
                    case 20 {
                        /* OR   */
                        r := or(iszero(iszero(a)), iszero(iszero(b)))
                    }
                    case 21 {
                        /* AND  */
                        r := and(iszero(iszero(a)), iszero(iszero(b)))
                    }
                    case 22 {
                        /* LT   */
                        r := slt(a, b)
                    }
                    case 23 {
                        /* LE   */
                        r := iszero(sgt(a, b))
                    }
                    case 24 {
                        /* EQ   */
                        r := eq(a, b)
                    }
                    case 28 {
                        /* GE   */
                        r := iszero(slt(a, b))
                    }
                    case 29 {
                        /* GT   */
                        r := sgt(a, b)
                    }
                    case 30 {
                        /* NE   */
                        r := iszero(eq(a, b))
                    }
                    default {
                        mstore(0x00, 0xba41e53700000000000000000000000000000000000000000000000000000000)
                        mstore(0x04, payload)
                        revert(0x00, 0x24)
                    }

                    mstore(vTop, r)
                    vTop := add(vTop, 0x20)
                }
                case 2 {
                    /* APPLY_UNARY */
                    vTop := sub(vTop, 0x20)
                    let a := mload(vTop)
                    let r := 0
                    switch payload
                    case 16 {
                        /* UMINUS */
                        r := sub(0, a)
                    }
                    case 34 {
                        /* NOT   */
                        r := iszero(iszero(iszero(a)))
                    }
                    default {
                        mstore(0x00, 0xba41e53700000000000000000000000000000000000000000000000000000000)
                        mstore(0x04, payload)
                        revert(0x00, 0x24)
                    }
                    mstore(vTop, r)
                    vTop := add(vTop, 0x20)
                }
                case 3 {
                    /* APPLY_IF */
                    // Pop elseVal (top), thenVal, cond.
                    vTop := sub(vTop, 0x20)
                    let elseVal := mload(vTop)
                    vTop := sub(vTop, 0x20)
                    let thenVal := mload(vTop)
                    vTop := sub(vTop, 0x20)
                    let condVal := mload(vTop)
                    let r := elseVal
                    if iszero(iszero(condVal)) { r := thenVal }
                    mstore(vTop, r)
                    vTop := add(vTop, 0x20)
                }
                case 4 {
                    /* APPLY_SUM */
                    let cnt := payload
                    let s := 0
                    for { let i := 0 } lt(i, cnt) { i := add(i, 1) } {
                        vTop := sub(vTop, 0x20)
                        s := add(s, mload(vTop))
                    }
                    mstore(vTop, s)
                    vTop := add(vTop, 0x20)
                }
            }

            // The result is the single value left on the value stack.
            vTop := sub(vTop, 0x20)
            result := mload(vTop)
            nextPos := sub(p, nlOff)
            // Restore free memory pointer (stacks were scratch space).
            mstore(0x40, freePtr)
        }
    }
}
