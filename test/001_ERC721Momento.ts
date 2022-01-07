import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import type { Contract } from "ethers";

let ERC721Momento;
let erc721Momento: Contract;

// Start test block
describe("ERC721Momento", () => {
  beforeEach(async () => {
    ERC721Momento = await ethers.getContractFactory("ERC721Momento");
    erc721Momento = await upgrades.deployProxy(ERC721Momento);
  });

  // Test case
  it("retrieve returns a name, symbol", async () => {
    expect((await erc721Momento.name()).toString()).to.equal("Momento NFT");
    expect((await erc721Momento.symbol()).toString()).to.equal("MNTNFT");
  });

  // Test case
  it("mint nft", async () => {
    const [owner] = await ethers.getSigners();
    erc721Momento.connect(owner).createItem(100);
  });
});
