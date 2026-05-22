# A Trustless System for Proposing Optimisation Problems and Verifying Solutions

## Abstract

Many optimisation problems exhibit a fundamental asymmetry: solutions
are hard to find but cheap to verify.  We present a system on Ethereum
that lets anyone propose an optimisation problem with a bounty and
lets anyone else submit a solution, with verification and payout
handled trustlessly by smart contracts.

The system moves verification off-chain via zero-knowledge proofs
(RISC Zero Groth16), providing constant-cost on-chain verification
(~371k gas) regardless of problem size, and scaling beyond the EVM
block gas limit where direct on-chain verification is impossible.
Problems are encoded in the NL file format (AMPL's solver interface)
and attached as blob sidecars (EIP-4844), solutions are submitted via
a commit-reveal
scheme (ERC-5732) to prevent front-running, and bounties are managed
through a bounty escrow mechanism.  A single central contract
coordinates problem registration, ZK verification, and payout.

A key design choice is a stateless Solidity verifier that parses NL
files directly.  The same `verify(nlFile, vars)` function serves both
paths: called on-chain for direct verification, or executed off-chain
inside the RISC Zero zkVM via Steel for indirect verification.  The NL
file carried in the blob sidecar is passed straight to the verifier as
calldata, with no intermediate compilation or per-problem contract
storage.  This eliminates separate verification implementations and
guarantees equivalence between the two paths.

We validate the design by comparing direct on-chain verification
against indirect verification using the rectilinear crossing number as
a case study.  Direct verification gas scales linearly with the number
of non-adjacent edge pairs (~430 gas/pair), while indirect
verification costs a constant ~371k gas.  The crossover occurs at
approximately 700 edge pairs for complete graphs; beyond this, indirect
is both cheaper and the only strategy that can scale.

## Build

Contracts (requires [Foundry](https://book.getfoundry.sh/)):

```
cd contracts
forge soldeer install
forge build
forge test
```

Prover (requires the [RISC Zero
toolchain](https://dev.risczero.com/api/zkvm/install)):

```
cd prover
cargo build --release
```
