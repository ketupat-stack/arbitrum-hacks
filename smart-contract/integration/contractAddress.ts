/**
 * @file   contractAddress.ts
 * @notice Alamat kontrak PathtrickSBT per jaringan.
 *
 * ⚠️  WAJIB diupdate oleh SC Engineer setelah deploy ke BNB Testnet.
 *     Isi CONTRACT_ADDRESS dengan alamat hasil `forge script ... --broadcast`.
 *
 * Chain IDs:
 *   - BNB Testnet : 97
 *   - BNB Mainnet : 56  (belum deploy)
 *   - Anvil local : 31337
 */

export const CONTRACT_ADDRESSES: Record<number, `0x${string}`> = {
  /** BNB Smart Chain Testnet — deployed 2026-09-23. */
  97: "0x39632892C33435a76043343Ef17Ac03124627ba9",

  /** Anvil local — diisi saat local testing */
  31337: "0x0000000000000000000000000000000000000000",
};

/**
 * Kembalikan contract address untuk chain ID yang diberikan.
 * @throws {Error} Jika chain ID tidak dikenali atau belum di-deploy.
 */
export function getContractAddress(chainId: number): `0x${string}` {
  const address = CONTRACT_ADDRESSES[chainId];
  if (!address || address === "0x0000000000000000000000000000000000000000") {
    throw new Error(
      `[PathtrickSBT] Contract belum di-deploy ke chain ID ${chainId}. ` +
        `Update CONTRACT_ADDRESSES di contractAddress.ts setelah deploy.`
    );
  }
  return address;
}
