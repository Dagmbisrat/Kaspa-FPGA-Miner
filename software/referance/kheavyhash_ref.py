"""kHeavyHash proof-of-work algorithm implementation for Kaspa."""

import hashlib
import random
import re
import struct
import time
from asyncio.events import AbstractEventLoopPolicy
from string import printable
from typing import List, Optional, Tuple
from webbrowser import get

from Crypto.Hash import cSHAKE256
from Crypto.Hash.keccak import _raw_keccak_lib
from Crypto.Util._raw_api import (
    SmartPointer,
    VoidPointer,
    c_size_t,
    c_ubyte,
    c_uint8_ptr,
    create_string_buffer,
    get_raw_buffer,
)


class KHeavyhash:
    """KHeavyHash proof-of-work algorithm for Kaspa."""

    def __init__(self):
        """Initialize with empty matrix cache."""
        self._cached_matrix = None
        self._cached_prepow_hash = None

    def hash(self, pre_pow_hash: bytes, timestamp: int, nonce: int) -> bytes:
        """
        Compute the complete kHeavyHash for given inputs.

        Args:
            pre_pow_hash: 32-byte pre-computed hash of block header (timestamp=0, nonce=0)
            timestamp: 64-bit UNIX timestamp
            nonce: 64-bit nonce value for mining iteration

        Returns:
            32-byte final hash result

        Note:
            The matrix is deterministic based on pre_pow_hash only and can be
            cached for multiple nonce attempts on the same block.
        """
        # Step 1: Construct 80-byte header
        header = self._construct_header(pre_pow_hash, timestamp, nonce)

        # Step 2: Initial cSHAKE256 with "ProofOfWorkHash" domain
        pow_hash = self._cshake256_myImplimentaion(header, 32, "", "ProofOfWorkHash")

        # Step 3: Generate or retrieve cached matrix from pre_pow_hash
        matrix = self._generate_matrix(pre_pow_hash)

        # Step 4: Create 64-element vector from pow_hash
        vector = self._create_vector_from_hash(pow_hash)

        # Step 5: Matrix-vector multiplication with normalization
        product_vector = self._matrix_vector_multiply(matrix, vector)

        # Step 6: XOR product with original pow_hash
        digest = self._xor_with_hash(product_vector, pow_hash)

        # Step 7: Final cSHAKE256 with "HeavyHash" domain
        final_hash = self._cshake256_myImplimentaion(digest, 32, "", "HeavyHash")

        return final_hash

    def hash_gpu_batch(
        self, pre_pow_hash: bytes, timestamp: int, nonces: List[int]
    ) -> List[bytes]:
        """
        Compute kHeavyHash for multiple nonces using a single GPU-batched GEMV.

        Uploads the matrix to GPU once per block, then processes all nonces in
        one (64,64)@(64,N) matrix multiply, minimizing PCIe round-trips and
        kernel-launch overhead.

        float32 is safe here: max dot product = 64 * 15 * 15 = 14,400,
        well within float32's exact integer range of 2^24 = 16,777,216.

        Args:
            pre_pow_hash: 32-byte block header hash (matrix seed)
            timestamp: 64-bit UNIX timestamp
            nonces: batch of nonce values to evaluate

        Returns:
            List of 32-byte final hashes, one per nonce, in input order
        """
        import torch

        matrix = self._generate_matrix(pre_pow_hash)

        # Upload matrix once; reuse for entire batch
        mat_gpu = torch.tensor(matrix, dtype=torch.float32, device="cuda")  # (64, 64)

        # CPU: cSHAKE256 has no GPU kernel — compute pow_hash per nonce
        pow_hashes = []
        for nonce in nonces:
            header = self._construct_header(pre_pow_hash, timestamp, nonce)
            pow_hashes.append(
                self._cshake256_myImplimentaion(header, 32, "", "ProofOfWorkHash")
            )

        # Vectorized nibble extraction via numpy — avoids Python loops
        import numpy as np

        pow_array = np.frombuffer(b"".join(pow_hashes), dtype=np.uint8).reshape(
            len(nonces), 32
        )
        vectors_np = np.empty((len(nonces), 64), dtype=np.float32)
        vectors_np[:, 0::2] = (pow_array >> 4) & 0xF  # upper nibbles at even indices
        vectors_np[:, 1::2] = pow_array & 0xF  # lower nibbles at odd indices

        # Single batched GEMV: (64,64) @ (64,N) = (64,N)
        vecs_gpu = torch.from_numpy(vectors_np).to("cuda").T  # (64, N)
        dot_products = (mat_gpu @ vecs_gpu).to(torch.int64)  # (64, N)
        normalized = (
            ((dot_products >> 10) & 0xF).T.cpu().numpy().astype(np.int32)
        )  # (N, 64)

        # Vectorized XOR recombination on CPU
        upper_nibbles = normalized[:, 0::2]  # (N, 32)
        lower_nibbles = normalized[:, 1::2]  # (N, 32)
        recombined = ((upper_nibbles << 4) | lower_nibbles).astype(np.uint8)  # (N, 32)
        xored = recombined ^ pow_array  # (N, 32)

        # Final cSHAKE256 per nonce (CPU only)
        results = []
        for i in range(len(nonces)):
            results.append(
                self._cshake256_myImplimentaion(bytes(xored[i]), 32, "", "HeavyHash")
            )
        return results

    def hash_cpu_batch(
        self, pre_pow_hash: bytes, timestamp: int, nonces: List[int]
    ) -> List[bytes]:
        """
        Compute kHeavyHash for multiple nonces optimized for multi-core CPU.

        Uses numpy for vectorized batched GEMV and concurrent.futures to
        parallelize cSHAKE256 calls across CPU cores. PyCryptodome's raw
        Keccak C extension releases the GIL, so threads run truly in parallel.

        Args:
            pre_pow_hash: 32-byte block header hash (matrix seed)
            timestamp: 64-bit UNIX timestamp
            nonces: batch of nonce values to evaluate

        Returns:
            List of 32-byte final hashes, one per nonce, in input order
        """
        from concurrent.futures import ThreadPoolExecutor

        import numpy as np

        matrix = self._generate_matrix(pre_pow_hash)
        mat_np = np.array(matrix, dtype=np.int32)  # (64, 64)

        # Parallel ProofOfWorkHash — GIL released by C Keccak extension
        def _pow_hash(nonce: int) -> bytes:
            header = self._construct_header(pre_pow_hash, timestamp, nonce)
            return self._cshake256_myImplimentaion(header, 32, "", "ProofOfWorkHash")

        with ThreadPoolExecutor() as ex:
            pow_hashes = list(ex.map(_pow_hash, nonces))

        # Vectorized nibble extraction
        pow_array = np.frombuffer(b"".join(pow_hashes), dtype=np.uint8).reshape(
            len(nonces), 32
        )
        vectors = np.empty((len(nonces), 64), dtype=np.int32)
        vectors[:, 0::2] = (pow_array >> 4) & 0xF
        vectors[:, 1::2] = pow_array & 0xF

        # Batched GEMV via numpy (uses BLAS under the hood)
        dot_products = vectors @ mat_np.T  # (N, 64)
        normalized = (dot_products >> 10) & 0xF  # (N, 64)

        # Vectorized XOR recombination
        upper_nibbles = normalized[:, 0::2]  # (N, 32)
        lower_nibbles = normalized[:, 1::2]  # (N, 32)
        recombined = ((upper_nibbles << 4) | lower_nibbles).astype(np.uint8)  # (N, 32)
        xored = recombined ^ pow_array  # (N, 32)

        # Parallel HeavyHash — GIL released by C Keccak extension
        def _final_hash(digest: bytes) -> bytes:
            return self._cshake256_myImplimentaion(digest, 32, "", "HeavyHash")

        with ThreadPoolExecutor() as ex:
            results = list(
                ex.map(_final_hash, [bytes(xored[i]) for i in range(len(nonces))])
            )

        return results

    def _construct_header(
        self, pre_pow_hash: bytes, timestamp: int, nonce: int
    ) -> bytes:
        """Construct 80-byte header: pre_pow_hash + timestamp + 32 zero bytes + nonce."""
        if len(pre_pow_hash) != 32:
            raise ValueError("pre_pow_hash must be exactly 32 bytes")

        # Pack timestamp and nonce as little-endian 64-bit integers
        timestamp_bytes = struct.pack("<Q", timestamp)
        nonce_bytes = struct.pack("<Q", nonce)

        header = pre_pow_hash + timestamp_bytes + b"\x00" * 32 + nonce_bytes

        return header

    def _cshake256_myImplimentaion(
        self,
        data: bytes,
        output_length: int,
        function_name: str = "",
        customization: str = "",
    ) -> bytes:
        """
        Compute cSHAKE256 hash with domain separation.

        Custom implementation using PyCryptodome's raw Keccak primitives.
        Implements NIST SP 800-185 cSHAKE256 specification.

        Args:
            data: Input data to hash
            output_length: Desired output length in bytes
            function_name: Function name string (N parameter) - ignored for compatibility
            customization: Customization string (S parameter)

        Returns:
            Hash output of specified length
        """

        def left_encode(x):
            """NIST SP 800-185 left_encode."""
            if x == 0:
                return b"\x01\x00"
            n = (x.bit_length() + 7) // 8
            return bytes([n]) + x.to_bytes(n, "big")

        def encode_string(s):
            """NIST SP 800-185 encode_string."""
            if isinstance(s, str):
                s = s.encode("utf-8")
            bitlen = len(s) * 8
            return left_encode(bitlen) + s

        def bytepad(x, w):
            """NIST SP 800-185 bytepad."""
            z = left_encode(w) + x
            # Pad with zeros to make length a multiple of w
            npad = (w - len(z) % w) % w
            return z + b"\x00" * npad

        # cSHAKE256 uses Keccak[512] (capacity = 512 bits = 64 bytes)
        # Rate = 1600 - 512 = 1088 bits = 136 bytes
        capacity = 512
        rate = 136

        # Initialize Keccak state
        state = VoidPointer()
        result = _raw_keccak_lib.keccak_init(
            state.address_of(), c_size_t(capacity // 8), c_ubyte(24)
        )
        if result:
            raise ValueError(f"Error {result} while initializing Keccak")

        state_ptr = SmartPointer(state.get(), _raw_keccak_lib.keccak_destroy)

        # Determine if we need cSHAKE or can fall back to SHAKE
        # Per spec: if both N and S are empty, use SHAKE256 with padding 0x1F
        # Otherwise use cSHAKE256 with padding 0x04
        #
        # Reference implementation ignores function_name and only uses customization
        # So we check only customization to match the reference behavior
        if customization:
            # Build cSHAKE prefix: bytepad(encode_string(N) || encode_string(S), rate)
            # N is always empty (b'') to match PyCryptodome's cSHAKE256.new() behavior
            prefix_unpad = encode_string(b"") + encode_string(customization)
            prefix = bytepad(prefix_unpad, rate)
            padding_byte = 0x04  # cSHAKE padding

            # Absorb the prefix
            result = _raw_keccak_lib.keccak_absorb(
                state_ptr.get(), c_uint8_ptr(prefix), c_size_t(len(prefix))
            )
            if result:
                raise ValueError(f"Error {result} while absorbing prefix")
        else:
            # Use SHAKE256 padding
            padding_byte = 0x1F

        # Absorb the data
        result = _raw_keccak_lib.keccak_absorb(
            state_ptr.get(), c_uint8_ptr(data), c_size_t(len(data))
        )
        if result:
            raise ValueError(f"Error {result} while absorbing data")

        # Squeeze the output
        output_buffer = create_string_buffer(output_length)
        result = _raw_keccak_lib.keccak_squeeze(
            state_ptr.get(),
            output_buffer,
            c_size_t(output_length),
            c_ubyte(padding_byte),
        )
        if result:
            raise ValueError(f"Error {result} while squeezing output")

        return get_raw_buffer(output_buffer)

    def _cshake256(
        self,
        data: bytes,
        output_length: int,
        function_name: str = "",
        customization: str = "",
    ):
        """
        Compute cSHAKE256 hash with domain separation using PyCryptodome.

        Args:
            data: Input data to hash
            output_length: Desired output length in bytes
            function_name: Domain separation string (N parameter)
            customization: Additional customization string (S parameter)

        Returns:
            Hash output of specified length
        """
        # Note: cSHAKE256 in PyCryptodome takes custom parameter which is S (customization)
        # We need to use the customization parameter, not function_name
        # Based on Go implementation: NewCShake256(nil, domain) means N=nil, S=domain
        shake = cSHAKE256.new(
            custom=customization.encode("utf-8") if customization else b""
        )
        shake.update(data)
        return shake.read(output_length)

    def _generate_matrix(
        self, pre_pow_hash: bytes, verbose: bool = False
    ) -> List[List[int]]:
        """
        Generate a 64x64 full-rank matrix from PrePowHash using xoshiro256++.

        Matrix is seeded from PrePowHash (first 32 bytes of input),
        NOT from the cSHAKE256 result. This allows matrix reuse across nonces.

        The matrix contains 16-bit unsigned integers storing 4-bit values (0-15).
        Generation repeats until the matrix achieves full rank (determinant ≠ 0).

        Args:
            pre_pow_hash: 32-byte seed for matrix generation

        Returns:
            64x64 matrix as list of lists, each element in range [0, 15]

        Note:
            Matrix generation is expensive but can be cached per PrePowHash.
            Same PrePowHash always produces the same matrix.
        """
        matrix_cache = self.get_cached_matrix(pre_pow_hash)
        if matrix_cache:
            return matrix_cache

        self.clear_matrix_cache()

        if verbose:
            print("=" * 80)
            print(f"Generating matrix from pre_pow_hash: {pre_pow_hash.hex()}")

        # Initialize xoshiro256++ state from pre_pow_hash
        state = self._init_xoshiro256pp(pre_pow_hash)

        # Attempt to generate full-rank matrix
        for attempt in range(1000):  # To avoid infinite loop
            matrix = []

            # Generate 64x64 matrix with 4-bit elements
            for i in range(64):
                row = []
                for _ in range(64):
                    # Get next random value and extract 4 bits
                    rand_val = self._xoshiro256pp_next(state)
                    for k in range(16):  # 16 4-bit values per 64-bit random number
                        element = (rand_val >> (k * 4)) & 0xF
                        row.append(element)
                        if len(row) == 64:
                            break
                    if len(row) == 64:
                        break
                matrix.append(row)

            # Check if matrix has full rank
            if self._check_matrix_rank(matrix, verbose):
                self.set_matrix_cache(pre_pow_hash, matrix)
                if verbose:
                    print(f"Generated full-rank matrix on attempt {attempt + 1}")
                    print("=" * 80)
                return matrix

        raise RuntimeError("Failed to generate full-rank matrix after 1000 attempts")

    def _init_xoshiro256pp(self, seed_bytes: bytes) -> List[int]:
        """
        Initialize xoshiro256++ PRNG state from 32-byte seed.

        Splits the 32-byte seed into four 64-bit little-endian integers
        to form the initial PRNG state.

        Args:
            seed_bytes: 32-byte seed (typically PrePowHash)

        Returns:
            List of 4 uint64 values representing PRNG state
        """
        if len(seed_bytes) != 32:
            raise ValueError("seed_bytes must be exactly 32 bytes")

        state = []
        for i in range(4):
            offset = i * 8
            value = struct.unpack("<Q", seed_bytes[offset : offset + 8])[0]
            state.append(value)

        return state

    def _xoshiro256pp_next(self, state: List[int]) -> int:
        """
        Generate next 64-bit pseudorandom number using xoshiro256++.

        Args:
            state: List of 4 uint64 values (modified in-place)

        Returns:
            64-bit pseudorandom integer

        Note:
            The state parameter is modified in-place to advance the PRNG.
        """
        # xoshiro256++ algorithm
        result = (state[0] + state[3]) & 0xFFFFFFFFFFFFFFFF
        result = self._rotl64(result, 23)
        result = (result + state[0]) & 0xFFFFFFFFFFFFFFFF

        t = (state[1] << 17) & 0xFFFFFFFFFFFFFFFF

        state[2] ^= state[0]
        state[3] ^= state[1]
        state[1] ^= state[2]
        state[0] ^= state[3]

        state[2] ^= t
        state[3] = self._rotl64(state[3], 45)

        return result

    def _check_matrix_rank(
        self, matrix: List[List[int]], verbose: bool = False
    ) -> bool:
        """
        Check if the 64x64 matrix has full rank (rank = 64).

        A full-rank matrix ensures proper diffusion and cryptographic
        properties. Non-full-rank matrices must be regenerated.

        Args:
            matrix: 64x64 matrix to check

        Returns:
            True if matrix has full rank, False otherwise

        Note:
            Uses Gaussian elimination with floating-point arithmetic to compute rank.
            This matches the official Kaspa (kaspad) implementation.
        """
        if verbose:
            print("=" * 80)
            print("Checking matrix rank...")
            start_time = time.time()

        eps = 1e-9  # Epsilon for floating-point comparison
        n = len(matrix)

        # Convert integer matrix to floating-point (To match Go implementation)
        B = [[float(matrix[i][j]) for j in range(n)] for i in range(n)]

        rank = 0
        row_selected = [False] * n

        # Gaussian elimination (matches Go's computeRank algorithm)
        for i in range(n):
            # Find pivot row for column i
            j = 0
            while j < n:
                if not row_selected[j] and abs(B[j][i]) > eps:
                    break
                j += 1

            if j != n:  # Found a pivot
                rank += 1
                row_selected[j] = True

                # Scale pivot row by dividing by pivot element
                pivot = B[j][i]
                for p in range(i + 1, n):
                    B[j][p] /= pivot

                # Eliminate column i in all other rows
                for k in range(n):
                    if k != j and abs(B[k][i]) > eps:
                        factor = B[k][i]
                        for p in range(i + 1, n):
                            B[k][p] -= B[j][p] * factor

        if verbose:
            end_time = time.time()
            print(
                f"Matrix rank check completed in {end_time - start_time:.3f}s, rank = {rank}"
            )
            print("=" * 80)

        return rank == n

    def _create_vector_from_hash(self, hash_bytes: bytes) -> List[int]:
        """
        Convert 32-byte hash to 64-element vector of 4-bit values.

        Each byte is split into two 4-bit nibbles:
        - Upper nibble: (byte >> 4) & 0x0F
        - Lower nibble: byte & 0x0F

        Args:
            hash_bytes: 32-byte hash result from cSHAKE256

        Returns:
            List of 64 integers, each in range [0, 15]
        """
        vector = []
        for byte in hash_bytes:
            upper_nibble = (byte >> 4) & 0xF
            lower_nibble = byte & 0xF
            vector.extend([upper_nibble, lower_nibble])
        return vector

    def _matrix_vector_multiply(
        self, matrix: List[List[int]], vector: List[int]
    ) -> List[int]:
        """
        Multiply 64x64 matrix by 64-element vector with normalization.

        Performs standard matrix-vector multiplication followed by
        right-shift by 10 bits to normalize results back to 4-bit range.

        Normalization rationale:
        - Max element value: 15 (4 bits)
        - Max single product: 15 × 15 = 225
        - Max sum of 64 products: 64 × 225 = 14,400 (requires 14 bits)
        - Right shift by 10: brings back to ~4-bit range

        Args:
            matrix: 64x64 matrix with elements in [0, 15]
            vector: 64-element vector with elements in [0, 15]

        Returns:
            64-element result vector with elements in [0, 15] after normalization
        """
        result = []
        for i in range(64):
            dot_product = sum(matrix[i][j] * vector[j] for j in range(64))
            # Normalize by right-shifting 10 bits
            normalized_value = (dot_product >> 10) & 0xF
            result.append(normalized_value)
        return result

    def _matrix_vector_multiply_GPU(
        self, matrix: List[List[int]], vector: List[int]
    ) -> List[int]:
        import torch
        mat = torch.tensor(matrix, dtype=torch.float64, device="cuda")  # (64, 64)
        vec = torch.tensor(vector, dtype=torch.float64, device="cuda")  # (64,)

        dot_products = (mat @ vec).to(torch.int64)  # (64,) — back to int for bit ops

        normalized = (dot_products >> 10) & 0xF

        return normalized.cpu().tolist()

    def _xor_with_hash(self, product_vector: List[int], original_hash: bytes) -> bytes:
        """
        XOR the matrix multiplication result with the original powHash.

        Recombines pairs of 4-bit values from product_vector back into bytes,
        then XORs with corresponding bytes from the original hash.

        Recombination:
        - Even indices (product[i*2]): become upper nibbles (shifted left by 4)
        - Odd indices (product[i*2+1]): become lower nibbles

        Args:
            product_vector: 64-element vector from matrix multiplication
            original_hash: 32-byte powHash from first cSHAKE256

        Returns:
            32-byte result ready for final hashing
        """
        result = bytearray(32)
        for i in range(32):
            upper_nibble = product_vector[i * 2]
            lower_nibble = product_vector[i * 2 + 1]
            recombined_byte = (upper_nibble << 4) | lower_nibble
            xored_byte = recombined_byte ^ original_hash[i]
            result[i] = xored_byte
        return bytes(result)

    def _rotl64(self, value: int, shift: int) -> int:
        """
        Rotate a 64-bit integer left by specified number of bits.

        Args:
            value: 64-bit integer to rotate
            shift: Number of bits to rotate left

        Returns:
            Rotated 64-bit integer
        """
        shift = shift % 64
        return ((value << shift) | (value >> (64 - shift))) & 0xFFFFFFFFFFFFFFFF

    def set_matrix_cache(self, pre_pow_hash: bytes, matrix: List[List[int]]):
        """
        Cache a pre-computed matrix for the given PrePowHash.

        This optimization allows miners to compute the matrix once per block
        and reuse it for all nonce attempts.

        Args:
            pre_pow_hash: 32-byte PrePowHash used as matrix seed
            matrix: Pre-computed 64x64 matrix
        """
        self._cached_prepow_hash = pre_pow_hash
        self._cached_matrix = matrix

    def clear_matrix_cache(self):
        """
        Clear the cached matrix to free memory.
        """
        self._cached_matrix = None
        self._cached_prepow_hash = None

    def get_cached_matrix(self, pre_pow_hash: bytes) -> Optional[List[List[int]]]:
        """Return cached matrix if available for given pre_pow_hash."""
        if self._cached_prepow_hash == pre_pow_hash:
            return self._cached_matrix
        return None


# Algorithm constants
MATRIX_SIZE = 64
ELEMENT_BITS = 4
NORMALIZATION_SHIFT = 10
HEADER_SIZE = 80
HASH_SIZE = 32
