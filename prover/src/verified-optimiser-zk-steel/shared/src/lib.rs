use alloy_sol_types::sol;
use serde::{Deserialize, Serialize};

sol! {
    interface INLVerifier {
        function verify(bytes calldata nl, int256[] calldata vars)
            external pure returns (int256 objective);
    }
}

/// Data sent from host to guest.
#[derive(Serialize, Deserialize)]
pub struct GuestInput {
    pub contract_address: [u8; 20],
    pub nl_file: Vec<u8>,
    pub flat_vars: Vec<i64>,
    pub chain_id: u64,
}

/// Output committed to the journal.  The coordinator contract's
/// `revealIndirect` decodes this after the 96-byte Steel commitment.
///
/// Journal layout (risc0-serde, after Steel commitment):
///   i64 LE: objective (2 u32 words)
///   32 x u32 LE: nl_file_hash bytes (sha256 of NL file)
///   32 x u32 LE: solution_hash bytes (sha256 of ABI-encoded vars)
///   20 x u32 LE: contract_address bytes (the NLVerifier the guest called)
#[derive(Serialize, Deserialize)]
pub struct VerifyOutput {
    pub objective: i64,
    pub nl_file_hash: [u8; 32],
    pub solution_hash: [u8; 32],
    pub contract_address: [u8; 20],
}
