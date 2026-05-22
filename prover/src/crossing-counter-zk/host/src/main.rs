use std::fs;
use std::time::Instant;

use methods::{METHOD_ELF, METHOD_ID};
use risc0_zkvm::{default_prover, ExecutorEnv, InnerReceipt, ProverOpts};
use serde::{Deserialize, Serialize};

/// Must match the guest's VerifyInput.
#[derive(Serialize, Deserialize)]
struct VerifyInput {
    coords: Vec<(i64, i64)>,
    edges: Vec<(u32, u32)>,
    is_complete: bool,
}

/// Must match the guest's VerifyOutput.
#[derive(Serialize, Deserialize)]
struct VerifyOutput {
    crossing_count: u64,
    input_hash: [u8; 32],
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

impl Fixture {
    fn to_verify_input(&self) -> VerifyInput {
        let coords = self.flat_coords.chunks(2).map(|c| (c[0], c[1])).collect();
        let edges = self.flat_edges.chunks(2).map(|c| (c[0], c[1])).collect();
        VerifyInput {
            coords,
            edges,
            is_complete: self.is_complete,
        }
    }
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

fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::filter::EnvFilter::from_default_env())
        .init();

    let groth16_mode = std::env::args().any(|a| a == "--groth16");

    let fixtures = load_fixtures();

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

        let input = fixture.to_verify_input();

        let env = ExecutorEnv::builder()
            .write(&input)
            .unwrap()
            .build()
            .unwrap();

        let prover = default_prover();

        let start = Instant::now();
        let prove_info = prover.prove_with_opts(env, METHOD_ELF, &opts).unwrap();
        let proving_time = start.elapsed();

        let receipt = prove_info.receipt;
        let stats = prove_info.stats;

        let output: VerifyOutput = receipt.journal.decode().unwrap();

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
