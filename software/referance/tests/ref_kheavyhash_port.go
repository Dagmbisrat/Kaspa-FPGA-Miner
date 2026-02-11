package main

import (
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"os"
	"strconv"

	"github.com/bcutil/kheavyhash"
)

func main() {
	if len(os.Args) != 4 {
		fmt.Println("Usage: go run test_port.go <pre_pow_hash_hex> <timestamp> <nonce>")
		fmt.Println("Example: go run ref_kheavyhash_port.go a1b2c3d4e5f6789012345678901234567890abcdefabcdef1234567890abcdef 1678901234 12345678")
		os.Exit(1)
	}

	// Parse pre_pow_hash
	prePowHash, err := hex.DecodeString(os.Args[1])
	if err != nil || len(prePowHash) != 32 {
		fmt.Println("Error: pre_pow_hash must be 32 bytes (64 hex chars)")
		os.Exit(1)
	}

	// Parse timestamp
	timestamp, err := strconv.ParseUint(os.Args[2], 10, 64)
	if err != nil {
		fmt.Println("Error: invalid timestamp")
		os.Exit(1)
	}

	// Parse nonce
	nonce, err := strconv.ParseUint(os.Args[3], 10, 64)
	if err != nil {
		fmt.Println("Error: invalid nonce")
		os.Exit(1)
	}

	// Build 80-byte work order
	var workOrder [80]byte
	copy(workOrder[0:32], prePowHash)
	binary.LittleEndian.PutUint64(workOrder[32:40], timestamp)
	// workOrder[40:72] is padding (already zeros)
	binary.LittleEndian.PutUint64(workOrder[72:80], nonce)

	// Compute hash
	result := kheavyhash.KHeavyHash(workOrder[:])

	// Print result
	fmt.Println(hex.EncodeToString(result[:]))
}
