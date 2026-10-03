# PathtrickSBT integration

The current contract is deployed for BNB Smart Chain Testnet (chain ID 97).
Use the ABI in `PathtrickSBT.abi.json` together with the address in
`contractAddress.ts`.

## Current mint flow

1. Backend verifies that the user passed the course.
2. Backend reads `nonces(user, courseId)` and signs EIP-712 data:
   `user`, `courseId`, `nonce`, and `deadline`.
3. The user wallet calls:

```solidity
mintCertificate(uint256 courseId, uint256 deadline, bytes signature)
```

4. The user pays `0.005 BNB` plus transaction gas.
5. The contract verifies the signature, prevents duplicate claims, and mints
   the soulbound ERC-1155 certificate.

The backend signer only signs attestations. It does not submit the mint
transaction.

## Backend environment

```env
CONTRACT_ADDRESS=0x...
BNB_TESTNET_RPC_URL=https://data-seed-prebsc-1-s1.binance.org:8545
```

The helper in `web3Helper.ts` expects an `ethers.Signer` for the user wallet.
Do not use the old Treasury/MINTER_ROLE flow with this contract.

## Deployment outputs

After a new deployment, update `contractAddress.ts` with the new chain-97
address and distribute the regenerated ABI to the backend/frontend.
