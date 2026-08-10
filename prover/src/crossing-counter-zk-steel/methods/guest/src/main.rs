use alloy_primitives::{Address, I256};
use alloy_sol_types::sol;
use risc0_steel::ethereum::{EthEvmInput, ETH_MAINNET_CHAIN_SPEC};
use risc0_steel::Contract;
use risc0_zkvm::guest::env;
use risc0_zkvm::sha::Impl as Sha256;
use risc0_zkvm::sha::Sha256 as _;
use serde::{Deserialize, Serialize};

sol! {
    interface ICrossingCount {
        function verify(
            int256[] calldata coords,
            uint8[] calldata flatEdges,
            bool isComplete
        ) external pure returns (uint256 crossings);
    }
}

/// Data sent by the host for constructing the call and computing the
/// input hash (compatible with the existing guest's VerifyInput).
#[derive(Serialize, Deserialize)]
struct GuestInput {
    contract_address: [u8; 20],
    flat_coords: Vec<i64>,
    flat_edges: Vec<u8>,
    is_complete: bool,
}

/// Must match the existing guest's VerifyInput so that the input hash
/// is identical.
#[derive(Serialize, Deserialize)]
struct VerifyInput {
    coords: Vec<(i64, i64)>,
    edges: Vec<(u32, u32)>,
    is_complete: bool,
}

/// Output committed to the journal.  Extends the existing guest's format
/// with the address of the CrossingCounter contract that was executed,
/// binding the proof to that exact deployment.
#[derive(Serialize, Deserialize)]
struct VerifyOutput {
    crossing_count: u64,
    input_hash: [u8; 32],
    contract_address: [u8; 20],
}

fn main() {
    // 1. Read Steel EVM input (block header + state/storage proofs).
    let evm_input: EthEvmInput = env::read();

    // 2. Read our fixture/call data.
    let guest_input: GuestInput = env::read();

    // 3. Build EVM environment (validates block header against chain spec).
    let evm_env = evm_input.into_env(&ETH_MAINNET_CHAIN_SPEC);

    // 4. Commit Steel block commitment to journal (96 bytes ABI-encoded).
    env::commit_slice(&evm_env.commitment().abi_encode());

    // 5. Build the Solidity call.
    let coords: Vec<I256> = guest_input
        .flat_coords
        .iter()
        .map(|&x| I256::try_from(x as i128).unwrap())
        .collect();
    let call = ICrossingCount::verifyCall {
        coords,
        flatEdges: guest_input.flat_edges.clone(),
        isComplete: guest_input.is_complete,
    };

    // 6. Execute via Steel's EVM interpreter inside the zkVM.
    let contract_addr = Address::from(guest_input.contract_address);
    let contract = Contract::new(contract_addr, &evm_env);
    let returns = contract.call_builder(&call).call();
    let crossing_count: u64 = returns.try_into().unwrap();

    // 7. Compute input hash (same as existing guest for compatibility).
    let verify_input = VerifyInput {
        coords: guest_input
            .flat_coords
            .chunks(2)
            .map(|c| (c[0], c[1]))
            .collect(),
        edges: guest_input
            .flat_edges
            .chunks(2)
            .map(|c| (c[0] as u32, c[1] as u32))
            .collect(),
        is_complete: guest_input.is_complete,
    };
    let input_words = risc0_zkvm::serde::to_vec(&verify_input).unwrap();
    let input_bytes: Vec<u8> = input_words.iter().flat_map(|w| w.to_le_bytes()).collect();
    let digest = Sha256::hash_bytes(&input_bytes);
    let input_hash: [u8; 32] = digest.as_bytes().try_into().unwrap();

    // 8. Commit output.  The contract address binds the proof to the exact
    //    CrossingCounter deployment whose bytecode was executed.
    let output = VerifyOutput {
        crossing_count,
        input_hash,
        contract_address: guest_input.contract_address,
    };
    env::commit(&output);
}
