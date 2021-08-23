const { expectRevert, time } = require('@openzeppelin/test-helpers');
const ethers = require('ethers');
const BLES = artifacts.require('BLES');
const Staking = artifacts.require('Staking');

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

contract('Staking', ([dev, user0, user1]) => {
  beforeEach(async () => {
    // Mock BLES, 100 million, then transfer to user0, and user1 each 1000
    this.blesToken = await BLES.new({ from: dev });
    await this.blesToken.transfer(user0, appendZeroes(1, 21), { from: dev });
    await this.blesToken.transfer(user1, appendZeroes(1, 21), { from: dev });

    // Staking
    this.staking = await Staking.new(this.blesToken.address, { from: dev });

    this.firstBlock = await time.latestBlock();

    // Adds 2 pools to staking, from block 10 to block 1000010, 1 BLES per block.
    // Lock for 0 days.
    await this.staking.add(this.blesToken.address, appendZeroes(1, 18), this.firstBlock + 10, this.firstBlock + 1000010, 0, { from: dev })
    // Lock for 40 days.
    await this.staking.add(this.blesToken.address, appendZeroes(1, 18), this.firstBlock + 10, this.firstBlock + 1000010, 40, { from: dev })
  });

  it('deposit, withdraw and claim', async () => {
    await this.blesToken.approve(this.staking.address, appendZeroes(1, 21), { from: user0 });
    await this.blesToken.approve(this.staking.address, appendZeroes(1, 21), { from: user1 });

    // Each of user0 and user1, deposit 100 BLES to each pool.
    await this.staking.deposit(0, appendZeroes(1, 20), { from: user0 });
    await this.staking.deposit(1, appendZeroes(1, 20), { from: user0 });
    await this.staking.deposit(0, appendZeroes(1, 20), { from: user1 });
    await this.staking.deposit(1, appendZeroes(1, 20), { from: user1 });

    await time.advanceBlockTo(this.firstBlock + 20);

    const pending0_0 = await this.staking.pendingReward(0, user0);
    const pending0_1 = await this.staking.pendingReward(1, user0);
    const pending1_0 = await this.staking.pendingReward(0, user1);
    const pending1_1 = await this.staking.pendingReward(1, user1);
    assert.equal(pending0_0.valueOf(), 5e18);
    assert.equal(pending0_1.valueOf(), 5e18);
    assert.equal(pending1_0.valueOf(), 5e18);
    assert.equal(pending1_1.valueOf(), 5e18);

    // Currently in pool 1, nothing is unlocked.
    const info0 = await this.staking.userLockInfo(user0, 1);
    assert.equal(info0.amount.valueOf(), 0);

    // Withrawing even 1 token will fail.
    await expectRevert(
        this.staking.withdraw(1, 1, { from: user0 }),
        'Please wait for unlock',
    );

    // Advance 1 day, and each of them deposit another 100 BLES to pool #1.
    await time.increase(time.duration.days(1));
    await this.staking.deposit(1, appendZeroes(1, 20), { from: user0 });
    await this.staking.deposit(1, appendZeroes(1, 20), { from: user1 });

    // Advance another 1 day, and each of them deposit another 100 BLES to pool #1.
    await time.increase(time.duration.days(1));
    await this.staking.deposit(1, appendZeroes(1, 20), { from: user0 });
    await this.staking.deposit(1, appendZeroes(1, 20), { from: user1 });

    // Advance 20 days, user1 withdraws early half of tokens on each of the 3 points.
    await time.increase(time.duration.days(20));
    // List unlock info array.
    const unlockInfoArray = await this.staking.getUnlockArray(user1, 1, 0, 100);
    assert.equal(unlockInfoArray.length, 3);
    assert.equal(unlockInfoArray[0].amount.valueOf(), 1e20);
    assert.equal(unlockInfoArray[1].amount.valueOf(), 1e20);
    assert.equal(unlockInfoArray[2].amount.valueOf(), 1e20);
    await this.staking.withdrawEarly(1, unlockInfoArray[0].pointer, appendZeroes(5, 19), { from: user1 });  // 22 / 40
    await this.staking.withdrawEarly(1, unlockInfoArray[1].pointer, appendZeroes(5, 19), { from: user1 });  // 21 / 40
    await this.staking.withdrawEarly(1, unlockInfoArray[2].pointer, appendZeroes(5, 19), { from: user1 });  // 20 / 40

    await expectRevert(
        this.staking.withdrawEarly(1, unlockInfoArray[0].pointer, appendZeroes(6, 19), { from: user1 }),
        '_amount too large',
    );

    const balance1_0 = await this.blesToken.balanceOf(user1);
    assert.equal(balance1_0.valueOf(), 6e20 + 275e17 + 2625e16 + 25e18);

    // Advance another 19 days, 2/3 of principal should be unlocked.
    await time.increase(time.duration.days(19));
    const unlockAmount0 = await this.staking.getUnlockAmount(user0, 1);
    assert.equal(unlockAmount0.valueOf(), 2e20);

    // User0, just withdraws 2/3. Now he has 800,
    // because 1000 - 100 * 4 + 100 * 2 = 800
    await this.staking.withdraw(1, appendZeroes(2, 20), { from: user0 });
    const balance0_0 = await this.blesToken.balanceOf(user0);
    assert.equal(balance0_0.valueOf(), 8e20);

    // User0 withdrawing more will fail.
    await expectRevert(
        this.staking.withdraw(1, 1, { from: user0 }),
        'Please wait for unlock',
    );

    // Advance 1 more day, now user0 can withdraw all.
    await time.increase(time.duration.days(1));
    await this.staking.withdraw(1, appendZeroes(1, 20), { from: user0 });
    const balance0_1 = await this.blesToken.balanceOf(user0);
    assert.equal(balance0_1.valueOf(), 9e20);
  });
});
