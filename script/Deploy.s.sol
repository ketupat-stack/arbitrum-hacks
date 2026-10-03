// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PathtrickSBT} from "../src/PathtrickSBT.sol";

/**
 * @title  Deploy
 * @notice Foundry deployment script for PathtrickSBT (ERC-1155 Soulbound Token on Arbitrum).
 *
 * Environment variables required
 * ───────────────────────────────
 *   PRIVATE_KEY       — private key of the deployer wallet used to broadcast.
 *   OWNER_ADDRESS     — owner or multisig address for administration.
 *   ADMIN_SIGNER      — address of the Backend wallet that signs the EIP-712 certificates.
 *                       This must be different from the deployer/owner address.
 *   USDG_TOKEN        — (optional) Paxos USDG token address. Use address(0) to disable.
 *   COURSE_IDS        — (optional) comma-separated courseIds to register on deploy.
 *
 * Usage examples
 * ──────────────
 *   # Arbitrum Sepolia (testnet) — broadcast + verify on Arbiscan
 *   forge script script/Deploy.s.sol \
 *       --rpc-url arbitrum_sepolia \
 *       --private-key $PRIVATE_KEY \
 *       --broadcast \
 *       --verify \
 *       --verifier-url https://api-sepolia.arbiscan.io/api \
 *       --etherscan-api-key $ARBISCAN_API_KEY \
 *       -vvvv
 *
 *   # Arbitrum One (mainnet) — broadcast + verify on Arbiscan
 *   forge script script/Deploy.s.sol \
 *       --rpc-url arbitrum_one \
 *       --private-key $PRIVATE_KEY \
 *       --broadcast \
 *       --verify \
 *       --etherscan-api-key $ARBISCAN_API_KEY \
 *       -vvvv
 *
 * Known USDG addresses
 * ────────────────────
 *   Arbitrum One:    TBD (check https://paxos.com/usdg)
 *   Arbitrum Sepolia: address(0) — use ETH payment on testnet
 */
contract Deploy is Script {
    function run() external returns (PathtrickSBT sbt) {
        // ── Read env ──────────────────────────────────────────────────────────
        uint256 deployerPrivKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivKey);
        address ownerAddress = vm.envAddress("OWNER_ADDRESS");
        address adminSigner = vm.envAddress("ADMIN_SIGNER");
        address usdgToken = vm.envOr("USDG_TOKEN", address(0));

        // ── Token URI (REQUIRED) ──────────────────────────────────────────────
        // Must be set in .env. Example: ipfs://Qm.../metadata/{id}.json
        // ⚠️  SECURITY: Never deploy to Mainnet with a placeholder URI.
        //     All minted certificates will show broken metadata until setURI() is called.
        string memory uri = vm.envString("TOKEN_URI");
        require(bytes(uri).length > 0, "Deploy: TOKEN_URI must not be empty");
        require(
            keccak256(bytes(uri)) != keccak256(bytes("ipfs://QmPlaceholderCID/{id}.json")),
            "Deploy: TOKEN_URI is still a placeholder - set a real IPFS CID in .env"
        );

        // ── Pre-flight safety checks ──────────────────────────────────────────
        // ⚠️  TRUST GAP (Pashov Agent-11): adminSigner is a privileged hot wallet.
        //     Its private key MUST be stored in an HSM or AWS KMS — NOT in a plain .env
        //     on a production server. A leaked adminSigner key allows forging certificates.
        require(adminSigner != ownerAddress, "Deploy: adminSigner must not be owner");
        require(adminSigner != address(0), "Deploy: adminSigner must not be zero address");

        console2.log("=== PathtrickSBT Deployment (Arbitrum) ===");
        console2.log("Deployer:         ", deployerAddress);
        console2.log("Owner:            ", ownerAddress);
        console2.log("Admin Signer:     ", adminSigner);
        console2.log("USDG Token:       ", usdgToken);
        console2.log("Token URI:        ", uri);
        console2.log("Chain ID:         ", block.chainid);

        // ── Deploy ────────────────────────────────────────────────────────────
        vm.startBroadcast(deployerPrivKey);

        sbt = new PathtrickSBT(ownerAddress, adminSigner, usdgToken, uri);

        // Register initial courses (1, 2, 3) as example starter set.
        // Owner will register more courses via registerCourse() after deploy.
        // Note: registerCourses must be called by owner — deployer must be owner
        // or this step is skipped and owner calls it separately after deploy.
        uint256[] memory initialCourses = new uint256[](3);
        initialCourses[0] = 1;
        initialCourses[1] = 2;
        initialCourses[2] = 3;

        if (deployerAddress == ownerAddress) {
            sbt.registerCourses(initialCourses);
            console2.log("Registered initial courses: 1, 2, 3");
        }

        vm.stopBroadcast();

        // ── Verify post-deploy invariants (simulation only) ───────────
        require(sbt.owner() == ownerAddress, "Deploy: owner not set correctly");
        require(sbt.adminSigner() == adminSigner, "Deploy: admin signer not set correctly");

        console2.log("PathtrickSBT deployed at:", address(sbt));
    }
}
