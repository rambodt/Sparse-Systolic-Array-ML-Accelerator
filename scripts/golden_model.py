#!/usr/bin/env python3
"""
Golden model for the Sparse Systolic Array Matrix Accelerator.

Implements tiled INT8 GEMM in the exact loop order executed by the DMA controller
(tile_m -> tile_n -> tile_k inner loop). Validates against numpy ground truth.
Run with --mode test to execute the directed test suite from Section 12.4.
"""

import numpy as np
import argparse
import sys
import os

ARRAY_SIZE = 16
DATA_WIDTH = 8


def gemm_reference(A: np.ndarray, B: np.ndarray) -> np.ndarray:
    """Numpy ground truth. A: [M,K] int8, B: [K,N] int8 -> C: [M,N] int32."""
    return A.astype(np.int32) @ B.astype(np.int32)


def gemm_tiled(A: np.ndarray, B: np.ndarray, tile_size: int = ARRAY_SIZE) -> np.ndarray:
    """
    Hardware-equivalent tiled GEMM.
    Loop order matches the DMA tiling controller exactly: tile_m -> tile_n -> tile_k.
    Accumulation mirrors output_buffer.sv: accum_clear at the start of each (m,n) tile,
    then accum_en for each k tile.
    """
    M, K = A.shape
    K2, N = B.shape
    assert K == K2, f"Shape mismatch: A is {M}x{K}, B is {K2}x{N}"
    assert M % tile_size == 0, f"M={M} must be divisible by tile_size={tile_size}"
    assert K % tile_size == 0, f"K={K} must be divisible by tile_size={tile_size}"
    assert N % tile_size == 0, f"N={N} must be divisible by tile_size={tile_size}"

    C = np.zeros((M, N), dtype=np.int32)

    for tm in range(M // tile_size):
        for tn in range(N // tile_size):
            accum = np.zeros((tile_size, tile_size), dtype=np.int32)  # accum_clear
            for tk in range(K // tile_size):
                A_tile = A[tm*tile_size:(tm+1)*tile_size,
                           tk*tile_size:(tk+1)*tile_size].astype(np.int32)
                B_tile = B[tk*tile_size:(tk+1)*tile_size,
                           tn*tile_size:(tn+1)*tile_size].astype(np.int32)
                accum += A_tile @ B_tile  # accum_en: C += A_tile x B_tile
            C[tm*tile_size:(tm+1)*tile_size,
              tn*tile_size:(tn+1)*tile_size] = accum

    return C


def apply_sparsity(A: np.ndarray, sparsity: float, rng=None) -> np.ndarray:
    """Zero out approximately `sparsity` fraction of elements in A."""
    if rng is None:
        rng = np.random.default_rng(42)
    mask = rng.random(A.shape) >= sparsity
    return (A * mask).astype(np.int8)


def verify(A: np.ndarray, B: np.ndarray, tile_size: int = ARRAY_SIZE, verbose: bool = True) -> bool:
    """Compare tiled GEMM against numpy reference. Returns True if they match."""
    M, K = A.shape
    _, N = B.shape
    C_ref = gemm_reference(A, B)
    C_hw  = gemm_tiled(A, B, tile_size)
    match = np.array_equal(C_ref, C_hw)

    if verbose:
        tag = f"{M}x{K} x {K}x{N} -> {M}x{N}  tile={tile_size}"
        if match:
            print(f"  PASS  {tag}")
        else:
            diff = np.abs(C_ref.astype(np.int64) - C_hw.astype(np.int64))
            print(f"  FAIL  {tag}  max_diff={diff.max()}  mismatches={(diff>0).sum()}")
            print("  Expected (first 4x4):")
            print(C_ref[:4, :4])
            print("  Got (first 4x4):")
            print(C_hw[:4, :4])

    return match


def run_test_suite(tile_size: int = ARRAY_SIZE) -> bool:
    """Directed test cases from Section 12.4 of the design document."""
    rng = np.random.default_rng(42)
    T = tile_size

    def rand(shape): return rng.integers(-128, 128, shape, dtype=np.int8)

    # Single-nonzero: A has one 1 at [0,0], B is identity -> C should equal 0 except C[0,0]=1
    A_single = np.zeros((T, T), dtype=np.int8)
    A_single[0, 0] = 1
    B_identity = np.eye(T, dtype=np.int8)

    # Checkerboard: alternating 0/1 pattern -> ~50% sparsity
    checker = np.zeros((T, T), dtype=np.int8)
    checker[::2, ::2] = 1
    checker[1::2, 1::2] = 1

    tests = [
        ("Identity A x Random B      (output should equal B)",
            np.eye(T, dtype=np.int8),          rand((T, T))),
        ("All-zeros A x Random B     (output should be 0)",
            np.zeros((T, T), dtype=np.int8),   rand((T, T))),
        ("All-ones A x All-ones B    (output should be T everywhere)",
            np.ones((T, T), dtype=np.int8),    np.ones((T, T), dtype=np.int8)),
        ("Max values (127x127)       (overflow check)",
            np.full((T, T), 127, dtype=np.int8), np.full((T, T), 127, dtype=np.int8)),
        ("Single nonzero A x Identity(isolates one PE path)",
            A_single,                           B_identity),
        ("Checkerboard A x All-ones  (50% sparsity counter check)",
            checker,                            np.ones((T, T), dtype=np.int8)),
        ("Multi-tile 32x32           (first tiling test)",
            rand((32, 32)),                     rand((32, 32))),
        ("Large 64x64                (full DMA tiling loop)",
            rand((64, 64)),                     rand((64, 64))),
    ]

    print("=" * 70)
    print(f"Golden Model Directed Test Suite  (tile_size={tile_size})")
    print("=" * 70)

    passed = 0
    for name, A, B in tests:
        print(f"\n[{name}]")
        if verify(A, B, tile_size):
            passed += 1

    print(f"\n{'='*70}")
    print(f"Result: {passed}/{len(tests)} passed")
    print("=" * 70)
    return passed == len(tests)


def generate_stimulus(A: np.ndarray, B: np.ndarray, out_dir: str = "tb/stimulus", prefix: str = "stim") -> None:
    """
    Write A, B tile data and expected C output to CSV for SystemVerilog testbenches.
    Each file contains one word per line, decimal encoded, row-major order.
    """
    os.makedirs(out_dir, exist_ok=True)

    def save(name, arr):
        path = os.path.join(out_dir, f"{prefix}_{name}.csv")
        np.savetxt(path, arr.flatten().astype(np.int32), fmt="%d")
        return path

    C = gemm_reference(A, B)
    p_A = save("A", A.view(np.uint8))
    p_B = save("B", B.view(np.uint8))
    p_C = save("C_expected", C)

    M, K = A.shape
    _, N = B.shape
    actual_sparsity = (A == 0).mean()
    print(f"Stimulus for {M}x{K} x {K}x{N} GEMM (sparsity={actual_sparsity:.1%})")
    print(f"  {p_A}")
    print(f"  {p_B}")
    print(f"  {p_C}")


def main():
    parser = argparse.ArgumentParser(
        description="Systolic Array Accelerator — Golden Model",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Modes:
  test      Run the directed test suite (default)
  verify    Verify a randomly generated MxKxN GEMM with optional sparsity
  stimulus  Generate CSV stimulus files for SystemVerilog testbenches

Examples:
  python golden_model.py
  python golden_model.py --mode verify --M 64 --K 64 --N 64 --sparsity 0.5
  python golden_model.py --mode stimulus --M 16 --K 16 --N 16 --output-dir tb/stimulus
""")
    parser.add_argument("--mode", choices=["test", "verify", "stimulus"], default="test")
    parser.add_argument("--M", type=int, default=16, help="Rows of A")
    parser.add_argument("--K", type=int, default=16, help="Shared inner dimension")
    parser.add_argument("--N", type=int, default=16, help="Columns of B")
    parser.add_argument("--tile-size", type=int, default=ARRAY_SIZE)
    parser.add_argument("--sparsity", type=float, default=0.0,
                        help="Fraction of A elements zeroed (0.0–1.0)")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--output-dir", default="tb/stimulus")
    args = parser.parse_args()

    if args.mode == "test":
        ok = run_test_suite(args.tile_size)
        sys.exit(0 if ok else 1)

    rng = np.random.default_rng(args.seed)
    A = rng.integers(-128, 128, (args.M, args.K), dtype=np.int8)
    B = rng.integers(-128, 128, (args.K, args.N), dtype=np.int8)

    if args.sparsity > 0.0:
        A = apply_sparsity(A, args.sparsity, rng)
        print(f"Sparsity applied: {(A == 0).mean():.1%} zeros in A")

    if args.mode == "verify":
        ok = verify(A, B, args.tile_size)
        sys.exit(0 if ok else 1)

    if args.mode == "stimulus":
        generate_stimulus(A, B, args.output_dir)


if __name__ == "__main__":
    main()
