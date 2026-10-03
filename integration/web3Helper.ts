import { ethers } from "ethers";
import ABI from "./PathtrickSBT.abi.json";

const RPC_URL =
  process.env.BNB_TESTNET_RPC_URL?.trim() ??
  "https://data-seed-prebsc-1-s1.binance.org:8545";
const RPC_TIMEOUT_MS = 15_000;

export interface MintResult {
  txHash: string;
  courseId: bigint;
  blockNumber: number;
  gasUsed: bigint;
}

export class SbtAlreadyCertifiedError extends Error {
  constructor(public readonly userAddress: string, public readonly courseId: bigint) {
    super(`[PathtrickSBT] User ${userAddress} already has course ${courseId}.`);
    this.name = "SbtAlreadyCertifiedError";
  }
}

export class SbtInsufficientFundsError extends Error {
  constructor(public readonly userAddress: string) {
    super(`[PathtrickSBT] User ${userAddress} does not have enough BNB for minting.`);
    this.name = "SbtInsufficientFundsError";
  }
}

export class SbtRpcError extends Error {
  constructor(public readonly cause: unknown) {
    super(`[PathtrickSBT] RPC error: ${String(cause)}`);
    this.name = "SbtRpcError";
  }
}

function createProvider(): ethers.JsonRpcProvider {
  return new ethers.JsonRpcProvider(RPC_URL, 97, {
    staticNetwork: true,
    polling: false,
    cacheTimeout: -1,
  });
}

function createContract(signer: ethers.Signer): ethers.Contract {
  const address = process.env.CONTRACT_ADDRESS?.trim();
  if (!address) {
    throw new Error("[PathtrickSBT] CONTRACT_ADDRESS is not configured.");
  }
  return new ethers.Contract(address, ABI, signer);
}

/**
 * Submit a user-paid mint transaction.
 *
 * The signer must be the certificate recipient. The backend signer only
 * creates the EIP-712 signature; it must not submit this transaction.
 */
export async function mintCertificate(
  userSigner: ethers.Signer,
  courseId: bigint,
  deadline: bigint,
  signature: string,
  mintPrice: bigint = 5_000_000_000_000_000n,
): Promise<MintResult> {
  const provider = createProvider();
  const signer = userSigner.provider ? userSigner : userSigner.connect(provider);
  const userAddress = await signer.getAddress();
  const contract = createContract(signer);

  try {
    const tx = await Promise.race([
      contract.mintCertificate(courseId, deadline, signature, { value: mintPrice }),
      new Promise<never>((_, reject) =>
        setTimeout(() => reject(new Error("RPC_TIMEOUT")), RPC_TIMEOUT_MS),
      ),
    ]);
    const receipt = await tx.wait(1);
    if (!receipt) throw new Error("Transaction receipt is null.");

    return {
      txHash: receipt.hash,
      courseId,
      blockNumber: receipt.blockNumber,
      gasUsed: receipt.gasUsed,
    };
  } catch (error) {
    const message = String(error).toLowerCase();
    if (message.includes("alreadycertified")) {
      throw new SbtAlreadyCertifiedError(userAddress, courseId);
    }
    if (message.includes("insufficient funds")) {
      throw new SbtInsufficientFundsError(userAddress);
    }
    throw new SbtRpcError(error);
  }
}

export async function hasCertificate(
  userAddress: string,
  courseId: bigint,
): Promise<boolean> {
  const address = process.env.CONTRACT_ADDRESS?.trim();
  if (!address) throw new Error("[PathtrickSBT] CONTRACT_ADDRESS is not configured.");
  const contract = new ethers.Contract(address, ABI, createProvider());
  return contract.hasCertificate(userAddress, courseId) as Promise<boolean>;
}

export async function getNonce(userAddress: string, courseId: bigint): Promise<bigint> {
  const address = process.env.CONTRACT_ADDRESS?.trim();
  if (!address) throw new Error("[PathtrickSBT] CONTRACT_ADDRESS is not configured.");
  const contract = new ethers.Contract(address, ABI, createProvider());
  return contract.nonces(userAddress, courseId) as Promise<bigint>;
}
