use std::fs;
use std::time::Instant;

use alloy::network::{EthereumWallet, TransactionBuilder};
use alloy::node_bindings::Anvil;
use alloy::primitives::{Address, Bytes, I256};
use alloy::providers::{Provider, ProviderBuilder};
use alloy::rpc::types::TransactionRequest;
use alloy::sol;
use methods::{METHOD_ELF, METHOD_ID};
use risc0_steel::ethereum::{EthEvmEnv, ETH_MAINNET_CHAIN_SPEC};
use risc0_steel::Contract as SteelContract;
use risc0_zkvm::{default_prover, ExecutorEnv, InnerReceipt, ProverOpts};
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

/// Data sent to the guest.
#[derive(Serialize, Deserialize)]
struct GuestInput {
    contract_address: [u8; 20],
    flat_coords: Vec<i64>,
    flat_edges: Vec<u8>,
    is_complete: bool,
}

/// Must match the guest's VerifyOutput.
#[derive(Serialize, Deserialize)]
struct VerifyOutput {
    crossing_count: u64,
    input_hash: [u8; 32],
    contract_address: [u8; 20],
}

#[derive(Deserialize)]
struct Fixture {
    name: String,
    slug: String,
    flat_coords: Vec<i64>,
    flat_edges: Vec<u32>,
    is_complete: bool,
    expected_crossings: u64,
}

fn fixtures_dir() -> String {
    std::env::var("FIXTURES_DIR").unwrap_or_else(|_| {
        format!("{}/../../../../contracts/benchmark-fixtures", env!("CARGO_MANIFEST_DIR"))
    })
}

fn load_fixtures() -> Vec<Fixture> {
    let dir = fixtures_dir();
    let manifest_json = fs::read_to_string(format!("{}/manifest.json", dir)).unwrap_or_else(|_| {
        panic!("manifest.json not found in {}; set FIXTURES_DIR to a directory containing manifest.json + per-slug fixture JSON files", dir)
    });
    let slugs: Vec<String> = serde_json::from_str(&manifest_json).unwrap();
    slugs
        .into_iter()
        .map(|slug| {
            let path = format!("{}/{}.json", dir, slug);
            let json = fs::read_to_string(&path)
                .unwrap_or_else(|_| panic!("fixture not found: {}", path));
            serde_json::from_str(&json).unwrap()
        })
        .collect()
}

fn load_contract_bytecode() -> Vec<u8> {
    let artifact_path = std::env::var("CROSSING_COUNTER_ARTIFACT").unwrap_or_else(|_| {
        format!(
            "{}/../../../../contracts/out/CrossingCounter.sol/CrossingCounter.json",
            env!("CARGO_MANIFEST_DIR")
        )
    });
    let json = fs::read_to_string(&artifact_path)
        .unwrap_or_else(|_| panic!("artifact not found: {}; run `forge build` in ../contracts first, or set CROSSING_COUNTER_ARTIFACT", artifact_path));
    let artifact: serde_json::Value = serde_json::from_str(&json).unwrap();
    let bytecode_hex = artifact["bytecode"]["object"]
        .as_str()
        .expect("missing bytecode.object in artifact");
    let hex_str = bytecode_hex.strip_prefix("0x").unwrap_or(bytecode_hex);
    alloy::hex::decode(hex_str).unwrap()
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::filter::EnvFilter::from_default_env())
        .init();

    let groth16_mode = std::env::args().any(|a| a == "--groth16");

    let fixtures = load_fixtures();
    let bytecode = load_contract_bytecode();

    // Spawn Anvil with chain_id 1 so the guest can use ETH_MAINNET_CHAIN_SPEC.
    // Use explicit path from HOME to handle environments where ~/.foundry/bin
    // is not on PATH (e.g. nREPL).
    let anvil_path = format!(
        "{}/.foundry/bin/anvil",
        std::env::var("HOME").expect("HOME not set")
    );
    let anvil = Anvil::new().path(anvil_path).chain_id(1).spawn();
    let rpc_url: url::Url = anvil.endpoint().parse().unwrap();

    let signer = alloy::signers::local::PrivateKeySigner::from_signing_key(
        anvil.keys()[0].clone().into(),
    );
    let wallet = EthereumWallet::new(signer);
    let provider = ProviderBuilder::new()
        .wallet(wallet)
        .connect_http(rpc_url.clone());

    // Deploy CrossingCount with empty constructor args (Edge[], false).
    // The Steel path only uses the pure verify(coords, flatEdges, isComplete)
    // function which ignores storage, so constructor args don't affect results.
    let mut deploy_code = bytecode;
    // ABI-encode constructor(Edge[] memory edges, bool isComplete):
    //   word 0: offset to Edge[] data = 0x40 (64)
    //   word 1: isComplete = false
    //   word 2: Edge[].length = 0
    let mut offset_word = [0u8; 32];
    offset_word[31] = 64;
    deploy_code.extend_from_slice(&offset_word);
    deploy_code.extend_from_slice(&[0u8; 32]); // isComplete = false
    deploy_code.extend_from_slice(&[0u8; 32]); // Edge[].length = 0
    let tx = TransactionRequest::default().with_deploy_code(Bytes::from(deploy_code));
    let receipt = provider
        .send_transaction(tx)
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    let contract_addr: Address = receipt.contract_address.expect("deployment failed");
    println!("Deployed CrossingCount at {}", contract_addr);

    if groth16_mode {
        println!("=== Groth16 mode (proofs will be exported to proofs/) ===\n");
        fs::create_dir_all("proofs").unwrap();

        let id_bytes: Vec<u8> = METHOD_ID.iter().flat_map(|w| w.to_le_bytes()).collect();
        let image_id_hex = hex(&id_bytes);
        fs::write("proofs/image_id.txt", &image_id_hex).unwrap();
    }

    let opts = if groth16_mode {
        ProverOpts::groth16()
    } else {
        ProverOpts::default()
    };

    for fixture in &fixtures {
        println!(
            "--- {} (expected: {}) ---",
            fixture.name, fixture.expected_crossings
        );

        // Build the Solidity call arguments.
        let coords: Vec<I256> = fixture
            .flat_coords
            .iter()
            .map(|&x| I256::try_from(x as i128).unwrap())
            .collect();
        let flat_edges: Vec<u8> = fixture.flat_edges.iter().map(|&e| e as u8).collect();
        let call = ICrossingCount::verifyCall {
            coords,
            flatEdges: flat_edges.clone(),
            isComplete: fixture.is_complete,
        };

        // Build EthEvmEnv from Anvil and preflight the call.
        let mut env = EthEvmEnv::builder()
            .rpc(rpc_url.clone())
            .chain_spec(&ETH_MAINNET_CHAIN_SPEC)
            .build()
            .await
            .unwrap();

        let mut contract = SteelContract::preflight(contract_addr, &mut env);
        let preflight_result = contract.call_builder(&call).call().await.unwrap();
        let preflight_crossings: u64 = preflight_result.try_into().unwrap();
        assert_eq!(
            preflight_crossings, fixture.expected_crossings,
            "{}: preflight mismatch",
            fixture.name
        );

        // Serialise the EVM input for the guest.
        let evm_input = env.into_input().await.unwrap();

        let guest_input = GuestInput {
            contract_address: contract_addr.into_array(),
            flat_coords: fixture.flat_coords.clone(),
            flat_edges: flat_edges,
            is_complete: fixture.is_complete,
        };

        let executor_env = ExecutorEnv::builder()
            .write(&evm_input)
            .unwrap()
            .write(&guest_input)
            .unwrap()
            .build()
            .unwrap();

        let prover = default_prover();

        let start = Instant::now();
        let prove_info = prover
            .prove_with_opts(executor_env, METHOD_ELF, &opts)
            .unwrap();
        let proving_time = start.elapsed();

        let receipt = prove_info.receipt;
        let stats = prove_info.stats;

        // Decode the journal: skip 96-byte Steel commitment, then decode VerifyOutput.
        let journal_bytes = &receipt.journal.bytes;
        assert!(
            journal_bytes.len() >= 96 + 216,
            "journal too short: {} bytes",
            journal_bytes.len()
        );
        let output_words: Vec<u32> = journal_bytes[96..]
            .chunks(4)
            .map(|c| u32::from_le_bytes(c.try_into().unwrap()))
            .collect();
        let output: VerifyOutput = risc0_zkvm::serde::from_slice(&output_words).unwrap();

        println!("  crossing_count:  {}", output.crossing_count);
        println!("  input_hash:      {}", hex(&output.input_hash));
        println!("  proving_time:    {:.2?}", proving_time);
        println!("  segments:        {}", stats.segments);
        println!("  total_cycles:    {}", stats.total_cycles);
        println!("  user_cycles:     {}", stats.user_cycles);

        if groth16_mode {
            if let InnerReceipt::Groth16(ref groth16) = receipt.inner {
                let seal = &groth16.seal;
                let journal = &receipt.journal.bytes;
                let id_bytes: Vec<u8> =
                    METHOD_ID.iter().flat_map(|w| w.to_le_bytes()).collect();
                let image_id = hex(&id_bytes);

                let seal_path = format!("proofs/{}_seal.bin", fixture.slug);
                fs::write(&seal_path, seal).unwrap();

                let journal_path = format!("proofs/{}_journal.bin", fixture.slug);
                fs::write(&journal_path, journal).unwrap();

                let summary_path = format!("proofs/{}_proof.txt", fixture.slug);
                let summary = format!(
                    "seal:      0x{}\njournal:   0x{}\nimage_id:  0x{}\nseal_len:  {}\n",
                    hex(seal),
                    hex(journal),
                    image_id,
                    seal.len(),
                );
                fs::write(&summary_path, &summary).unwrap();

                println!("  seal_size:       {} bytes", seal.len());
                println!("  journal_size:    {} bytes", journal.len());
                println!("  exported:        {}", seal_path);
            } else {
                println!("  WARNING: receipt is not Groth16");
            }
        } else {
            let receipt_bytes = bincode::serialize(&receipt).unwrap();
            println!("  paging_cycles:   {}", stats.paging_cycles);
            println!("  reserved_cycles: {}", stats.reserved_cycles);
            println!(
                "  proof_size:      {} bytes ({:.1} KB)",
                receipt_bytes.len(),
                receipt_bytes.len() as f64 / 1024.0
            );
        }

        assert_eq!(
            output.crossing_count, fixture.expected_crossings,
            "{}: expected {} crossings, got {}",
            fixture.name, fixture.expected_crossings, output.crossing_count
        );

        receipt.verify(METHOD_ID).unwrap();
        println!("  receipt verified OK");
    }

    println!("\nAll fixtures passed.");
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
}
