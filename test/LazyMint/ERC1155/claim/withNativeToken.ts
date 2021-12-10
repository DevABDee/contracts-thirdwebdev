import { ethers } from "hardhat";
import { expect, use } from "chai";
import { solidity } from "ethereum-waffle";

// Contract Types
import { LazyMintERC1155, MintConditionStruct } from "typechain/LazyMintERC1155";

// Types
import { BigNumber, BytesLike } from "ethers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

// Test utils
import { getContracts, Contracts } from "../../../../utils/tests/getContracts";
import { MerkleTree } from 'merkletreejs'
import keccak256 from "keccak256"

use(solidity);

describe("Test: claim lazy minted tokens with native tokens", function() {
  // Constants
  const NATIVE_TOKEN_ADDRESS: string = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE";
    
  // Signers
  let protocolProvider: SignerWithAddress;
  let protocolAdmin: SignerWithAddress;
  let claimer: SignerWithAddress;

  // Contracts
  let lazyMintERC1155: LazyMintERC1155;

  // Lazy minting params
  const amountToLazyMint: BigNumber = BigNumber.from(10_000);
  const baseURI: string = "ipfs://baseURI/";

  // Setting mint conditions default params
  const tokenId: BigNumber = BigNumber.from(0);
  let mintConditions: MintConditionStruct[];

  // Claim params
  let proof: BytesLike[];
  let quantityToClaim: BigNumber;
  let totalPrice: BigNumber;

  // Test params
  let targetMintConditionIndex: BigNumber;
  let royaltyTreasury: string;

  // Helper functions

  const timeTravelToMintCondition = async (_tokenId: BigNumber, _conditionIndex: BigNumber) => {
    // Time travel
    const travelTo: string = (await lazyMintERC1155.getMintConditionAtIndex(_tokenId, _conditionIndex)).startTimestamp.toString();
    await ethers.provider.send("evm_mine", [parseInt(travelTo)]);
  };

  before(async () => {
    [protocolProvider, protocolAdmin, claimer] = await ethers.getSigners()
  })

  beforeEach(async () => {  
    const contracts: Contracts = await getContracts(protocolProvider, protocolAdmin);
    lazyMintERC1155 = contracts.lazyMintERC1155;
    royaltyTreasury = contracts.protocolControl.address;

    // Lazy mint tokens
    await lazyMintERC1155.connect(protocolAdmin).lazyMint(amountToLazyMint, baseURI);

    // Generate a merkle root for whitelisting
    const leaves = [claimer.address].map(x => keccak256(x));
    const tree = new MerkleTree(leaves, keccak256);
    const whitelist = tree.getRoot();    

    // Set mint conditions
    const templateMintCondition: MintConditionStruct = {
      
      startTimestamp: BigNumber.from(
          (await ethers.provider.getBlock("latest")).timestamp
        ).add(100),
      maxMintSupply: BigNumber.from(15),
      currentMintSupply: BigNumber.from(0),
      quantityLimitPerTransaction: BigNumber.from(5),
      waitTimeInSecondsBetweenClaims: BigNumber.from(5),
      merkleRoot: whitelist,
      pricePerToken: ethers.utils.parseEther("0.1"),
      currency: NATIVE_TOKEN_ADDRESS
    }

    mintConditions = [...Array(5).keys()]
      .map((val: number) => val * 100)
      .map((val: number) => {
        return {
          ...templateMintCondition,
          startTimestamp: (templateMintCondition.startTimestamp as BigNumber).add(val)
        }
      })
    
    // Set claim params
    proof = tree.getProof(claimer.address);
    quantityToClaim = BigNumber.from(mintConditions[0].quantityLimitPerTransaction);
    totalPrice = quantityToClaim.mul(mintConditions[0].pricePerToken);

    // Set mint conditions
    await lazyMintERC1155.connect(protocolAdmin).setPublicMintConditions(tokenId, mintConditions)

    // Travel to mint condition start
    targetMintConditionIndex = BigNumber.from(0);
    await timeTravelToMintCondition(tokenId, targetMintConditionIndex);
  })

  describe("Revert cases", function() {
    it("Should revert if quantity wanted is zero", async () => {
      const invalidQty: BigNumber = BigNumber.from(0);
      await expect(
        lazyMintERC1155.connect(claimer).claim(tokenId, invalidQty, proof, { value: totalPrice })
      ).to.be.revertedWith("LazyMintERC1155: invalid quantity claimed.")
    })

    it("Should revert if quantity wanted is greater than limit per transaction", async () => {      
      const invalidQty: BigNumber = (mintConditions[0].quantityLimitPerTransaction as BigNumber).add(1);

      await expect(
        lazyMintERC1155.connect(claimer).claim(tokenId, invalidQty, proof, { value: totalPrice })
      ).to.be.revertedWith("LazyMintERC1155: invalid quantity claimed.")
    })

    it("Should revert if tokenId provided is unminted", async () => {      
      const invalidTokenId: BigNumber = amountToLazyMint.add(1);
      
      await expect(
        lazyMintERC1155.connect(claimer).claim(invalidTokenId, quantityToClaim, proof, { value: totalPrice })
      ).to.be.revertedWith("LazyMintERC1155: no public mint condition.")
    })

    it("Should revert if quantity wanted + current mint supply exceeds max mint supply", async () => {      
      let currentMintSupply: BigNumber = BigNumber.from(0);
      const maxMintSupply: BigNumber = mintConditions[0].maxMintSupply as BigNumber;

      while(currentMintSupply.lt(maxMintSupply)) {

        if((currentMintSupply.add(quantityToClaim)).gt(maxMintSupply)) {
          await expect(
            lazyMintERC1155.connect(claimer).claim(tokenId, quantityToClaim, proof, { value: totalPrice })
          ).to.be.revertedWith("LazyMintERC1155: exceed max mint supply.")
        }

        await lazyMintERC1155.connect(claimer).claim(tokenId, quantityToClaim, proof, { value: totalPrice })
        const nextValidTimestampForClaim: BigNumber = await lazyMintERC1155.getTimesForNextValidClaim(tokenId, targetMintConditionIndex, claimer.address)
        await ethers.provider.send("evm_mine", [nextValidTimestampForClaim.toNumber()]);

        currentMintSupply = currentMintSupply.add(quantityToClaim);
      }
    })

    it("Should revert if claimer claims before valid timestamp for transaction", async () => {      
      await lazyMintERC1155.connect(claimer).claim(tokenId, quantityToClaim, proof, { value: totalPrice })

      await expect(
        lazyMintERC1155.connect(claimer).claim(tokenId, quantityToClaim, proof, { value: totalPrice })
      ).to.be.revertedWith("LazyMintERC1155: cannot claim yet.")
    })

    it("Should revert if claimer is not in the whitelist", async () => {
      await expect(
        lazyMintERC1155.connect(protocolAdmin).claim(tokenId, quantityToClaim, proof, { value: totalPrice })
      ).to.be.revertedWith("LazyMintERC1155: not in whitelist.")
    })

    it("Should revert if caller has not sent enough native token", async () => {
      await expect(
        lazyMintERC1155.connect(claimer).claim(tokenId, quantityToClaim, proof)
      ).to.be.revertedWith("LazyMintERC1155: must send total price.")
    })
  })
  
  describe("Events", function() {
    it("Should emit ClaimedTokens", async () => {
      await expect(
        lazyMintERC1155.connect(claimer).claim(tokenId, quantityToClaim, proof, { value: totalPrice })
      ).to.emit(lazyMintERC1155, "ClaimedTokens")
      .withArgs(
        ...Object.values({
          mintConditionIndex: targetMintConditionIndex,
          tokenId: tokenId,
          claimer: claimer.address,
          quantityClaimed: quantityToClaim
        })
      )
    })
  })
  
  describe("Balances", function() {
    it("Should increase the claimer's balance of the tokens claimed", async () => {
      const claimerBalBefore: BigNumber = await lazyMintERC1155.balanceOf(claimer.address, tokenId);
      await lazyMintERC1155.connect(claimer).claim(tokenId, quantityToClaim, proof, { value: totalPrice })
      const claimerBalAfter: BigNumber = await lazyMintERC1155.balanceOf(claimer.address, tokenId);

      expect(claimerBalAfter).to.equal(claimerBalBefore.add(quantityToClaim));
    })

    it("Should decrease the currency balance of the claimer", async () => {
      const claimerBalBefore: BigNumber = await ethers.provider.getBalance(claimer.address);

      const gasPrice: BigNumber = ethers.utils.parseUnits("10", "gwei");
      const tx = await lazyMintERC1155.connect(claimer).claim(tokenId, quantityToClaim, proof, { value: totalPrice, gasPrice });
      const gasUsed: BigNumber = (await tx.wait()).gasUsed;
      const gasPaid: BigNumber = gasPrice.mul(gasUsed);
      
      const claimerBalAfter: BigNumber = await ethers.provider.getBalance(claimer.address);

      expect(claimerBalAfter).to.equal(claimerBalBefore.sub(totalPrice.add(gasPaid)));
    })

    it("Should distribute the sale value to the relevant stakeholders", async () => {
      // Set fees to 5 %
      const MAX_BPS: BigNumber = BigNumber.from(10_000);
      const feeBps: BigNumber = BigNumber.from(500);
      await lazyMintERC1155.connect(protocolAdmin).setFeeBps(feeBps);
      
      const fees: BigNumber = (totalPrice.mul(feeBps)).div(MAX_BPS);
      const feeRecipient: string = royaltyTreasury

      const remainder: BigNumber = totalPrice.sub(fees);
      const remainderRecipient: string = protocolAdmin.address;

      const feeRecipientBalBefore: BigNumber = await ethers.provider.getBalance(feeRecipient);
      const remainderRecipientBalBefore: BigNumber = await ethers.provider.getBalance(remainderRecipient);

      await lazyMintERC1155.connect(claimer).claim(tokenId, quantityToClaim, proof, { value: totalPrice });

      const feeRecipientBalAfter: BigNumber = await ethers.provider.getBalance(feeRecipient);
      const remainderRecipientBalAfter: BigNumber = await ethers.provider.getBalance(remainderRecipient);

      expect(feeRecipientBalAfter).to.equal(feeRecipientBalBefore.add(fees))
      expect(remainderRecipientBalAfter).to.equal(remainderRecipientBalBefore.add(remainder));
    })
  })

  describe("Contract state", function() {
    it("Should update the supply minted during the claim condition", async () => {
      const currenMintSupplyBefore = (await lazyMintERC1155.getMintConditionAtIndex(tokenId, targetMintConditionIndex)).currentMintSupply;
      await lazyMintERC1155.connect(claimer).claim(tokenId, quantityToClaim, proof, { value: totalPrice });
      const currenMintSupplyAfter = (await lazyMintERC1155.getMintConditionAtIndex(tokenId, targetMintConditionIndex)).currentMintSupply;

      expect(currenMintSupplyAfter).to.equal(currenMintSupplyBefore.add(quantityToClaim));
    })
    it("Should update the next valid timestamp for claim, for the claimer", async () => {
      const waitBetweenClaims: BigNumber = (await lazyMintERC1155.getMintConditionAtIndex(tokenId, targetMintConditionIndex)).waitTimeInSecondsBetweenClaims;
      await lazyMintERC1155.connect(claimer).claim(tokenId, quantityToClaim, proof, { value: totalPrice });

      const currentTimestamp: BigNumber = BigNumber.from((await ethers.provider.getBlock("latest")).timestamp)
      const expectedNextValidTimestamp: BigNumber = currentTimestamp.add(waitBetweenClaims);

      expect(
        await lazyMintERC1155.getTimesForNextValidClaim(tokenId, targetMintConditionIndex, claimer.address)
      ).to.equal(expectedNextValidTimestamp);
    })
  })
})