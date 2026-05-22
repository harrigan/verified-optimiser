use std::fs;
use std::time::Instant;

use alloy::primitives::{Address, Bytes, I256};
use clap::Parser;
use methods::{METHOD_ELF, METHOD_ID};
use risc0_steel::ethereum::{EthEvmEnv, ETH_HOLESKY_CHAIN_SPEC, ETH_MAINNET_CHAIN_SPEC,
    ETH_SEPOLIA_CHAIN_SPEC};
use risc0_steel::Contract as SteelContract;
use risc0_zkvm::{default_executor, default_prover, ExecutorEnv, InnerReceipt, ProverOpts};
use serde::Deserialize;
use shared::{GuestInput, INLVerifier, VerifyOutput};

#[derive(Deserialize)]
struct SolutionInput {
    vars: Vec<i64>,
    /// Optional path to NL file (alternative to --nl flag).
    nl_path: Option<String>,
}

#[derive(Parser)]
struct Args {
    /// HTTP RPC URL of the target chain.
    #[arg(long)]
    rpc_url: String,

    /// Deployed NLVerifier contract address (0x-prefixed).
    #[arg(long)]
    contract: String,

    /// Path to JSON file with {"vars": [i64, ...], "nl_path": "..."}.
    #[arg(long)]
    vars: String,

    /// Path to the NL file.  Overrides nl_path in the vars JSON.
    #[arg(long)]
    nl: Option<String>,

    /// Produce Groth16 proof and export to proofs/.
    #[arg(long)]
    groth16: bool,

    /// Execute only: count cycles and segments without generating a proof.
    #[arg(long)]
    execute_only: bool,

    /// Target chain: mainnet, sepolia, or holesky.
    #[arg(long, default_value = "mainnet")]
    chain: String,
}

fn chain_spec(name: &str) -> (&'static risc0_steel::ethereum::EthChainSpec, u64) {
    match name.to_lowercase().as_str() {
        "mainnet" => (&ETH_MAINNET_CHAIN_SPEC, 1),
        "sepolia" => (&ETH_SEPOLIA_CHAIN_SPEC, 11155111),
        "holesky" => (&ETH_HOLESKY_CHAIN_SPEC, 17000),
        _ => panic!("unsupported chain: {name} (expected mainnet, sepolia, or holesky)"),
    }
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::filter::EnvFilter::from_default_env())
        .init();

    let args = Args::parse();

    let contract_addr: Address = args
        .contract
        .parse()
        .expect("invalid contract address");

    let solution: SolutionInput = serde_json::from_str(
        &fs::read_to_string(&args.vars)
            .unwrap_or_else(|_| panic!("vars file not found: {}", args.vars)),
    )
    .expect("invalid vars JSON (expected {\"vars\": [...]})");

    // Resolve the NL file path: --nl flag takes priority, then nl_path in JSON.
    let nl_path = args
        .nl
        .or(solution.nl_path)
        .expect("NL file path required (--nl flag or nl_path in vars JSON)");
    let nl_file = fs::read(&nl_path)
        .unwrap_or_else(|_| panic!("NL file not found: {nl_path}"));

    let rpc_url: url::Url = args.rpc_url.parse().expect("invalid RPC URL");
    let (spec, chain_id) = chain_spec(&args.chain);

    if args.groth16 {
        println!("=== Groth16 mode (proofs will be exported to proofs/) ===\n");
        fs::create_dir_all("proofs").unwrap();

        let id_bytes: Vec<u8> = METHOD_ID.iter().flat_map(|w| w.to_le_bytes()).collect();
        let image_id_hex = hex(&id_bytes);
        fs::write("proofs/image_id.txt", &image_id_hex).unwrap();
    }

    let opts = if args.groth16 {
        ProverOpts::groth16()
    } else {
        ProverOpts::default()
    };

    // Build the verify(nl, vars) call.
    let nl = Bytes::from(nl_file.clone());
    let vars: Vec<I256> = solution
        .vars
        .iter()
        .map(|&x| I256::try_from(x as i128).unwrap())
        .collect();
    let call = INLVerifier::verifyCall { nl, vars };

    // Build EthEvmEnv and preflight.
    let mut env = EthEvmEnv::builder()
        .rpc(rpc_url)
        .chain_spec(spec)
        .build()
        .await
        .unwrap();

    let mut contract = SteelContract::preflight(contract_addr, &mut env);
    let mut builder = contract.call_builder(&call);
    builder.tx.gas_limit = u64::MAX;
    let preflight_result = builder.call().await.unwrap();
    println!("  preflight objective: {}", preflight_result.as_i64());

    // Serialise EVM input for guest.
    let evm_input = env.into_input().await.unwrap();

    let guest_input = GuestInput {
        contract_address: contract_addr.into_array(),
        nl_file,
        flat_vars: solution.vars,
        chain_id,
    };

    let executor_env = ExecutorEnv::builder()
        .write(&evm_input)
        .unwrap()
        .write(&guest_input)
        .unwrap()
        .build()
        .unwrap();

    if args.execute_only {
        let start = Instant::now();
        let session = default_executor()
            .execute(executor_env, METHOD_ELF)
            .unwrap();
        let execute_time = start.elapsed();

        let journal_bytes = &session.journal.bytes;
        let output_words: Vec<u32> = journal_bytes[96..]
            .chunks(4)
            .map(|c| u32::from_le_bytes(c.try_into().unwrap()))
            .collect();
        let output: VerifyOutput = risc0_zkvm::serde::from_slice(&output_words).unwrap();

        let total_cycles: u64 = session.segments.iter().map(|s| 1u64 << s.po2).sum();
        let user_cycles = session.cycles();

        println!("  objective:      {}", output.objective);
        println!("  nl_file_hash:   {}", hex(&output.nl_file_hash));
        println!("  solution_hash:  {}", hex(&output.solution_hash));
        println!("  execute_time:   {:.2?}", execute_time);
        println!("  segments:       {}", session.segments.len());
        println!("  total_cycles:   {}", total_cycles);
        println!("  user_cycles:    {}", user_cycles);
        return;
    }

    let prover = default_prover();

    let start = Instant::now();
    let prove_info = prover
        .prove_with_opts(executor_env, METHOD_ELF, &opts)
        .unwrap();
    let proving_time = start.elapsed();

    let receipt = prove_info.receipt;
    let stats = prove_info.stats;

    // Decode journal: skip 96-byte Steel commitment, then VerifyOutput.
    let journal_bytes = &receipt.journal.bytes;
    let output_words: Vec<u32> = journal_bytes[96..]
        .chunks(4)
        .map(|c| u32::from_le_bytes(c.try_into().unwrap()))
        .collect();
    let output: VerifyOutput = risc0_zkvm::serde::from_slice(&output_words).unwrap();

    println!("  objective:      {}", output.objective);
    println!("  nl_file_hash:   {}", hex(&output.nl_file_hash));
    println!("  solution_hash:  {}", hex(&output.solution_hash));
    println!("  proving_time:   {:.2?}", proving_time);
    println!("  segments:       {}", stats.segments);
    println!("  total_cycles:   {}", stats.total_cycles);
    println!("  user_cycles:    {}", stats.user_cycles);

    if args.groth16 {
        if let InnerReceipt::Groth16(ref groth16) = receipt.inner {
            let seal = &groth16.seal;
            let journal = &receipt.journal.bytes;
            let id_bytes: Vec<u8> =
                METHOD_ID.iter().flat_map(|w| w.to_le_bytes()).collect();
            let image_id = hex(&id_bytes);

            fs::write("proofs/seal.bin", seal).unwrap();
            fs::write("proofs/journal.bin", journal).unwrap();

            let summary = format!(
                "seal:      0x{}\njournal:   0x{}\nimage_id:  0x{}\nseal_len:  {}\n",
                hex(seal),
                hex(journal),
                image_id,
                seal.len(),
            );
            fs::write("proofs/proof.txt", &summary).unwrap();

            println!("  seal_size:      {} bytes", seal.len());
            println!("  journal_size:   {} bytes", journal.len());
            println!("  exported:       proofs/");
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

    receipt.verify(METHOD_ID).unwrap();
    println!("  receipt verified OK");
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
}
