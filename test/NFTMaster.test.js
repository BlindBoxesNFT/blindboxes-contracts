const { expectRevert, time } = require('@openzeppelin/test-helpers');
const ethers = require('ethers');
const MockERC20 = artifacts.require('MockERC20');
const MockLinkAccessor = artifacts.require('MockLinkAccessor');
const MockNFT = artifacts.require('MockNFT');
const MockNFTMaster = artifacts.require('MockNFTMaster');

function encodeParameters(types, values) {
  const abi = new ethers.utils.AbiCoder();
  return abi.encode(types, values);
}

function appendZeroes(value, count) {
  var result = value.toString();
  for (var i = 0; i < count; ++i) {
    result += '0';
  }

  return result;
}

contract('NFTMaster', ([dev, curator, artist, buyer0, buyer1]) => {
  beforeEach(async () => {
    // Mock USDC, 100 million
    this.baseToken = await MockERC20.new("Mock USDC", "USDC", appendZeroes(1, 26), { from: dev });

    // Mock BLES, 100 million
    this.blesToken = await MockERC20.new("Mock BLES", "BLES", appendZeroes(1, 26), { from: dev });

    // Mock NFTMaster
    this.nftMaster = await MockNFTMaster.new({ from: dev });

    // Mock NFT
    this.mockCat = await MockNFT.new("Mock Cat", "CAT", { from: dev });
    this.mockDog = await MockNFT.new("Mock Dog", "DOG", { from: dev });

    await this.mockCat.mint(curator, 0, { from: dev });
    await this.mockCat.mint(artist, 1, { from: dev });
    await this.mockDog.mint(curator, 0, { from: dev });
    await this.mockDog.mint(artist, 1, { from: dev });

    // Mock linkAccessor
    this.linkAccessor = await MockLinkAccessor.new(this.nftMaster.address, { from: dev });

    await this.nftMaster.setBaseToken(this.baseToken.address, { from: dev });
    await this.nftMaster.setBlesToken(this.blesToken.address, { from: dev });
    await this.nftMaster.setLinkAccessor(this.linkAccessor.address, { from: dev });
    await this.nftMaster.setFeeTo(dev, { from: dev });
  });

  it('create, add, and buy with USDC', async () => {
    // Curator create an empty collection.
    await this.nftMaster.createCollection("Art gallery", 3, false, [artist],  { from: curator });
    const collectionId = await this.nftMaster.nextCollectionId();
    assert.equal(collectionId.valueOf(), 1);

    // Deposit NFT.
    await this.mockCat.approve(this.nftMaster.address, 0, {from: curator});
    await this.nftMaster.depositNFT(this.mockCat.address, 0, {from: curator});
    const nftId0 = await this.nftMaster.nextNFTId();
    assert.equal(nftId0.valueOf(), 1);

    await this.mockCat.approve(this.nftMaster.address, 1, {from: artist});
    await this.nftMaster.depositNFT(this.mockCat.address, 1, {from: artist});
    const nftId1 = await this.nftMaster.nextNFTId();
    assert.equal(nftId1.valueOf(), 2);

    await this.mockDog.approve(this.nftMaster.address, 0, {from: curator});
    await this.nftMaster.depositNFT(this.mockDog.address, 0, {from: curator});
    const nftId2 = await this.nftMaster.nextNFTId();
    assert.equal(nftId2.valueOf(), 3);

    // Add NFTs to collection.

    // 100 USDC
    await this.nftMaster.addNFTToCollection(1, 1, appendZeroes(1, 20), {from: curator});

    // 200 USDC
    await this.nftMaster.addNFTToCollection(2, 1, appendZeroes(2, 20), {from: artist});

    // 300 USDC
    await this.nftMaster.addNFTToCollection(3, 1, appendZeroes(3, 20), {from: curator});

    // Publish
    await this.nftMaster.publishCollection(1, 0, 0, {from: curator});

    // View the published collection.
    const collection = await this.nftMaster.allCollections(1, {from: buyer0});
    assert.equal(collection[0], curator);  // owner
    assert.equal(collection[1], "Art gallery");  // name
    assert.equal(collection[2].valueOf(), 3);  // size
    assert.equal(collection[3].valueOf(), 6e20);  // totalPrice
    assert.equal(collection[4].valueOf(), 2e20);  // averagePrice
    assert.equal(collection[5].valueOf(), 0);  // willAcceptBLES
    assert.equal(collection[6].valueOf(), 1);  // isPublished

    // TODO: buy and withdraw
  });
});
