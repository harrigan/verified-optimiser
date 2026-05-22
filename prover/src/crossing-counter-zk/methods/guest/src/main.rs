use risc0_zkvm::guest::env;
use risc0_zkvm::sha::Impl as Sha256;
use risc0_zkvm::sha::Sha256 as _;
use serde::{Deserialize, Serialize};

/// Input from the host: vertex coordinates and edge list.
#[derive(Serialize, Deserialize)]
struct VerifyInput {
    /// Vertex coordinates as (x, y) pairs.
    coords: Vec<(i64, i64)>,
    /// Edge list as (u, v) index pairs.  Empty means complete graph.
    edges: Vec<(u32, u32)>,
    /// If true, use the optimised four-tuple path for complete graphs.
    is_complete: bool,
}

/// Output committed to the journal.
#[derive(Serialize, Deserialize)]
struct VerifyOutput {
    /// Number of edge crossings.
    crossing_count: u64,
    /// SHA-256 hash of the serialised input, binding the proof to specific data.
    input_hash: [u8; 32],
}

/// 2D cross product: (b - a) × (c - a).
/// Returns a value whose sign indicates orientation.
fn cross2d(ax: i64, ay: i64, bx: i64, by: i64, cx: i64, cy: i64) -> i128 {
    let dx1 = (bx - ax) as i128;
    let dy1 = (by - ay) as i128;
    let dx2 = (cx - ax) as i128;
    let dy2 = (cy - ay) as i128;
    dx1 * dy2 - dy1 * dx2
}

/// Returns 1 if segments AB and CD intersect, 0 otherwise.
/// Assumes general position (no three vertices collinear).
fn segments_intersect(
    ax: i64, ay: i64, bx: i64, by: i64,
    cx: i64, cy: i64, dx: i64, dy: i64,
) -> u64 {
    let d1 = cross2d(ax, ay, bx, by, cx, cy);
    let d2 = cross2d(ax, ay, bx, by, dx, dy);
    let d3 = cross2d(cx, cy, dx, dy, ax, ay);
    let d4 = cross2d(cx, cy, dx, dy, bx, by);
    if (d1 > 0) != (d2 > 0) && (d3 > 0) != (d4 > 0) { 1 } else { 0 }
}

fn main() {
    let input: VerifyInput = env::read();

    let n = input.coords.len();
    let coords = &input.coords;

    // General position check: no three vertices collinear.
    for i in 0..n {
        for j in (i + 1)..n {
            for k in (j + 1)..n {
                let c = cross2d(
                    coords[i].0, coords[i].1,
                    coords[j].0, coords[j].1,
                    coords[k].0, coords[k].1,
                );
                assert!(c != 0, "vertices {}, {}, {} are collinear", i, j, k);
            }
        }
    }

    // Count crossings.
    let crossings = if input.is_complete {
        // Optimised four-tuple path for complete graphs.
        let mut count: u64 = 0;
        for i in 0..n {
            for j in (i + 1)..n {
                for k in (j + 1)..n {
                    for l in (k + 1)..n {
                        let (ix, iy) = coords[i];
                        let (jx, jy) = coords[j];
                        let (kx, ky) = coords[k];
                        let (lx, ly) = coords[l];
                        count += segments_intersect(ix, iy, jx, jy, kx, ky, lx, ly);
                        count += segments_intersect(ix, iy, kx, ky, jx, jy, lx, ly);
                        count += segments_intersect(ix, iy, lx, ly, jx, jy, kx, ky);
                    }
                }
            }
        }
        count
    } else {
        // General path: test all non-adjacent edge pairs.
        let edges = &input.edges;
        let m = edges.len();
        let mut count: u64 = 0;
        for i in 0..m {
            for j in (i + 1)..m {
                let (a, b) = edges[i];
                let (c, d) = edges[j];
                if a != c && a != d && b != c && b != d {
                    count += segments_intersect(
                        coords[a as usize].0, coords[a as usize].1,
                        coords[b as usize].0, coords[b as usize].1,
                        coords[c as usize].0, coords[c as usize].1,
                        coords[d as usize].0, coords[d as usize].1,
                    );
                }
            }
        }
        count
    };

    // Hash the serialised input to bind the proof to this specific data.
    let input_bytes = risc0_zkvm::serde::to_vec(&input).unwrap();
    // Convert u32 words to bytes for hashing.
    let input_bytes_u8: Vec<u8> = input_bytes.iter().flat_map(|w| w.to_le_bytes()).collect();
    let digest = Sha256::hash_bytes(&input_bytes_u8);
    let input_hash: [u8; 32] = digest.as_bytes().try_into().unwrap();

    let output = VerifyOutput {
        crossing_count: crossings,
        input_hash,
    };

    env::commit(&output);
}
