"""
Unit tests for KHeavyhash helper functions.

This module contains comprehensive unit tests for the KHeavyhash helper functions
only, excluding the main hash() method and focusing on the internal implementation
details using pytest framework.
"""

import sys
import time
from unittest.mock import MagicMock

import pytest

sys.path.append("..")
from kheavyhash_ref import KHeavyhash


class TestKHeavyhashHelperFunctions:
    """Test class for KHeavyhash helper functions."""

    def setup_method(self):
        """Set up test fixtures before each test method."""
        self.khash = KHeavyhash()
        self.test_pre_pow_hash = b"\x01\x01\x03\x04" * 8  # 32 bytes
        self.test_timestamp = 1234567890
        self.test_nonce = 9876543210

    def test_construct_header(self):
        """Test header construction helper function."""
        header = self.khash._construct_header(
            self.test_pre_pow_hash, self.test_timestamp, self.test_nonce
        )

        # Test basic properties
        assert isinstance(header, bytes)
        assert len(header) == 80

        # Test that header contains input data
        assert self.test_pre_pow_hash in header

        # Test deterministic behavior
        header2 = self.khash._construct_header(
            self.test_pre_pow_hash, self.test_timestamp, self.test_nonce
        )
        assert header == header2

        # Test different inputs produce different headers
        header3 = self.khash._construct_header(
            self.test_pre_pow_hash, self.test_timestamp + 1, self.test_nonce
        )
        assert header != header3

        # Test header structure (assuming pre_pow_hash + timestamp + nonce + padding)
        # First 32 bytes should be pre_pow_hash
        assert header[:32] == self.test_pre_pow_hash

    def test_construct_header_edge_cases(self):
        """Test header construction with edge case values."""
        # Test with maximum timestamp and nonce
        max_timestamp = 2**63 - 1
        max_nonce = 2**64 - 1
        header = self.khash._construct_header(
            self.test_pre_pow_hash, max_timestamp, max_nonce
        )
        assert len(header) == 80

        # Test with minimum values
        min_timestamp = 0
        min_nonce = 0
        header = self.khash._construct_header(
            self.test_pre_pow_hash, min_timestamp, min_nonce
        )
        assert len(header) == 80

    def test_cshake256_implementation(self):
        """Test _cshake256_myImplimentaion against _cshake256 reference implementation."""

        # Test 1: Basic functionality with custom function name and customization
        data = b"test data"
        output_len = 32
        function_name = "TestFunction"
        customization = "TestCustomization"

        reference_result = self.khash._cshake256(
            data, output_len, function_name, customization
        )
        test_result = self.khash._cshake256_myImplimentaion(
            data, output_len, function_name, customization
        )

        assert isinstance(test_result, bytes), "Result should be bytes"
        assert len(test_result) == output_len, (
            f"Expected {output_len} bytes, got {len(test_result)}"
        )
        assert test_result == reference_result, (
            f"Basic test failed: got {test_result.hex()}, expected {reference_result.hex()}"
        )

        # Test deterministic behavior
        test_result2 = self.khash._cshake256_myImplimentaion(
            data, output_len, function_name, customization
        )
        assert test_result == test_result2, "Implementation is not deterministic"

        # Test different outputs for different inputs
        reference_result3 = self.khash._cshake256(
            data + b"x", output_len, function_name, customization
        )
        test_result3 = self.khash._cshake256_myImplimentaion(
            data + b"x", output_len, function_name, customization
        )
        assert test_result != test_result3, (
            "Different inputs should produce different outputs"
        )
        assert test_result3 == reference_result3, "Different input test failed"

        # Test 2: ProofOfWorkHash function name with empty customization
        function_name = "ProofOfWorkHash"
        customization = ""

        reference_result = self.khash._cshake256(
            data, output_len, function_name, customization
        )
        test_result = self.khash._cshake256_myImplimentaion(
            data, output_len, function_name, customization
        )
        assert test_result == reference_result, (
            f"ProofOfWorkHash test failed: got {test_result.hex()}, expected {reference_result.hex()}"
        )

        # Test 3: HeavyHash function name with empty customization
        function_name = "HeavyHash"

        reference_result = self.khash._cshake256(
            data, output_len, function_name, customization
        )
        test_result = self.khash._cshake256_myImplimentaion(
            data, output_len, function_name, customization
        )
        assert test_result == reference_result, (
            f"HeavyHash test failed: got {test_result.hex()}, expected {reference_result.hex()}"
        )

        # Test 4: Varying output lengths
        data = b"test"
        function_name = "Test"
        customization = ""

        for length in [16, 32, 64, 128]:
            reference_result = self.khash._cshake256(
                data, length, function_name, customization
            )
            test_result = self.khash._cshake256_myImplimentaion(
                data, length, function_name, customization
            )

            assert len(test_result) == length, (
                f"Wrong length for {length} bytes: got {len(test_result)}"
            )
            assert isinstance(test_result, bytes), (
                f"Result should be bytes for length {length}"
            )
            assert test_result == reference_result, (
                f"Length {length} test failed: got {test_result.hex()}, expected {reference_result.hex()}"
            )

        # Test 5: Empty inputs
        # Empty data
        reference_result = self.khash._cshake256(b"", 32, "Test", "")
        test_result = self.khash._cshake256_myImplimentaion(b"", 32, "Test", "")
        assert len(test_result) == 32, "Empty data test: wrong length"
        assert test_result == reference_result, (
            f"Empty data test failed: got {test_result.hex()}, expected {reference_result.hex()}"
        )

        # Empty function name and customization
        reference_result = self.khash._cshake256(b"data", 32, "", "")
        test_result = self.khash._cshake256_myImplimentaion(b"data", 32, "", "")
        assert len(test_result) == 32, "Empty function name test: wrong length"
        assert test_result == reference_result, (
            f"Empty function name test failed: got {test_result.hex()}, expected {reference_result.hex()}"
        )

        # Verify different from non-empty inputs
        reference_result3 = self.khash._cshake256(b"data", 32, "Test", "Custom")
        test_result3 = self.khash._cshake256_myImplimentaion(
            b"data", 32, "Test", "Custom"
        )
        assert test_result != test_result3, (
            "Empty vs non-empty should produce different outputs"
        )
        assert test_result3 == reference_result3, (
            f"Non-empty inputs test failed: got {test_result3.hex()}, expected {reference_result3.hex()}"
        )

    def test_generate_matrix_basic(self):
        """Test matrix generation helper function."""
        matrix = self.khash._generate_matrix(self.test_pre_pow_hash)

        # Test matrix structure
        assert isinstance(matrix, list)
        assert len(matrix) == 64  # 64x64 matrix
        assert all(len(row) == 64 for row in matrix)

        # Test element values are in GF(16) range
        assert all(all(0 <= element <= 15 for element in row) for row in matrix)

        # Test deterministic behavior
        matrix2 = self.khash._generate_matrix(self.test_pre_pow_hash)
        assert matrix == matrix2

        # Test different matrices for different inputs
        matrix3 = self.khash._generate_matrix(b"\x01" + b"\x00" * 31)
        assert matrix != matrix3

    def test_generate_matrix_verbose_mode(self):
        """Test matrix generation with verbose mode."""
        # Test that verbose mode doesn't change the result
        matrix1 = self.khash._generate_matrix(self.test_pre_pow_hash, verbose=False)
        matrix2 = self.khash._generate_matrix(self.test_pre_pow_hash, verbose=True)
        assert matrix1 == matrix2

    def test_init_xoshiro256pp(self):
        """Test xoshiro256++ initialization helper."""
        seed = b"\x12\x34\x56\x78" * 8  # 32 bytes

        state = self.khash._init_xoshiro256pp(seed)

        # Test state structure
        assert isinstance(state, list)
        assert len(state) == 4
        assert all(isinstance(s, int) for s in state)
        assert all(0 <= s < 2**64 for s in state)

        # Test deterministic behavior
        state2 = self.khash._init_xoshiro256pp(seed)
        assert state == state2

        # Test different seeds produce different states
        different_seed = b"\x87\x65\x43\x21" * 8
        state3 = self.khash._init_xoshiro256pp(different_seed)
        assert state != state3

    def test_init_xoshiro256pp_edge_cases(self):
        """Test xoshiro256++ initialization with edge cases."""
        # Test with all zeros seed
        zero_seed = b"\x00" * 32
        state = self.khash._init_xoshiro256pp(zero_seed)
        assert len(state) == 4

        # Test with all ones seed
        ones_seed = b"\xff" * 32
        state = self.khash._init_xoshiro256pp(ones_seed)
        assert len(state) == 4

    def test_xoshiro256pp_next(self):
        """Test xoshiro256++ random number generation helper."""
        state = [1, 2, 3, 4]  # Initial state
        original_state = state[:]

        result = self.khash._xoshiro256pp_next(state)

        # Test return value
        assert isinstance(result, int)
        assert 0 <= result < 2**64

        # Test that state was modified
        assert state != original_state

        # Test sequence generation
        results = []
        state = [1, 2, 3, 4]
        for _ in range(10):
            results.append(self.khash._xoshiro256pp_next(state))

        # All results should be different (with high probability)
        assert len(set(results)) >= 8  # Allow for small chance of duplicates

    def test_xoshiro256pp_next_state_evolution(self):
        """Test that xoshiro256++ state evolves properly."""
        state1 = [123, 456, 789, 101112]
        state2 = state1[:]

        # Generate some numbers and verify states diverge
        for _ in range(5):
            self.khash._xoshiro256pp_next(state1)
            self.khash._xoshiro256pp_next(state2)

        # States should have evolved identically
        assert state1 == state2

        # But if we start from different initial states, they should diverge
        state3 = [124, 456, 789, 101112]  # Slightly different
        self.khash._xoshiro256pp_next(state3)
        assert state1[0] != state3[0]  # Should be different after one step

    def test_check_matrix_rank_full_rank(self):
        """Test matrix rank checking with full-rank matrices."""
        # Create identity matrix (full rank)
        identity_matrix = [[0 for _ in range(64)] for _ in range(64)]
        for i in range(64):
            identity_matrix[i][i] = 1

        assert self.khash._check_matrix_rank(identity_matrix) == True

    def test_check_matrix_rank_deficient(self):
        """Test matrix rank checking with rank-deficient matrices."""
        # All zeros matrix (rank 0)
        zero_matrix = [[0 for _ in range(64)] for _ in range(64)]
        assert self.khash._check_matrix_rank(zero_matrix) == False

        # Matrix with duplicate rows (rank deficient)
        dup_matrix = [[1, 2, 3] + [0] * 61 for _ in range(64)]
        assert self.khash._check_matrix_rank(dup_matrix) == False

    def test_check_matrix_rank_edge_cases(self):
        """Test matrix rank checking edge cases."""
        # Matrix with one non-zero row
        single_row_matrix = [[0 for _ in range(64)] for _ in range(64)]
        single_row_matrix[0][0] = 1
        result = self.khash._check_matrix_rank(single_row_matrix)
        assert isinstance(result, bool)

    def test_create_vector_from_hash(self):
        """Test vector creation from hash helper function."""
        test_hash = b"\x12\x34\x56\x78" * 8  # 32 bytes

        vector = self.khash._create_vector_from_hash(test_hash)

        # Test vector structure
        assert isinstance(vector, list)
        assert len(vector) == 64
        assert all(isinstance(v, int) for v in vector)
        assert all(0 <= v <= 15 for v in vector)  # GF(16) elements

        # Test deterministic behavior
        vector2 = self.khash._create_vector_from_hash(test_hash)
        assert vector == vector2

        # Test different vectors for different hashes
        different_hash = b"\x87\x65\x43\x21" * 8
        vector3 = self.khash._create_vector_from_hash(different_hash)
        assert vector != vector3

    def test_create_vector_from_hash_edge_cases(self):
        """Test vector creation with edge case hashes."""
        # All zeros hash
        zero_hash = b"\x00" * 32
        vector = self.khash._create_vector_from_hash(zero_hash)
        assert len(vector) == 64
        assert all(v == 0 for v in vector)

        # All ones hash
        ones_hash = b"\xff" * 32
        vector = self.khash._create_vector_from_hash(ones_hash)
        assert len(vector) == 64
        assert all(v == 15 for v in vector)  # 0xff & 0xf == 15

    def test_matrix_vector_multiply_comprehensive(self):
        """Comprehensive test for matrix-vector multiplication with multiple scenarios."""

        # Test 1: Identity matrix - all results should be 0 due to normalization
        identity_matrix = [[0 for _ in range(64)] for _ in range(64)]
        for i in range(64):
            identity_matrix[i][i] = 1
        test_vector = [i % 16 for i in range(64)]  # [0,1,2,...,15,0,1,...]
        result = self.khash._matrix_vector_multiply(identity_matrix, test_vector)
        # After normalization: all values 0-15 become 0 when >> 10
        assert all(r == 0 for r in result), (
            f"Identity matrix with small values should produce zeros, got {result[:5]}..."
        )

        # Test 2: Identity matrix with larger values that survive normalization
        large_identity = [[0 for _ in range(64)] for _ in range(64)]
        for i in range(64):
            large_identity[i][i] = 1024  # 1024 * vector_element
        large_vector = [1] * 64  # All ones
        result_large = self.khash._matrix_vector_multiply(large_identity, large_vector)
        # Expected: (1024 * 1) >> 10 = 1024 >> 10 = 1
        assert all(r == 1 for r in result_large), (
            f"Large identity test failed: expected all 1s, got {result_large[:5]}..."
        )

        # Test 3: Zero matrix should produce all zeros
        zero_matrix = [[0 for _ in range(64)] for _ in range(64)]
        result_zero = self.khash._matrix_vector_multiply(zero_matrix, test_vector)
        assert all(r == 0 for r in result_zero), "Zero matrix should produce zeros"

        # Test 4: Test normalization with maximum values
        max_matrix = [[15 for _ in range(64)] for _ in range(64)]
        max_vector = [15] * 64
        result_max = self.khash._matrix_vector_multiply(max_matrix, max_vector)
        # Expected: (64 * 15 * 15) >> 10 = 14400 >> 10 = 14, then & 0xF = 14
        expected_normalized = (64 * 15 * 15) >> 10
        assert all(r == expected_normalized for r in result_max), (
            f"Max normalization: expected {expected_normalized}, got {result_max[0]}"
        )

        # Test 5: Reference implementation comparison
        def reference_matrix_vector_multiply(matrix, vector):
            """Reference implementation for comparison."""
            result = []
            for i in range(64):
                dot_product = sum(matrix[i][j] * vector[j] for j in range(64))
                normalized_value = (dot_product >> 10) & 0xF
                result.append(normalized_value)
            return result

        # Test with deterministic "random" matrix
        import random

        random.seed(42)
        test_matrix = [[random.randint(0, 15) for _ in range(64)] for _ in range(64)]
        test_vector_rand = [random.randint(0, 15) for _ in range(64)]

        result_impl = self.khash._matrix_vector_multiply(test_matrix, test_vector_rand)
        result_ref = reference_matrix_vector_multiply(test_matrix, test_vector_rand)

        assert result_impl == result_ref, "Implementation doesn't match reference"

    def test_matrix_vector_multiply_against_numpy(self):
        """Test against numpy if available (optional test)."""
        np = pytest.importorskip("numpy", reason="NumPy not available for comparison")

        # Create test data
        matrix = np.random.randint(0, 16, (64, 64))
        vector = np.random.randint(0, 16, 64)

        # Our implementation
        result_ours = self.khash._matrix_vector_multiply(
            matrix.tolist(), vector.tolist()
        )

        # NumPy reference
        dot_products = np.dot(matrix, vector)
        result_numpy = ((dot_products >> 10) & 0xF).tolist()

        assert result_ours == result_numpy, "Results don't match NumPy implementation"

    def test_xor_with_hash(self):
        """Test XOR operation with hash helper function."""
        product_vector = [i % 16 for i in range(64)]  # Test vector
        hash_value = b"\xaa" * 32  # Test hash

        result = self.khash._xor_with_hash(product_vector, hash_value)

        # Test result structure
        assert isinstance(result, bytes)
        assert len(result) == 32

        # Test deterministic behavior
        result2 = self.khash._xor_with_hash(product_vector, hash_value)
        assert result == result2

        # Test different results for different inputs
        different_vector = [(i + 1) % 16 for i in range(64)]
        result3 = self.khash._xor_with_hash(different_vector, hash_value)
        assert result != result3

    def test_xor_with_hash_edge_cases(self):
        """Test XOR operation edge cases."""
        # Zero vector
        zero_vector = [0] * 64
        hash_value = b"\xff" * 32
        result = self.khash._xor_with_hash(zero_vector, hash_value)
        assert len(result) == 32

        # Maximum values
        max_vector = [15] * 64
        result = self.khash._xor_with_hash(max_vector, hash_value)
        assert len(result) == 32

    def test_rotl64(self):
        """Test 64-bit left rotation helper function."""
        test_value = 0x123456789ABCDEF0

        # Test rotation by 0 (identity)
        assert self.khash._rotl64(test_value, 0) == test_value

        # Test rotation by 1
        rotated_1 = self.khash._rotl64(test_value, 1)
        assert isinstance(rotated_1, int)
        assert 0 <= rotated_1 < 2**64

        # Test rotation by 64 (should be identity)
        assert self.khash._rotl64(test_value, 64) == test_value

        # Test multiple rotations
        for shift in [8, 16, 24, 32, 40, 48, 56]:
            rotated = self.khash._rotl64(test_value, shift)
            assert isinstance(rotated, int)
            assert 0 <= rotated < 2**64

    def test_rotl64_edge_cases(self):
        """Test 64-bit rotation with edge cases."""
        # Test with 0
        assert self.khash._rotl64(0, 32) == 0

        # Test with maximum 64-bit value
        max_val = 2**64 - 1
        rotated = self.khash._rotl64(max_val, 1)
        assert rotated == max_val  # All 1s rotated should remain all 1s

        # Test large rotation amounts
        test_val = 0x123456789ABCDEF0
        result1 = self.khash._rotl64(test_val, 1)
        result65 = self.khash._rotl64(test_val, 65)  # Should be same as 1
        assert result1 == result65

    def test_matrix_cache_functionality(self):
        """Test matrix caching helper functions."""
        test_matrix = [[i % 16 for i in range(64)] for _ in range(64)]
        test_hash = b"\x12\x34" * 16

        # Test setting cache
        self.khash.set_matrix_cache(test_hash, test_matrix)
        assert self.khash._cached_prepow_hash == test_hash
        assert self.khash._cached_matrix == test_matrix

        # Test getting cached matrix
        cached = self.khash.get_cached_matrix(test_hash)
        assert cached == test_matrix

        # Test cache miss
        different_hash = b"\x56\x78" * 16
        assert self.khash.get_cached_matrix(different_hash) is None

        # Test clearing cache
        self.khash.clear_matrix_cache()
        assert self.khash._cached_matrix is None
        assert self.khash._cached_prepow_hash is None

    def test_matrix_cache_edge_cases(self):
        """Test matrix cache with edge cases."""
        # Test with None values
        self.khash.set_matrix_cache(None, None)
        assert self.khash._cached_prepow_hash is None
        assert self.khash._cached_matrix is None

        # Test multiple cache operations
        hash1 = b"\x11" * 32
        hash2 = b"\x22" * 32
        matrix1 = [[1] * 64 for _ in range(64)]
        matrix2 = [[2] * 64 for _ in range(64)]

        self.khash.set_matrix_cache(hash1, matrix1)
        self.khash.set_matrix_cache(hash2, matrix2)  # Should overwrite

        assert self.khash.get_cached_matrix(hash1) is None  # Old cache lost
        assert self.khash.get_cached_matrix(hash2) == matrix2


# CPU vs GPU batch comparison test class
class TestCpuGpuBatch:
    """Compare hash_cpu_batch and hash_gpu_batch for correctness and performance."""

    # (pre_pow_hash, timestamp, description)
    TEST_VECTORS = [
        (b"\xff" * 32, 0, "All ones"),
        (bytes(range(32)), 0, "Sequential bytes"),
        (b"\xaa\x55" * 16, 0, "Alternating pattern"),
        (bytes(range(32)), 1234567890, "Sequential with timestamp"),
        (b"\xff" * 32, 2**31 - 1, "Max timestamp"),
        (b"\xaa\x55" * 16, 1609459200, "Mixed pattern"),
        (bytes([i % 256 for i in range(32)]), 1640995200, "Modulo pattern"),
        (b"\x12\x34\x56\x78" * 8, 1700000000, "Repeated pattern"),
    ]

    # Nonces used for all correctness tests
    CORRECTNESS_NONCES = list(range(16))

    def setup_method(self):
        self.khash = KHeavyhash()

    def _has_cuda(self) -> bool:
        try:
            import torch

            return torch.cuda.is_available()
        except ImportError:
            return False

    # ── Correctness ───────────────────────────────────────────────────────

    def test_cpu_batch_matches_single_hash(self):
        """hash_cpu_batch must produce identical output to hash() for every nonce."""
        for pre_pow_hash, timestamp, description in self.TEST_VECTORS:
            expected = [
                self.khash.hash(pre_pow_hash, timestamp, n)
                for n in self.CORRECTNESS_NONCES
            ]
            actual = self.khash.hash_cpu_batch(
                pre_pow_hash, timestamp, self.CORRECTNESS_NONCES
            )
            assert actual == expected, (
                f"CPU batch mismatch for '{description}':\n"
                f"  expected[0]: {expected[0].hex()}\n"
                f"  actual[0]:   {actual[0].hex()}"
            )

    def test_gpu_batch_matches_single_hash(self):
        """hash_gpu_batch must produce identical output to hash() for every nonce."""
        if not self._has_cuda():
            pytest.skip("CUDA not available")
        for pre_pow_hash, timestamp, description in self.TEST_VECTORS:
            expected = [
                self.khash.hash(pre_pow_hash, timestamp, n)
                for n in self.CORRECTNESS_NONCES
            ]
            actual = self.khash.hash_gpu_batch(
                pre_pow_hash, timestamp, self.CORRECTNESS_NONCES
            )
            assert actual == expected, (
                f"GPU batch mismatch for '{description}':\n"
                f"  expected[0]: {expected[0].hex()}\n"
                f"  actual[0]:   {actual[0].hex()}"
            )

    def test_cpu_gpu_batch_agree(self):
        """hash_cpu_batch and hash_gpu_batch must return bit-identical results."""
        if not self._has_cuda():
            pytest.skip("CUDA not available")
        failures = []
        for pre_pow_hash, timestamp, description in self.TEST_VECTORS:
            cpu = self.khash.hash_cpu_batch(
                pre_pow_hash, timestamp, self.CORRECTNESS_NONCES
            )
            gpu = self.khash.hash_gpu_batch(
                pre_pow_hash, timestamp, self.CORRECTNESS_NONCES
            )
            if cpu != gpu:
                for i, (c, g) in enumerate(zip(cpu, gpu)):
                    if c != g:
                        failures.append(
                            f"'{description}' nonce={self.CORRECTNESS_NONCES[i]}:\n"
                            f"  CPU: {c.hex()}\n"
                            f"  GPU: {g.hex()}"
                        )
        assert not failures, "CPU/GPU disagreements:\n" + "\n".join(failures)

    def test_cpu_batch_order_preserved(self):
        """Results must be in the same order as the input nonce list."""
        pre_pow_hash = bytes(range(32))
        timestamp = 1700000000
        nonces = [7, 2, 99, 0, 42]
        batch = self.khash.hash_cpu_batch(pre_pow_hash, timestamp, nonces)
        for i, nonce in enumerate(nonces):
            single = self.khash.hash(pre_pow_hash, timestamp, nonce)
            assert batch[i] == single, (
                f"Order broken at index {i} (nonce={nonce}):\n"
                f"  batch:  {batch[i].hex()}\n"
                f"  single: {single.hex()}"
            )

    def test_gpu_batch_order_preserved(self):
        """GPU results must be in the same order as the input nonce list."""
        if not self._has_cuda():
            pytest.skip("CUDA not available")
        pre_pow_hash = bytes(range(32))
        timestamp = 1700000000
        nonces = [7, 2, 99, 0, 42]
        batch = self.khash.hash_gpu_batch(pre_pow_hash, timestamp, nonces)
        for i, nonce in enumerate(nonces):
            single = self.khash.hash(pre_pow_hash, timestamp, nonce)
            assert batch[i] == single, (
                f"Order broken at index {i} (nonce={nonce}):\n"
                f"  batch:  {batch[i].hex()}\n"
                f"  single: {single.hex()}"
            )

    def test_single_nonce_batch(self):
        """Batch of size 1 must equal a direct hash() call."""
        pre_pow_hash = b"\xde\xad\xbe\xef" * 8
        timestamp = 999
        nonce = 1
        assert self.khash.hash_cpu_batch(pre_pow_hash, timestamp, [nonce]) == [
            self.khash.hash(pre_pow_hash, timestamp, nonce)
        ]
        if self._has_cuda():
            assert self.khash.hash_gpu_batch(pre_pow_hash, timestamp, [nonce]) == [
                self.khash.hash(pre_pow_hash, timestamp, nonce)
            ]

    # ── Performance ───────────────────────────────────────────────────────

    def test_performance_comparison(self):
        """Benchmark hash_cpu_batch vs hash_gpu_batch throughput.

        Runs each implementation for BENCH_DURATION seconds with a fixed
        batch size and reports hashes/second.  GPU is warmed up first to
        avoid counting CUDA context initialisation in the measurement.
        """
        BENCH_DURATION = 60.0
        BATCH_SIZE = 1048576

        pre_pow_hash = bytes(range(32))
        timestamp = 1700000000
        nonces = list(range(BATCH_SIZE))

        # ── CPU ───────────────────────────────────────────────────────────
        cpu_count = 0
        cpu_start = time.perf_counter()
        deadline = cpu_start + BENCH_DURATION
        while time.perf_counter() < deadline:
            self.khash.hash_cpu_batch(pre_pow_hash, timestamp, nonces)
            cpu_count += BATCH_SIZE
        cpu_elapsed = time.perf_counter() - cpu_start
        cpu_hps = cpu_count / cpu_elapsed

        print(f"\n{'=' * 60}")
        print(
            f"Batch Performance Comparison"
            f"  (duration: {BENCH_DURATION:.0f}s each, batch={BATCH_SIZE})"
        )
        print(f"{'=' * 60}")
        print(f"CPU:  {cpu_count:>9} hashes  {cpu_elapsed:.2f}s  {cpu_hps:>12.1f} H/s")

        # ── GPU (optional) ────────────────────────────────────────────────
        if self._has_cuda():
            # Warm-up: amortise CUDA context creation outside the timer
            self.khash.hash_gpu_batch(pre_pow_hash, timestamp, nonces[:8])

            gpu_count = 0
            gpu_start = time.perf_counter()
            deadline = gpu_start + BENCH_DURATION
            while time.perf_counter() < deadline:
                self.khash.hash_gpu_batch(pre_pow_hash, timestamp, nonces)
                gpu_count += BATCH_SIZE
            gpu_elapsed = time.perf_counter() - gpu_start
            gpu_hps = gpu_count / gpu_elapsed

            print(
                f"GPU:  {gpu_count:>9} hashes  {gpu_elapsed:.2f}s  {gpu_hps:>12.1f} H/s"
            )
            if gpu_hps >= cpu_hps:
                print(f"GPU is {gpu_hps / cpu_hps:.2f}x faster than CPU")
            else:
                print(f"CPU is {cpu_hps / gpu_hps:.2f}x faster than GPU")
        else:
            print("GPU:  skipped (CUDA not available)")

        print(f"{'=' * 60}")


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
