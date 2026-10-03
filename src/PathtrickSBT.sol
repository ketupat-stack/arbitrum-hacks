// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Arbitrum Precompile Interface
interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
}

/**
 * @title  PathtrickSBT
 * @author Pathtrick — Ketupat Team
 * @notice ERC-1155 Soulbound Token (SBT) for Pathtrick AI Career Coach certificates.
 *         Deployed on Arbitrum One / Arbitrum Sepolia.
 *         Uses EIP-712 ECDSA Signatures for AI-graded minting.
 *
 *  Key design decisions
 *  ────────────────────
 *  • Non-transferable: SBT logic overrides `_update` to reject transfers.
 *  • Dual Payment: User pays mint fee in ETH **or** Paxos USDG stablecoin.
 *  • ECDSA Signature: AI Backend signs a message (EIP-712) proving the user passed.
 *  • Double-mint guard: one certificate per (user, courseId) pair.
 *  • Certificate Record: On-chain timestamp and issuer stored per token.
 *  • Revocation: Owner can revoke (burn) a certificate if needed.
 *  • Pausable: Emergency pause stops all minting.
 *  • Course Registry: Only registered courseIds can be minted.
 */
contract PathtrickSBT is ERC1155, Ownable2Step, Pausable, EIP712 {
    using ECDSA for bytes32;
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice On-chain record stored for each issued certificate.
    struct CertificateRecord {
        uint128 issuedAt; // block.timestamp when minted
        uint64 l1BlockNumber; // Ethereum L1 block number from Arbitrum ArbSys
        address issuer; // adminSigner address at time of mint
    }

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    uint256 public mintPrice = 0.005 ether;

    /// @notice Paxos USDG stablecoin address. If set, user can pay in USDG instead of ETH.
    /// @dev    Set to address(0) to disable USDG payment.
    IERC20 public usdgToken;

    /// @notice Mint price denominated in USDG (6 decimals). Default: 1 USDG.
    uint256 public mintPriceUSDG = 1e6;

    /// @notice Address of the Backend AI wallet that signs certificates.
    /// @dev    ⚠️  TRUST GAP: This is a privileged hot wallet. Its private key MUST be
    ///         stored in an HSM or KMS — NOT in a plain .env file on a production server.
    ///         A leaked adminSigner key allows forging valid certificates for any address.
    address public adminSigner;

    /// @dev hasCertificate[user][courseId] — double-mint guard.
    mapping(address => mapping(uint256 => bool)) public hasCertificate;
    mapping(address => mapping(uint256 => uint256)) public nonces;

    /// @dev Certificate on-chain records: certificates[user][courseId]
    mapping(address => mapping(uint256 => CertificateRecord)) public certificates;

    /// @dev Course registry: registeredCourse[courseId] = true if valid.
    mapping(uint256 => bool) public registeredCourse;

    // EIP-712 TypeHash — matches original format used by Frontend & Backend
    // Struct: MintCertificate(address user,uint256 courseId,uint256 nonce,uint256 deadline)
    bytes32 public constant MINT_TYPEHASH =
        keccak256("MintCertificate(address user,uint256 courseId,uint256 nonce,uint256 deadline)");

    // ─────────────────────────────────────────────────────────────────────────
    // Custom errors
    // ─────────────────────────────────────────────────────────────────────────

    error SoulboundTokenNonTransferable();
    error AlreadyCertified(address user, uint256 courseId);
    error IncorrectMintFee();
    error InvalidSignature();
    error WithdrawFailed();
    error AdminSignerCannotBeOwner();
    error SignatureExpired();
    error CourseNotRegistered(uint256 courseId);
    error NotCertified(address user, uint256 courseId);
    error USDGNotEnabled();
    error ZeroAddress();

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event CertificateMinted(address indexed to, uint256 indexed courseId, uint256 issuedAt, bool paidInUSDG);
    event CertificateRevoked(address indexed from, uint256 indexed courseId, address revokedBy);
    event AdminSignerUpdated(address oldSigner, address newSigner);
    event MintPriceUpdated(uint256 oldPrice, uint256 newPrice);
    event MintPriceUSDGUpdated(uint256 oldPrice, uint256 newPrice);
    event USDGTokenUpdated(address oldToken, address newToken);
    event CourseRegistered(uint256 indexed courseId);
    event CourseDeregistered(uint256 indexed courseId);

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @param initialOwner  Address that receives Ownable admin rights (for withdrawal/config).
     * @param _adminSigner  Address of the Backend AI wallet that signs the certificates.
     * @param _usdgToken    Address of Paxos USDG stablecoin. Pass address(0) to disable.
     * @param uri_          Metadata URI for the ERC1155 tokens.
     */
    constructor(address initialOwner, address _adminSigner, address _usdgToken, string memory uri_)
        ERC1155(uri_)
        Ownable(initialOwner)
        EIP712("PathtrickSBT", "1")
    {
        if (_adminSigner == address(0)) revert ZeroAddress();
        if (_adminSigner == initialOwner) revert AdminSignerCannotBeOwner();
        adminSigner = _adminSigner;

        // USDG is optional
        if (_usdgToken != address(0)) {
            usdgToken = IERC20(_usdgToken);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Mint — ETH payment
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Mint a soulbound certificate after passing the AI grading. Pay in ETH.
     * @dev    User must pay `mintPrice` ETH and provide a valid EIP-712 signature
     *         from the `adminSigner`. Contract must not be paused.
     *
     * @param courseId  Course / skill-path identifier (used as tokenId).
     * @param deadline  Unix timestamp after which the signature is invalid.
     * @param signature ECDSA signature generated by Backend AI.
     */
    function mintCertificate(uint256 courseId, uint256 deadline, bytes calldata signature)
        external
        payable
        whenNotPaused
    {
        if (msg.value != mintPrice) revert IncorrectMintFee();
        _mintInternal(msg.sender, courseId, deadline, signature, false);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Mint — USDG payment (Paxos stablecoin)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Mint a soulbound certificate paying with Paxos USDG stablecoin.
     * @dev    Caller must have approved this contract to spend `mintPriceUSDG` USDG.
     *
     * @param courseId  Course / skill-path identifier.
     * @param deadline  Unix timestamp after which the signature is invalid.
     * @param signature ECDSA signature from Backend AI.
     */
    function mintCertificateWithUSDG(uint256 courseId, uint256 deadline, bytes calldata signature)
        external
        whenNotPaused
    {
        if (address(usdgToken) == address(0)) revert USDGNotEnabled();
        // Pull USDG from caller — SafeERC20 handles non-standard ERC20s
        usdgToken.safeTransferFrom(msg.sender, address(this), mintPriceUSDG);
        _mintInternal(msg.sender, courseId, deadline, signature, true);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal Mint Logic
    // ─────────────────────────────────────────────────────────────────────────

    function _mintInternal(address user, uint256 courseId, uint256 deadline, bytes calldata signature, bool paidInUSDG)
        internal
    {
        // Checks
        if (!registeredCourse[courseId]) revert CourseNotRegistered(courseId);
        if (hasCertificate[user][courseId]) revert AlreadyCertified(user, courseId);
        if (deadline < block.timestamp) revert SignatureExpired();

        uint256 nonce = nonces[user][courseId];

        // Verify EIP-712 Signature
        bytes32 structHash = keccak256(abi.encode(MINT_TYPEHASH, user, courseId, nonce, deadline));
        bytes32 digest = _hashTypedDataV4(structHash);

        address recoveredSigner = digest.recover(signature);
        if (recoveredSigner != adminSigner || recoveredSigner == address(0)) {
            revert InvalidSignature();
        }

        // Effects — update state before minting (CEI pattern)
        nonces[user][courseId] = nonce + 1;
        hasCertificate[user][courseId] = true;
        certificates[user][courseId] = CertificateRecord({
            issuedAt: uint128(block.timestamp),
            l1BlockNumber: uint64(IArbSys(address(100)).arbBlockNumber()),
            issuer: adminSigner
        });

        // Interactions
        _mint(user, courseId, 1, "");

        emit CertificateMinted(user, courseId, block.timestamp, paidInUSDG);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin Functions
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Revoke (burn) a certificate. Used for misconduct or error correction.
     * @dev    Resets hasCertificate so the user could theoretically re-earn it.
     */
    function revokeCertificate(address user, uint256 courseId) external onlyOwner {
        if (!hasCertificate[user][courseId]) revert NotCertified(user, courseId);

        hasCertificate[user][courseId] = false;
        delete certificates[user][courseId];
        _burn(user, courseId, 1);

        emit CertificateRevoked(user, courseId, msg.sender);
    }

    /**
     * @notice Register a courseId so it can be minted.
     */
    function registerCourse(uint256 courseId) external onlyOwner {
        registeredCourse[courseId] = true;
        emit CourseRegistered(courseId);
    }

    /**
     * @notice Batch register multiple courseIds at once.
     */
    function registerCourses(uint256[] calldata courseIds) external onlyOwner {
        for (uint256 i = 0; i < courseIds.length; i++) {
            registeredCourse[courseIds[i]] = true;
            emit CourseRegistered(courseIds[i]);
        }
    }

    /**
     * @notice Deregister a courseId — no new mints allowed for this course.
     */
    function deregisterCourse(uint256 courseId) external onlyOwner {
        registeredCourse[courseId] = false;
        emit CourseDeregistered(courseId);
    }

    /**
     * @notice Withdraw collected ETH from mint fees.
     */
    function withdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        (bool success,) = owner().call{value: balance}("");
        if (!success) revert WithdrawFailed();
    }

    /**
     * @notice Withdraw collected USDG from mint fees.
     */
    function withdrawUSDG() external onlyOwner {
        if (address(usdgToken) == address(0)) revert USDGNotEnabled();
        uint256 balance = usdgToken.balanceOf(address(this));
        usdgToken.safeTransfer(owner(), balance);
    }

    /**
     * @notice Update the admin signer address (e.g., key rotation).
     * @dev    ⚠️  ACCESS CONTROL: Change takes effect immediately (no timelock).
     *         For production, consider wrapping this in a Timelock contract
     *         or using a multisig to prevent instant key-rotation attacks if
     *         the owner account is ever compromised.
     */
    function setAdminSigner(address _newSigner) external onlyOwner {
        if (_newSigner == address(0)) revert ZeroAddress();
        if (_newSigner == owner()) revert AdminSignerCannotBeOwner();
        address oldSigner = adminSigner;
        adminSigner = _newSigner;
        emit AdminSignerUpdated(oldSigner, _newSigner);
    }

    /**
     * @notice Update the ETH mint fee.
     */
    function setMintPrice(uint256 _newPrice) external onlyOwner {
        uint256 oldPrice = mintPrice;
        mintPrice = _newPrice;
        emit MintPriceUpdated(oldPrice, _newPrice);
    }

    /**
     * @notice Update the USDG mint fee (in USDG's native decimals, e.g. 1e6 = 1 USDG).
     */
    function setMintPriceUSDG(uint256 _newPrice) external onlyOwner {
        uint256 oldPrice = mintPriceUSDG;
        mintPriceUSDG = _newPrice;
        emit MintPriceUSDGUpdated(oldPrice, _newPrice);
    }

    /**
     * @notice Update the Paxos USDG token address. Pass address(0) to disable.
     */
    function setUSDGToken(address _usdgToken) external onlyOwner {
        address oldToken = address(usdgToken);
        usdgToken = IERC20(_usdgToken);
        emit USDGTokenUpdated(oldToken, _usdgToken);
    }

    /**
     * @notice Update the token URI.
     */
    function setURI(string memory newuri) external onlyOwner {
        _setURI(newuri);
    }

    /**
     * @notice Pause all minting. Emergency use only.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause minting.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Returns the full on-chain certificate record for a user + course.
     */
    function getCertificate(address user, uint256 courseId) external view returns (CertificateRecord memory) {
        return certificates[user][courseId];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Soulbound overrides — block all transfers & approvals
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev OZ v5 routes all mint / burn / transfer flows through _update().
     *      We override it to reject any call where both from and to are non-zero
     *      (i.e., normal transfers).
     */
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        virtual
        override
    {
        // Allow minting (from == 0) and burning (to == 0)
        // Block transfers (from != 0 && to != 0)
        if (from != address(0) && to != address(0)) {
            revert SoulboundTokenNonTransferable();
        }
        super._update(from, to, ids, values);
    }

    /**
     * @dev Operator approvals are meaningless on an SBT — always revert to save user gas.
     */
    function setApprovalForAll(address, bool) public pure override {
        revert SoulboundTokenNonTransferable();
    }
}
