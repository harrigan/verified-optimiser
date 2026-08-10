use alloy_primitives::{Address, Bytes, I256};
use risc0_steel::ethereum::{EthEvmInput, ETH_HOLESKY_CHAIN_SPEC, ETH_MAINNET_CHAIN_SPEC,
    ETH_SEPOLIA_CHAIN_SPEC};
use risc0_steel::Contract;
use risc0_zkvm::guest::env;
use risc0_zkvm::sha::Impl as Sha256;
use risc0_zkvm::sha::Sha256 as _;
use shared::{GuestInput, INLVerifier, VerifyOutput};

fn main() {
    // 1. Read Steel EVM input (block header + state/storage proofs).
    let evm_input: EthEvmInput = env::read();

    // 2. Read call data.
    let guest_input: GuestInput = env::read();

    // 3. Build EVM environment (validates block header against chain spec).
    let spec = match guest_input.chain_id {
        1 => &ETH_MAINNET_CHAIN_SPEC,
        11155111 => &ETH_SEPOLIA_CHAIN_SPEC,
        17000 => &ETH_HOLESKY_CHAIN_SPEC,
        id => panic!("unsupported chain ID: {id}"),
    };
    let evm_env = evm_input.into_env(spec);

    // 4. Commit Steel block commitment to journal (96 bytes ABI-encoded).
    env::commit_slice(&evm_env.commitment().abi_encode());

    // 5. Build the NLVerifier.verify(nl, vars) call.
    let nl = Bytes::from(guest_input.nl_file.clone());
    let vars: Vec<I256> = guest_input
        .flat_vars
        .iter()
        .map(|&x| I256::try_from(x as i128).unwrap())
        .collect();
    let call = INLVerifier::verifyCall { nl, vars };

    // 6. Execute via Steel's EVM interpreter inside the zkVM.
    let contract_addr = Address::from(guest_input.contract_address);
    let contract = Contract::new(contract_addr, &evm_env);
    let mut builder = contract.call_builder(&call);
    builder.tx.gas_limit = u64::MAX;
    let objective: i64 = builder.call().as_i64();

    // 7. Compute nl_file_hash: sha256 of the raw NL file bytes.
    let nl_digest = Sha256::hash_bytes(&guest_input.nl_file);
    let nl_file_hash: [u8; 32] = nl_digest.as_bytes().try_into().unwrap();

    // 8. Compute solution_hash: sha256 of the flat vars (risc0-serde encoding).
    let input_words = risc0_zkvm::serde::to_vec(&guest_input.flat_vars).unwrap();
    let input_bytes: Vec<u8> = input_words.iter().flat_map(|w| w.to_le_bytes()).collect();
    let sol_digest = Sha256::hash_bytes(&input_bytes);
    let solution_hash: [u8; 32] = sol_digest.as_bytes().try_into().unwrap();

    // 9. Commit output.  The contract address binds the proof to the exact
    //    NLVerifier deployment whose bytecode was executed; the coordinator
    //    checks it against its own NL_VERIFIER.
    let output = VerifyOutput {
        objective,
        nl_file_hash,
        solution_hash,
        contract_address: guest_input.contract_address,
    };
    env::commit(&output);
}
