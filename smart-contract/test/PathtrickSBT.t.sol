// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PathtrickSBT} from "../src/PathtrickSBT.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract PathtrickSBTTest is Test {
    // ─────────────────────────────────────────────────────────────────────────
    // Actors
    // ─────────────────────────────────────────────────────────────────────────
    address internal owner;
    address internal adminSigner;
    uint256 internal adminPrivateKey;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    // ─────────────────────────────────────────────────────────────────────────
    // Fixtures
    // ─────────────────────────────────────────────────────────────────────────
    PathtrickSBT internal sbt;
    ERC20Mock internal usdg;

    uint256 internal constant COURSE_ID = 42;
    uint256 internal constant MINT_PRICE = 0.005 ether;
    uint256 internal constant MINT_PRICE_USDG = 1e6; // 1 USDG (6 decimals)
    string internal constant TOKEN_URI = "ipfs://QmPlaceholderCID/{id}.json";

    bytes32 public constant MINT_TYPEHASH =
        keccak256("MintCertificate(address user,uint256 courseId,uint256 nonce,uint256 deadline)");

    // ─────────────────────────────────────────────────────────────────────────
    // Setup
    // ─────────────────────────────────────────────────────────────────────────
    function setUp() public {
        owner = makeAddr("owner");
        (adminSigner, adminPrivateKey) = makeAddrAndKey("adminSigner");

        // Mock Arbitrum ArbSys(100).arbBlockNumber() so local tests don't revert
        vm.mockCall(address(100), abi.encodeWithSignature("arbBlockNumber()"), abi.encode(uint256(19000000)));

        // Deploy mock USDG token
        usdg = new ERC20Mock();

        sbt = new PathtrickSBT(owner, adminSigner, address(usdg), TOKEN_URI);

        // Owner registers course
        vm.prank(owner);
        sbt.registerCourse(COURSE_ID);

        // Give users ETH and USDG
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        usdg.mint(alice, 100e6);
        usdg.mint(bob, 100e6);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helper — Generates an EIP-712 Signature (without score)
    // ─────────────────────────────────────────────────────────────────────────
    function _signMintRequest(uint256 pKey, address user, uint256 courseId, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(MINT_TYPEHASH, user, courseId, sbt.nonces(user, courseId), deadline));

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("PathtrickSBT")),
                keccak256(bytes("1")),
                block.chainid,
                address(sbt)
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // =========================================================================
    // SC-01: Mint Happy Path (ETH)
    // =========================================================================

    function test_mint_succeeds_with_valid_signature_and_fee() public {
        bytes memory sig = _signMintRequest(adminPrivateKey, alice, COURSE_ID, block.timestamp + 1 days);

        vm.prank(alice);
        sbt.mintCertificate{value: MINT_PRICE}(COURSE_ID, block.timestamp + 1 days, sig);

        assertEq(sbt.balanceOf(alice, COURSE_ID), 1, "alice should own 1 token");
        assertTrue(sbt.hasCertificate(alice, COURSE_ID), "hasCertificate should be true");
    }

    function test_mint_stores_certificate_record() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signMintRequest(adminPrivateKey, alice, COURSE_ID, deadline);

        vm.prank(alice);
        sbt.mintCertificate{value: MINT_PRICE}(COURSE_ID, deadline, sig);

        PathtrickSBT.CertificateRecord memory rec = sbt.getCertificate(alice, COURSE_ID);
        assertEq(rec.issuer, adminSigner, "issuer should be adminSigner");
        assertEq(rec.issuedAt, block.timestamp, "issuedAt should be current timestamp");
        assertEq(rec.l1BlockNumber, 19000000, "l1BlockNumber should match mocked L1 block");
    }

    function test_mint_event_emitted() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signMintRequest(adminPrivateKey, alice, COURSE_ID, deadline);

        vm.expectEmit(true, true, false, true);
        emit PathtrickSBT.CertificateMinted(alice, COURSE_ID, block.timestamp, false);

        vm.prank(alice);
        sbt.mintCertificate{value: MINT_PRICE}(COURSE_ID, deadline, sig);
    }

    // =========================================================================
    // SC-02: Mint with USDG (Paxos Stablecoin)
    // =========================================================================

    function test_mint_with_usdg_succeeds() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signMintRequest(adminPrivateKey, alice, COURSE_ID, deadline);

        vm.startPrank(alice);
        usdg.approve(address(sbt), MINT_PRICE_USDG);
        sbt.mintCertificateWithUSDG(COURSE_ID, deadline, sig);
        vm.stopPrank();

        assertEq(sbt.balanceOf(alice, COURSE_ID), 1, "alice should own 1 token");
        assertEq(usdg.balanceOf(address(sbt)), MINT_PRICE_USDG, "contract should hold USDG");
    }

    function test_mint_usdg_event_paidInUSDG_true() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signMintRequest(adminPrivateKey, alice, COURSE_ID, deadline);

        // Approve first, then set expectEmit right before the call that emits
        vm.startPrank(alice);
        usdg.approve(address(sbt), MINT_PRICE_USDG);

        vm.expectEmit(true, true, false, true);
        emit PathtrickSBT.CertificateMinted(alice, COURSE_ID, block.timestamp, true);

        sbt.mintCertificateWithUSDG(COURSE_ID, deadline, sig);
        vm.stopPrank();
    }

    function test_mint_usdg_reverts_if_not_enabled() public {
        // Deploy without USDG
        PathtrickSBT sbtNoUSDG = new PathtrickSBT(owner, adminSigner, address(0), TOKEN_URI);
        vm.prank(owner);
        sbtNoUSDG.registerCourse(COURSE_ID);

        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signMintRequest(adminPrivateKey, alice, COURSE_ID, deadline);

        vm.expectRevert(PathtrickSBT.USDGNotEnabled.selector);
        vm.prank(alice);
        sbtNoUSDG.mintCertificateWithUSDG(COURSE_ID, deadline, sig);
    }

    /// @dev USDG payment should revert if allowance is insufficient
    function test_mint_usdg_reverts_if_insufficient_allowance() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signMintRequest(adminPrivateKey, alice, COURSE_ID, deadline);

        // No approve — should revert
        vm.expectRevert();
        vm.prank(alice);
        sbt.mintCertificateWithUSDG(COURSE_ID, deadline, sig);
    }

    /// @dev USDG payment should revert if user balance is zero
    function test_mint_usdg_reverts_if_insufficient_balance() public {
        address broke = makeAddr("broke");
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signMintRequest(adminPrivateKey, broke, COURSE_ID, deadline);

        vm.startPrank(broke);
        usdg.approve(address(sbt), MINT_PRICE_USDG);
        vm.expectRevert();
        sbt.mintCertificateWithUSDG(COURSE_ID, deadline, sig);
        vm.stopPrank();
    }

    // =========================================================================
    // SC-03: Course Registry
    // =========================================================================

    function test_mint_reverts_for_unregistered_course() public {
        uint256 unregisteredCourse = 999;
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signMintRequest(adminPrivateKey, alice, unregisteredCourse, deadline);

        vm.expectRevert(abi.encodeWithSelector(PathtrickSBT.CourseNotRegistered.selector, unregisteredCourse));
        vm.prank(alice);
        sbt.mintCertificate{value: MINT_PRICE}(unregisteredCourse, deadline, sig);
    }

    function test_owner_can_register_and_deregister_course() public {
        uint256 newCourse = 100;
        assertFalse(sbt.registeredCourse(newCourse));

        vm.prank(owner);
        sbt.registerCourse(newCourse);
        assertTrue(sbt.registeredCourse(newCourse));

        vm.prank(owner);
        sbt.deregisterCourse(newCourse);
        assertFalse(sbt.registeredCourse(newCourse));
    }

    function test_owner_can_batch_register_courses() public {
        uint256[] memory ids = new uint256[](3);
        ids[0] = 10;
        ids[1] = 11;
        ids[2] = 12;

        vm.prank(owner);
        sbt.registerCourses(ids);

        assertTrue(sbt.registeredCourse(10));
        assertTrue(sbt.registeredCourse(11));
        assertTrue(sbt.registeredCourse(12));
    }

    /// @dev Mint should revert after a course is deregistered
    function test_mint_reverts_after_course_deregistered() public {
        vm.prank(owner);
        sbt.deregisterCourse(COURSE_ID);

        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signMintRequest(adminPrivateKey, alice, COURSE_ID, deadline);

        vm.expectRevert(abi.encodeWithSelector(PathtrickSBT.CourseNotRegistered.selector, COURSE_ID));
        vm.prank(alice);
        sbt.mintCertificate{value: MINT_PRICE}(COURSE_ID, deadline, sig);
    }

    /// @dev Non-owner should not be able to register or deregister courses
    function test_non_owner_cannot_register_course() public {
        vm.expectRevert();
        vm.prank(alice);
        sbt.registerCourse(999);
    }

    // =========================================================================
    // SC-04: Mint Validations & Errors
    // =========================================================================

    function test_mint_reverts_if_fee_incorrect() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signMintRequest(adminPrivateKey, alice, COURSE_ID, deadline);

        vm.expectRevert(PathtrickSBT.IncorrectMintFee.selector);
        vm.prank(alice);
        sbt.mintCertificate{value: MINT_PRICE - 1 wei}(COURSE_ID, deadline, sig);
    }

    function test_mint_reverts_if_overpaid() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signMintRequest(adminPrivateKey, alice, COURSE_ID, deadline);

        vm.expectRevert(PathtrickSBT.IncorrectMintFee.selector);
        vm.prank(alice);
        sbt.mintCertificate{value: MINT_PRICE + 1 wei}(COURSE_ID, deadline, sig);
    }

    function test_mint_reverts_if_signature_invalid() public {
        uint256 deadline = block.timestamp + 1 days;
        // Sign for bob but alice tries to use it
        bytes memory sig = _signMintRequest(adminPrivateKey, bob, COURSE_ID, deadline);

        vm.expectRevert(PathtrickSBT.InvalidSignature.selector);
        vm.prank(alice);
        sbt.mintCertificate{value: MINT_PRICE}(COURSE_ID, deadline, sig);
    }

    function test_mint_reverts_if_signed_by_wrong_admin() public {
        (, uint256 wrongKey) = makeAddrAndKey("wrongSigner");
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signMintRequest(wrongKey, alice, COURSE_ID, deadline);

        vm.expectRevert(PathtrickSBT.InvalidSignature.selector);
        vm.prank(alice);
        sbt.mintCertificate{value: MINT_PRICE}(COURSE_ID, deadline, sig);
    }

    function test_mint_reverts_with_expired_signature() public {
        uint256 deadline = block.timestamp - 1;
        bytes memory sig = _signMintRequest(adminPrivateKey, alice, COURSE_ID, deadline);

        vm.expectRevert(PathtrickSBT.SignatureExpired.selector);
        vm.prank(alice);
        sbt.mintCertificate{value: MINT_PRICE}(COURSE_ID, deadline, sig);
    }

    function test_double_mint_reverts() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signMintRequest(adminPrivateKey, alice, COURSE_ID, deadline);

        vm.startPrank(alice);
        sbt.mintCertificate{value: MINT_PRICE}(COURSE_ID, deadline, sig);

        vm.expectRevert(abi.encodeWithSelector(PathtrickSBT.AlreadyCertified.selector, alice, COURSE_ID));
        sbt.mintCertificate{value: MINT_PRICE}(COURSE_ID, deadline, sig);
        vm.stopPrank();
    }

    function test_constructor_reverts_when_owner_equals_admin_signer() public {
        vm.expectRevert(PathtrickSBT.AdminSignerCannotBeOwner.selector);
        new PathtrickSBT(owner, owner, address(0), TOKEN_URI);
    }

    function test_constructor_reverts_with_zero_admin_signer() public {
        vm.expectRevert(PathtrickSBT.ZeroAddress.selector);
        new PathtrickSBT(owner, address(0), address(0), TOKEN_URI);
    }

    // =========================================================================
    // SC-05: Soulbound Properties
    // =========================================================================

    function test_safeTransferFrom_reverts() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signMintRequest(adminPrivateKey, alice, COURSE_ID, deadline);
        vm.prank(alice);
        sbt.mintCertificate{value: MINT_PRICE}(COURSE_ID, deadline, sig);

        vm.expectRevert(PathtrickSBT.SoulboundTokenNonTransferable.selector);
        vm.prank(alice);
        sbt.safeTransferFrom(alice, bob, COURSE_ID, 1, "");
    }

    function test_safeBatchTransferFrom_reverts() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signMintRequest(adminPrivateKey, alice, COURSE_ID, deadline);
        vm.prank(alice);
        sbt.mintCertificate{value: MINT_PRICE}(COURSE_ID, deadline, sig);

        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = COURSE_ID;
        amounts[0] = 1;

        vm.expectRevert(PathtrickSBT.SoulboundTokenNonTransferable.selector);
        vm.prank(alice);
        sbt.safeBatchTransferFrom(alice, bob, ids, amounts, "");
    }

    function test_setApprovalForAll_reverts() public {
        vm.expectRevert(PathtrickSBT.SoulboundTokenNonTransferable.selector);
        vm.prank(alice);
        sbt.setApprovalForAll(bob, true);
    }

    // =========================================================================
    // SC-06: Certificate Revocation
    // =========================================================================

    function test_owner_can_revoke_certificate() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signMintRequest(adminPrivateKey, alice, COURSE_ID, deadline);
        vm.prank(alice);
        sbt.mintCertificate{value: MINT_PRICE}(COURSE_ID, deadline, sig);

        assertTrue(sbt.hasCertificate(alice, COURSE_ID));

        vm.prank(owner);
        sbt.revokeCertificate(alice, COURSE_ID);

        assertFalse(sbt.hasCertificate(alice, COURSE_ID));
        assertEq(sbt.balanceOf(alice, COURSE_ID), 0, "token should be burned");
    }

    /// @dev Certificate record should be cleared after revocation
    function test_revoke_clears_certificate_record() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signMintRequest(adminPrivateKey, alice, COURSE_ID, deadline);
        vm.prank(alice);
        sbt.mintCertificate{value: MINT_PRICE}(COURSE_ID, deadline, sig);

        vm.prank(owner);
        sbt.revokeCertificate(alice, COURSE_ID);

        PathtrickSBT.CertificateRecord memory rec = sbt.getCertificate(alice, COURSE_ID);
        assertEq(rec.issuedAt, 0, "issuedAt should be cleared");
        assertEq(rec.issuer, address(0), "issuer should be cleared");
    }

    function test_revoke_emits_event() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signMintRequest(adminPrivateKey, alice, COURSE_ID, deadline);
        vm.prank(alice);
        sbt.mintCertificate{value: MINT_PRICE}(COURSE_ID, deadline, sig);

        vm.expectEmit(true, true, false, true);
        emit PathtrickSBT.CertificateRevoked(alice, COURSE_ID, owner);

        vm.prank(owner);
        sbt.revokeCertificate(alice, COURSE_ID);
    }

    function test_revoke_reverts_if_not_certified() public {
        vm.expectRevert(abi.encodeWithSelector(PathtrickSBT.NotCertified.selector, alice, COURSE_ID));
        vm.prank(owner);
        sbt.revokeCertificate(alice, COURSE_ID);
    }

    function test_non_owner_cannot_revoke() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signMintRequest(adminPrivateKey, alice, COURSE_ID, deadline);
        vm.prank(alice);
        sbt.mintCertificate{value: MINT_PRICE}(COURSE_ID, deadline, sig);

        vm.expectRevert();
        vm.prank(bob);
        sbt.revokeCertificate(alice, COURSE_ID);
    }

    // =========================================================================
    // SC-07: Pausable
    // =========================================================================

    function test_owner_can_pause_and_unpause() public {
        vm.prank(owner);
        sbt.pause();
        assertTrue(sbt.paused());

        vm.prank(owner);
        sbt.unpause();
        assertFalse(sbt.paused());
    }

    function test_mint_reverts_when_paused() public {
        vm.prank(owner);
        sbt.pause();

        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signMintRequest(adminPrivateKey, alice, COURSE_ID, deadline);

        vm.expectRevert();
        vm.prank(alice);
        sbt.mintCertificate{value: MINT_PRICE}(COURSE_ID, deadline, sig);
    }

    function test_mint_usdg_reverts_when_paused() public {
        vm.prank(owner);
        sbt.pause();

        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signMintRequest(adminPrivateKey, alice, COURSE_ID, deadline);

        vm.startPrank(alice);
        usdg.approve(address(sbt), MINT_PRICE_USDG);
        vm.expectRevert();
        sbt.mintCertificateWithUSDG(COURSE_ID, deadline, sig);
        vm.stopPrank();
    }

    /// @dev Mint should work again after unpausing
    function test_mint_succeeds_after_unpause() public {
        vm.prank(owner);
        sbt.pause();
        vm.prank(owner);
        sbt.unpause();

        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signMintRequest(adminPrivateKey, alice, COURSE_ID, deadline);

        vm.prank(alice);
        sbt.mintCertificate{value: MINT_PRICE}(COURSE_ID, deadline, sig);

        assertEq(sbt.balanceOf(alice, COURSE_ID), 1);
    }

    /// @dev Non-owner should not be able to pause
    function test_non_owner_cannot_pause() public {
        vm.expectRevert();
        vm.prank(alice);
        sbt.pause();
    }

    // =========================================================================
    // SC-08: Admin & Owner Functions
    // =========================================================================

    function test_owner_can_withdraw_eth() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signMintRequest(adminPrivateKey, alice, COURSE_ID, deadline);
        vm.prank(alice);
        sbt.mintCertificate{value: MINT_PRICE}(COURSE_ID, deadline, sig);

        assertEq(address(sbt).balance, MINT_PRICE);

        uint256 ownerBefore = owner.balance;
        vm.prank(owner);
        sbt.withdraw();

        assertEq(address(sbt).balance, 0);
        assertEq(owner.balance, ownerBefore + MINT_PRICE);
    }

    function test_owner_can_withdraw_usdg() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signMintRequest(adminPrivateKey, alice, COURSE_ID, deadline);

        vm.startPrank(alice);
        usdg.approve(address(sbt), MINT_PRICE_USDG);
        sbt.mintCertificateWithUSDG(COURSE_ID, deadline, sig);
        vm.stopPrank();

        assertEq(usdg.balanceOf(address(sbt)), MINT_PRICE_USDG);

        vm.prank(owner);
        sbt.withdrawUSDG();

        assertEq(usdg.balanceOf(address(sbt)), 0);
        assertEq(usdg.balanceOf(owner), MINT_PRICE_USDG);
    }

    function test_non_owner_cannot_withdraw() public {
        vm.expectRevert();
        vm.prank(alice);
        sbt.withdraw();
    }

    function test_owner_can_set_admin_signer() public {
        address newSigner = makeAddr("newSigner");

        vm.expectEmit(true, true, false, false);
        emit PathtrickSBT.AdminSignerUpdated(adminSigner, newSigner);

        vm.prank(owner);
        sbt.setAdminSigner(newSigner);

        assertEq(sbt.adminSigner(), newSigner);
    }

    function test_owner_cannot_set_self_as_admin_signer() public {
        vm.expectRevert(PathtrickSBT.AdminSignerCannotBeOwner.selector);
        vm.prank(owner);
        sbt.setAdminSigner(owner);
    }

    /// @dev setAdminSigner with zero address should revert
    function test_owner_cannot_set_zero_admin_signer() public {
        vm.expectRevert(PathtrickSBT.ZeroAddress.selector);
        vm.prank(owner);
        sbt.setAdminSigner(address(0));
    }

    function test_owner_can_set_mint_price() public {
        uint256 newPrice = 0.01 ether;

        vm.expectEmit(false, false, false, true);
        emit PathtrickSBT.MintPriceUpdated(MINT_PRICE, newPrice);

        vm.prank(owner);
        sbt.setMintPrice(newPrice);

        assertEq(sbt.mintPrice(), newPrice);
    }

    function test_owner_can_set_mint_price_usdg() public {
        uint256 newPrice = 2e6; // 2 USDG

        vm.prank(owner);
        sbt.setMintPriceUSDG(newPrice);

        assertEq(sbt.mintPriceUSDG(), newPrice);
    }

    /// @dev setUSDGToken should update the token address
    function test_owner_can_update_usdg_token() public {
        address newToken = makeAddr("newUSDG");

        vm.expectEmit(false, false, false, true);
        emit PathtrickSBT.USDGTokenUpdated(address(usdg), newToken);

        vm.prank(owner);
        sbt.setUSDGToken(newToken);

        assertEq(address(sbt.usdgToken()), newToken);
    }

    /// @dev Ownable2Step: pending owner transfer should work
    function test_ownership_transfer_two_step() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        sbt.transferOwnership(newOwner);

        // pendingOwner must accept
        assertEq(sbt.owner(), owner, "owner should not change yet");

        vm.prank(newOwner);
        sbt.acceptOwnership();

        assertEq(sbt.owner(), newOwner, "ownership should transfer after accept");
    }

    // =========================================================================
    // SC-09: Fuzzing & Security Tests
    // =========================================================================

    function testFuzz_mint_reverts_with_random_signature(bytes calldata randomSig, uint256 courseId) public {
        vm.assume(randomSig.length == 65);
        vm.prank(owner);
        sbt.registerCourse(courseId);

        vm.expectRevert();
        vm.prank(alice);
        sbt.mintCertificate{value: MINT_PRICE}(courseId, block.timestamp + 1 days, randomSig);
    }

    function testFuzz_mint_reverts_with_incorrect_fee(uint256 randomFee) public {
        vm.assume(randomFee != MINT_PRICE);

        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signMintRequest(adminPrivateKey, alice, COURSE_ID, deadline);

        vm.deal(alice, randomFee);
        vm.expectRevert(PathtrickSBT.IncorrectMintFee.selector);
        vm.prank(alice);
        sbt.mintCertificate{value: randomFee}(COURSE_ID, deadline, sig);
    }

    function testFuzz_soulbound_prevents_arbitrary_transfers(address attacker, address recipient, uint256 courseId)
        public
    {
        vm.assume(attacker != address(0));
        vm.assume(recipient != address(0));

        vm.expectRevert();
        vm.prank(attacker);
        sbt.safeTransferFrom(attacker, recipient, courseId, 1, "");
    }
}
