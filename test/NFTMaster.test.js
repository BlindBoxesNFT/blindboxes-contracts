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

contract('NFTMaster', ([dev, curator, artist, buyer0, buyer1, feeTo, randomGuy, linkToken]) => {
  beforeEach(async () => {
    // Mock USDC, 100 million, then transfer to buyer0, and buyer1 each 10 million
    this.baseToken = await MockERC20.new("Mock USDC", "USDC", appendZeroes(1, 26), { from: dev });
    await this.baseToken.transfer(buyer0, appendZeroes(1, 25), { from: dev });
    await this.baseToken.transfer(buyer1, appendZeroes(1, 25), { from: dev });

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

    await this.nftMaster.setBaseToken(this.baseToken.address, { from: dev });
    await this.nftMaster.setBlesToken(this.blesToken.address, { from: dev });
    await this.nftMaster.setLinkToken(linkToken, { from: dev });
    await this.nftMaster.setFeeTo(feeTo, { from: dev });
  });

  it('create, add, and buy with USDC', async () => {
    this.linkAccessor = await MockLinkAccessor.new(this.nftMaster.address, { from: dev });
    await this.nftMaster.setLinkAccessor(this.linkAccessor.address, { from: dev });

    // Curator create an empty collection, charges 10% commission.
    await this.nftMaster.createCollection("Art gallery", 4, 1000, false, [artist],  { from: curator });
    const collectionId = await this.nftMaster.nextCollectionId();
    assert.equal(collectionId.valueOf(), 1);

    // Add NFTs to collection.

    // 100 USDC
    await this.mockCat.approve(this.nftMaster.address, 0, {from: curator});
    await this.nftMaster.addNFTToCollection(this.mockCat.address, 0, collectionId, appendZeroes(1, 20), {from: curator});

    // 200 USDC
    await this.mockCat.approve(this.nftMaster.address, 1, {from: artist});
    await this.nftMaster.addNFTToCollection(this.mockCat.address, 1, collectionId, appendZeroes(2, 20), {from: artist});

    // 300 USDC
    await this.mockDog.approve(this.nftMaster.address, 0, {from: curator});
    await this.nftMaster.addNFTToCollection(this.mockDog.address, 0, collectionId, appendZeroes(3, 20), {from: curator});

    // 400 USDC
    await this.mockDog.approve(this.nftMaster.address, 1, {from: artist});
    await this.nftMaster.addNFTToCollection(this.mockDog.address, 1, collectionId, appendZeroes(3, 20), {from: artist});

    // Remove dog #1.
    const dog1NFTId = await this.nftMaster.nftIdMap(this.mockDog.address, 1, {from: artist});
    await this.nftMaster.removeNFTFromCollection(dog1NFTId.valueOf(), collectionId, {from: artist});
    assert.equal(await this.mockDog.ownerOf(1), artist);

    // Publish
    await this.nftMaster.publishCollection(1, [linkToken], 0, 0, {from: curator});

    // View the published collection.
    const collection = await this.nftMaster.allCollections(collectionId, {from: buyer0});
    assert.equal(collection[0], curator);  // owner
    assert.equal(collection[1], "Art gallery");  // name
    assert.equal(collection[2].valueOf(), 3);  // size
    assert.equal(collection[3].valueOf(), 1000);  // commissionRate
    assert.equal(collection[4].valueOf(), 0);  // willAcceptBLES
    assert.equal(collection[5].valueOf(), 6e20);  // totalPrice
    assert.equal(collection[6].valueOf(), 2e20);  // averagePrice
    assert.equal(collection[7].valueOf(), 3e19);  // fee
    assert.equal(collection[8].valueOf(), 6e19);  // commission

    assert.notEqual(collection[9].valueOf(), 0);  // isPublished

    assert.equal(await this.nftMaster.collaborators(collectionId, 0), artist);

    // Buy and withdraw
    await this.linkAccessor.setRandomness(11, {from: dev});

    // buyer0 buys 1.
    await this.baseToken.approve(this.nftMaster.address, appendZeroes(2, 20), {from: buyer0});
    await this.nftMaster.drawBoxes(collectionId, 1, {from: buyer0});
    // buyer1 buys 2.
    await this.baseToken.approve(this.nftMaster.address, appendZeroes(4, 20), {from: buyer1});
    await this.nftMaster.drawBoxes(collectionId, 2, {from: buyer1});

    // Trigger randomness (mock)
    await this.linkAccessor.triggerRandomness({from: dev});

    const rrr = await this.nftMaster.nftMapping(collectionId, 0, {from: randomGuy});

    // Check for result.
    const winner0 = await this.nftMaster.getWinner(collectionId, 0, {from: randomGuy});
    const winner1 = await this.nftMaster.getWinner(collectionId, 1, {from: randomGuy});
    const winner2 = await this.nftMaster.getWinner(collectionId, 2, {from: randomGuy});

    const nftId0 = await this.nftMaster.nftIdMap(this.mockCat.address, 0, {from: artist});
    const nftId1 = await this.nftMaster.nftIdMap(this.mockCat.address, 1, {from: artist});
    const nftId2 = await this.nftMaster.nftIdMap(this.mockDog.address, 0, {from: artist});
    const winnerData = [[winner0, nftId0], [winner1, nftId1], [winner2, nftId2]];

    const buyer0NFTIdArray = winnerData.filter(entry => entry[0] == buyer0).map(entry => entry[1]);
    const buyer1NFTIdArray = winnerData.filter(entry => entry[0] == buyer1).map(entry => entry[1]);

    assert.equal(buyer0NFTIdArray.length, 1);
    assert.equal(buyer1NFTIdArray.length, 2);

    // Withdraw.
    // Here nft index happen to be nftId - 1.
    await this.nftMaster.claimNFT(collectionId, buyer0NFTIdArray[0] - 1, {from: buyer0});
    await this.nftMaster.claimNFT(collectionId, buyer1NFTIdArray[0] - 1, {from: buyer1});
    await this.nftMaster.claimNFT(collectionId, buyer1NFTIdArray[1] - 1, {from: buyer1});

    // Curator and artist all get money, after 5% fee and 10% commission deducted.
    const curatorBalance = await this.baseToken.balanceOf(curator, {from: curator});
    assert.equal(curatorBalance.valueOf(), 34e19);
    const artistBalance = await this.baseToken.balanceOf(artist, {from: artist});
    assert.equal(artistBalance.valueOf(), 17e19);

    // feeTo got fee.
    await this.nftMaster.claimFee(collectionId, {from: randomGuy});
    const feeToBalance = await this.baseToken.balanceOf(feeTo, {from: feeTo});
    assert.equal(feeToBalance.valueOf(), 3e19);

    // curator got commission.
    await this.nftMaster.claimCommission(collectionId, {from: curator});
    const curatorNewBalance = await this.baseToken.balanceOf(curator, {from: curator});
    assert.equal(curatorNewBalance.valueOf(), 40e19);  // 34 + 6 = 40
  });

  it('create, add, published and unpublished', async () => {
    // Curator create an empty collection, charges 10% commission.
    await this.nftMaster.createCollection("Art gallery", 4, 1000, false, [artist],  { from: curator });
    const collectionId = await this.nftMaster.nextCollectionId();
    assert.equal(collectionId.valueOf(), 1);

    // Add NFTs to collection.

    // 100 USDC
    await this.mockCat.approve(this.nftMaster.address, 0, {from: curator});
    await this.nftMaster.addNFTToCollection(this.mockCat.address, 0, collectionId, appendZeroes(1, 20), {from: curator});

    // 200 USDC
    await this.mockCat.approve(this.nftMaster.address, 1, {from: artist});
    await this.nftMaster.addNFTToCollection(this.mockCat.address, 1, collectionId, appendZeroes(2, 20), {from: artist});

    // 300 USDC
    await this.mockDog.approve(this.nftMaster.address, 0, {from: curator});
    await this.nftMaster.addNFTToCollection(this.mockDog.address, 0, collectionId, appendZeroes(3, 20), {from: curator});

    // Publish
    await this.nftMaster.publishCollection(1, [linkToken], 0, 0, {from: curator});

    // View the published collection.
    const collection = await this.nftMaster.allCollections(collectionId, {from: buyer0});
    assert.notEqual(collection[9].valueOf(), 0);  // isPublished

    assert.equal(await this.nftMaster.collaborators(collectionId, 0), artist);

    // buyer0 buys 1.
    await this.baseToken.approve(this.nftMaster.address, appendZeroes(2e20), {from: buyer0});
    await this.nftMaster.drawBoxes(collectionId, 1, {from: buyer0});

    await expectRevert(
      this.nftMaster.unpublishCollection(collectionId, {from: curator}),
      'Not expired yet',
    );

    // buyer1 buys 2.
    await this.baseToken.approve(this.nftMaster.address, appendZeroes(4e20), {from: buyer1});
    await this.nftMaster.drawBoxes(collectionId, 1, {from: buyer1});

    await time.increase(time.duration.days(15));
    await this.nftMaster.unpublishCollection(collectionId, {from: curator});
    const collectionAfterUnpublished = await this.nftMaster.allCollections(collectionId, {from: buyer0});
    assert.equal(collectionAfterUnpublished[9].valueOf(), 0);  //isPublished
    assert.equal(collectionAfterUnpublished[11].valueOf(), 0); //soldCount

    const buy0Balance = await this.baseToken.balanceOf(buyer0, {from: buyer0});
    assert.equal(buy0Balance.valueOf(), appendZeroes(1, 25));
    const buy1Balance = await this.baseToken.balanceOf(buyer1, {from: buyer1});
    assert.equal(buy1Balance.valueOf(), appendZeroes(1, 25));

    // Publish
    await this.nftMaster.publishCollection(1, [linkToken], 0, 0, {from: curator});

    const publishCollectionSecond = await this.nftMaster.allCollections(collectionId, {from: buyer0});
    assert.notEqual(publishCollectionSecond[9].valueOf(), 0);  // isPublished

    // buyer0 buys 1.
    await this.baseToken.approve(this.nftMaster.address, appendZeroes(2e20), {from: buyer0});
    await this.nftMaster.drawBoxes(collectionId, 1, {from: buyer0});
    // buyer1 buys 2.
    await this.baseToken.approve(this.nftMaster.address, appendZeroes(4e20), {from: buyer1});
    await this.nftMaster.drawBoxes(collectionId, 2, {from: buyer1});

    await time.increase(time.duration.days(15));
    // sold out
    await expectRevert(
      this.nftMaster.unpublishCollection(collectionId, {from: curator}),
      'Sold out',
    );
  });

  it('test 100 NFT.', async () => {
    // Curator create an empty collection, charges 10% commission.
    await this.nftMaster.createCollection("Pig gallery", 100, 1000, false, [artist],  { from: curator });
    const collectionId = await this.nftMaster.nextCollectionId();
    assert.equal(collectionId.valueOf(), 1);

    const mockPig = await MockNFT.new("Mock Pig", "PIG", { from: dev });

    // Add NFTs to collection.

    for (let i = 0; i < 100; ++i) {
      await mockPig.mint(curator, i, { from: dev });
      await mockPig.approve(this.nftMaster.address, i, {from: curator});
      // (i + 1) * 100 USDC
      await this.nftMaster.addNFTToCollection(mockPig.address, i, collectionId, appendZeroes((i + 1), 20), {from: curator});
    }

    // Publish
    await this.nftMaster.publishCollection(1, [linkToken], 0, 0, {from: curator});

    // View the published collection.
    const collection = await this.nftMaster.allCollections(collectionId, {from: buyer0});

    assert.equal(collection[0], curator);  // owner
    assert.equal(collection[1], "Pig gallery");  // name
    assert.equal(collection[2].valueOf(), 100);  // size
    assert.equal(collection[3].valueOf(), 1000);  // commissionRate
    assert.equal(collection[4].valueOf(), 0);  // willAcceptBLES
    assert.equal(collection[5].valueOf(), 505e21);  // totalPrice
    assert.equal(collection[6].valueOf(), 505e19);  // averagePrice
    assert.equal(collection[7].valueOf(), 2525e19);  // fee
    assert.equal(collection[8].valueOf(), 505e20);  // commission

    assert.notEqual(collection[9].valueOf(), 0);  // isPublished
    assert.equal(await this.nftMaster.collaborators(collectionId, 0), artist);

    // Buy and withdraw

    // buyer0 buys 40.
    for (let i = 0; i < 40; ++i) {
      await this.baseToken.approve(this.nftMaster.address, appendZeroes(505, 19), {from: buyer0});
      await this.nftMaster.drawBoxes(collectionId, 1, {from: buyer0});
    }
    // buyer1 buys 60.
    for (let i = 0; i < 60; ++i) {
      await this.baseToken.approve(this.nftMaster.address, appendZeroes(505, 19), {from: buyer1});
      await this.nftMaster.drawBoxes(collectionId, 1, {from: buyer1});
    }

    // Check for result.
    let buyer0Count = 0;
    let buyer1Count = 0;
    for (let i = 0; i < 100; ++i) {
      const winner = await this.nftMaster.getWinner(collectionId, i, {from: randomGuy});
      if (winner == buyer0) {
        ++buyer0Count;
      } else if (winner == buyer1) {
        ++buyer1Count;
      }
    }

    assert.equal(buyer0Count, 40);
    assert.equal(buyer1Count, 60);
  });
});
