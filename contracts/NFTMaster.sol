// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import "@chainlink/contracts/src/v0.6/VRFConsumerBase.sol";

import "./interfaces/IUniswapV2Router02.sol";

// This contract is owned by Timelock.
contract NFTMaster is Ownable, VRFConsumerBase {

    using SafeERC20 for IERC20;

    event nftDeposit(address _who, address _tokenAddress, uint256 _tokenId);
    event nftWithdraw(address _who, address _tokenAddress, uint256 _tokenId);

    IERC20 wETH;
    IERC20 baseToken;
    IERC20 blesToken;
    IERC20 linkToken;

    bytes32 public linkKeyHash;
    uint256 public linkCost = 1e17;  // 0.1 LINK

    // Platform fee.
    uint256 constant FEE_BASE = 10000;
    uint256 public feeRate = 500;  // 5%

    address public feeTo;

    IUniswapV2Router02 public router;

    uint256 public nextNFTId;
    uint256 public nextCollectionId;

    struct NFT {
        address tokenAddress;
        uint256 tokenId;
        address owner;
        uint256 price;
        uint256 paid;
        uint256 collectionId;
        uint256 indexInCollection;
    }

    // nftId => NFT
    mapping(uint256 => NFT) public allNFTs;

    // owner => nftId[]
    mapping(address => uint256[]) public nftsByOwner;

    // tokenAddress => tokenId => nftId
    mapping(address => mapping(uint256 => uint256)) nftIdMap;

    struct Collection {
        address owner;
        string name;
        uint256 size;
        uint256 totalPrice;
        uint256 averagePrice;
        uint256 fee;
        bool willAcceptBLES;
        bool isFeatured;
        bool isPublished;
        address[] collaborators;

        // The following are runtime variables
        uint256 timesToCall;
        uint256 slotPointerI;
        uint256 slotPointerJ;
        uint256 soldCount;
    }

    // collectionId => Collection
    mapping(uint256 => Collection) public allCollections;

    // owner => collectionId[]
    mapping(address => uint256[]) public collectionsByOwner;

    // collectionId => who => true/false
    mapping(uint256 => mapping(address => bool)) isCollaborator;

    // collectionId => nftId[]
    mapping(uint256 => uint256[]) public nftsByCollectionId;

    mapping(bytes32 => uint256) public requestIdToCollectionId;

    struct Slot {
        address owner;
        uint256 size;
    }

    // collectionId => Slot[]
    mapping(uint256 => Slot[]) public slotMap;
    // collectionId => index => address
    mapping(uint256 => mapping(uint256 => address)) public slotOwner;

    uint256 public nftPriceFloor = 1e18;  // 1 USDC
    uint256 public nftPriceCeil = 1e24;  // 1M USDC
    uint256 public collectionMinimumSize = 10;  // 10 blind boxes

    constructor(
        IERC20 wETH_,
        address vrfCoordinator_,
        IERC20 link_
    ) VRFConsumerBase(vrfCoordinator_, address(link_)) public {
        wETH = wETH_;
        linkToken = link_;
    }

    function setBaseToken(IERC20 baseToken_) external onlyOwner {
        baseToken = baseToken_;
    }

    function setBlesToken(IERC20 blesToken_) external onlyOwner {
        blesToken = blesToken_;
    }

    function setLinkKeyHash(bytes32 linkKeyHash_) external onlyOwner {
        linkKeyHash = linkKeyHash_;
    }

    function setLinkCost(uint256 linkCost_) external onlyOwner {
        linkCost = linkCost_;
    }

    function setFeeRate(uint256 feeRate_) external onlyOwner {
        feeRate = feeRate_;
    }

    function setFeeTo(address feeTo_) external onlyOwner {
        feeTo = feeTo_;
    }

    function setUniswapV2Router(IUniswapV2Router02 router_) external {
        router = router_;
    }

    function setNFTPriceFloor(uint256 value_) external onlyOwner {
        require(value_ < nftPriceCeil, "should be higher than floor");
        nftPriceFloor = value_;
    }

    function setNFTPriceCeil(uint256 value_) external onlyOwner {
        require(value_ > nftPriceFloor, "should be higher than floor");
        nftPriceCeil = value_;
    }

    function setCollectionMinimumSize(uint256 size_) external onlyOwner {
        collectionMinimumSize = size_;
    }

    function _generateNextNFTId() private returns(uint256) {
        return ++nextNFTId;
    }

    function _generateNextCollectionId() private returns(uint256) {
        return ++nextCollectionId;
    }

    function depositNFT(address tokenAddress_, uint256 tokenId_) external {
        IERC721(tokenAddress_).safeTransferFrom(_msgSender(), address(this), tokenId_);

        NFT memory nft;
        nft.tokenAddress = tokenAddress_;
        nft.tokenId = tokenId_;
        nft.owner = _msgSender();
        nft.collectionId = 0;
        nft.indexInCollection = 0;

        uint256 nftId;

        if (nftIdMap[tokenAddress_][tokenId_] > 0) {
            nftId = nftIdMap[tokenAddress_][tokenId_];
        } else {
            nftId = _generateNextNFTId();
            nftIdMap[tokenAddress_][tokenId_] = nftId;
        }

        allNFTs[nftId] = nft;
        nftsByOwner[_msgSender()].push(nftId);

        emit nftDeposit(_msgSender(), tokenAddress_, tokenId_);
    }

    function _withdraw(uint256 nftId_) private {
        allNFTs[nftId_].owner = address(0);
        allNFTs[nftId_].collectionId = 0;

        address tokenAddress = allNFTs[nftId_].tokenAddress;
        uint256 tokenId = allNFTs[nftId_].tokenId;

        IERC721(tokenAddress).safeTransferFrom(address(this), _msgSender(), tokenId);

        emit nftWithdraw(_msgSender(), tokenAddress, tokenId);
    }

    function withdrawNFT(uint256 nftId_) external {
        require(allNFTs[nftId_].owner == msg.sender && allNFTs[nftId_].collectionId == 0, "Not owned");
        _withdraw(nftId_);
    }

    function claimNFT(uint256 collectionId_, uint256 index_) external {
        require(allCollections[collectionId_].soldCount ==
                allCollections[collectionId_].size, "Not finished");
        require(slotOwner[collectionId_][index_] == _msgSender(), "Only winner can claim");

        uint256 nftId = nftsByCollectionId[collectionId_][index_];

        require(allNFTs[nftId].collectionId == collectionId_, "Already claimed");

        if (allNFTs[nftId].paid == 0) {
            if (allCollections[collectionId_].willAcceptBLES) {
                allNFTs[nftId].paid = allNFTs[nftId].price;
                IERC20(blesToken).safeTransfer(allNFTs[nftId].owner, allNFTs[nftId].paid);
            } else {
                allNFTs[nftId].paid = allNFTs[nftId].price.mul(FEE_BASE.sub(feeRate)).div(FEE_BASE);
                IERC20(baseToken).safeTransfer(allNFTs[nftId].owner, allNFTs[nftId].paid);
            }
        }

        _withdraw(nftId);
    }

    function claimRevenue(uint256 collectionId_, uint256 index_) external {
        require(allCollections[collectionId_].soldCount ==
                allCollections[collectionId_].size, "Not finished");

        uint256 nftId = nftsByCollectionId[collectionId_][index_];

        require(allNFTs[nftId].owner == _msgSender() && allNFTs[nftId].collectionId > 0, "NFT not claimed");

        if (allNFTs[nftId].paid == 0) {
            if (allCollections[collectionId_].willAcceptBLES) {
                allNFTs[nftId].paid = allNFTs[nftId].price;
                IERC20(blesToken).safeTransfer(allNFTs[nftId].owner, allNFTs[nftId].paid);
            } else {
                allNFTs[nftId].paid = allNFTs[nftId].price.mul(FEE_BASE.sub(feeRate)).div(FEE_BASE);
                IERC20(baseToken).safeTransfer(allNFTs[nftId].owner, allNFTs[nftId].paid);
            }
        }
    }

    function claimFee(uint256 collectionId_) external {
        Collection storage collection = allCollections[collectionId_];

        require(collection.soldCount ==
                collection.size, "Not finished");
        require(collection.willAcceptBLES, "No fee if you accept BLES");

        if (feeTo != address(0)) {
            IERC20(baseToken).safeTransfer(feeTo, collection.fee);
        }
    }

    function createCollection(
        string calldata name_,
        uint256 size_,
        bool willAcceptBLES_,
        address[] calldata collaborators_
    ) external {
        require(size_ >= collectionMinimumSize, "Size too small");

        Collection memory collection;
        collection.owner = msg.sender;
        collection.name = name_;
        collection.size = size_;
        collection.totalPrice = 0;
        collection.averagePrice = 0;
        collection.willAcceptBLES = willAcceptBLES_;
        collection.isFeatured = false;
        collection.isPublished = false;
        collection.collaborators = collaborators_;

        uint256 collectionId = _generateNextCollectionId();

        allCollections[collectionId] = collection;
        collectionsByOwner[msg.sender].push(collectionId);

        for (uint256 i = 0; i < collaborators_.length; ++i) {
            isCollaborator[collectionId][collaborators_[i]] = true;
        }
    }

    function addNFTToCollection(uint256 nftId_, uint256 collectionId_, uint256 price_) external {
        require(allNFTs[nftId_].owner == _msgSender(), "Only NFT owner can add");
        require(allCollections[collectionId_].owner == _msgSender() ||
                isCollaborator[collectionId_][_msgSender()], "Needs collection owner or collaborator");

        require(price_ >= nftPriceFloor && price_ <= nftPriceCeil, "Price not in range");

        require(allNFTs[nftId_].collectionId == 0, "Already added");
        require(!allCollections[collectionId_].isPublished, "Collection already published");
        require(nftsByCollectionId[collectionId_].length < allCollections[collectionId_].size,
                "collection full");

        allNFTs[nftId_].price = price_;
        allNFTs[nftId_].collectionId = collectionId_;
        allNFTs[nftId_].indexInCollection = nftsByCollectionId[collectionId_].length;

        // Push to nftsByCollectionId.
        nftsByCollectionId[collectionId_].push(nftId_);

        allCollections[collectionId_].totalPrice = allCollections[collectionId_].totalPrice.add(price_);

        if (allCollections[collectionId_].willAcceptBLES) {
            allCollections[collectionId_].fee = allCollections[collectionId_].fee.add(price_.mul(feeRate).div(FEE_BASE));
        }
    }

    function editNFTInCollection(uint256 nftId_, uint256 collectionId_, uint256 price_) external {
        require(allCollections[collectionId_].owner == _msgSender() ||
                allNFTs[nftId_].owner == _msgSender(), "Needs collection owner or NFT owner");

        require(price_ >= nftPriceFloor && price_ <= nftPriceCeil, "Price not in range");

        require(allNFTs[nftId_].collectionId == collectionId_, "NFT not in collection");
        require(!allCollections[collectionId_].isPublished, "Collection already published");

        allCollections[collectionId_].totalPrice = allCollections[collectionId_].totalPrice.add(
            price_).sub(allNFTs[nftId_].price);

        if (allCollections[collectionId_].willAcceptBLES) {
            allCollections[collectionId_].fee = allCollections[collectionId_].fee.add(
                price_.mul(feeRate).div(FEE_BASE)).sub(
                    allNFTs[nftId_].price.mul(feeRate).div(FEE_BASE));
        }

        allNFTs[nftId_].price = price_;  // Change price.
    }

    function removeNFTFromCollection(uint256 nftId_, uint256 collectionId_) external {
        require(allNFTs[nftId_].owner == _msgSender() ||
                allCollections[collectionId_].owner == _msgSender(),
                "Only NFT owner or collection owner can remove");
        require(allNFTs[nftId_].collectionId == collectionId_, "NFT not in collection");
        require(!allCollections[collectionId_].isPublished, "Collection already published");

        allCollections[collectionId_].totalPrice = allCollections[collectionId_].totalPrice.sub(allNFTs[nftId_].price);

        if (allCollections[collectionId_].willAcceptBLES) {
            allCollections[collectionId_].fee = allCollections[collectionId_].fee.sub(
                    allNFTs[nftId_].price.mul(feeRate).div(FEE_BASE));
        }

        allNFTs[nftId_].collectionId = 0;

        // Removes from nftsByCollectionId
        uint256 index = allNFTs[nftId_].indexInCollection;
        uint256 lastNFTId = nftsByCollectionId[collectionId_][nftsByCollectionId[collectionId_].length - 1];

        nftsByCollectionId[collectionId_][index] = lastNFTId;
        allNFTs[lastNFTId].indexInCollection = index;
        nftsByCollectionId[collectionId_].pop();
    }

    function randomnessCount(uint256 size_) public pure returns(uint256){
        uint256 i;
        for (i = 0; size_** i <= type(uint256).max / size_; i++) {}
        return i;
    }

    function publishCollection(uint256 collectionId_, uint256 amountInMax_, uint256 deadline_) public {
        require(allCollections[collectionId_].owner == _msgSender(), "Only owner can publish");

        uint256 actualSize = nftsByCollectionId[collectionId_].length;
        require(actualSize >= collectionMinimumSize, "Not enough boxes");

        allCollections[collectionId_].size = actualSize;  // Fit the size.

        // Math.ceil(totalPrice / actualSize);
        allCollections[collectionId_].averagePrice = allCollections[collectionId_].totalPrice.add(actualSize.sub(1)).div(actualSize);
        allCollections[collectionId_].isPublished = true;

        // Now buy LINK. Here is some math for calculating the time of calls needed from ChainLink.
        uint256 count = randomnessCount(actualSize);
        uint256 times = (actualSize + count - 1) / count;
        _buyLink(times, amountInMax_, deadline_);

        allCollections[collectionId_].timesToCall = times;
    }

    function _buyLink(uint256 times_, uint256 amountInMax_, uint256 deadline_) private {
        uint256 amountToBuy = linkCost.mul(times_);

        address[] memory path = new address[](3);
        path[0] = address(baseToken);
        path[1] = address(wETH);
        path[2] = address(linkToken);

        router.swapTokensForExactTokens(
            amountToBuy,
            amountInMax_,
            path,
            address(this),
            deadline_);
    }

    function drawBoxes(uint256 collectionId_, uint256 times_) external {
        require(allCollections[collectionId_].soldCount.add(times_) <= allCollections[collectionId_].size, "Not enough left");

        uint256 cost = allCollections[collectionId_].averagePrice.mul(times_);

        if (allCollections[collectionId_].willAcceptBLES) {
            IERC20(blesToken).safeTransferFrom(_msgSender(), address(this), cost);
        } else {
            IERC20(baseToken).safeTransferFrom(_msgSender(), address(this), cost);
        }

        Slot memory slot;
        slot.owner = _msgSender();
        slot.size = times_;
        slotMap[collectionId_].push(slot);

        allCollections[collectionId_].soldCount = allCollections[collectionId_].soldCount.add(times_);

        for (uint256 i = allCollections[collectionId_].size - allCollections[collectionId_].timesToCall;
                 i < allCollections[collectionId_].soldCount;
                 ++i) {
            _getRandomNumber(collectionId_, i);
        }
    }

    function _takeIndex(address who_, uint256 collectionId_, uint256 index_) private {
        uint256 size = allCollections[collectionId_].size;

        for (uint256 i = index_; i < size; ++i) {
            if (slotOwner[collectionId_][i] == address(0)) {
                slotOwner[collectionId_][i] = who_;
                return;
            }
        }

        require(slotOwner[collectionId_][0] == address(0), "0 should be the only left index");
        slotOwner[collectionId_][0] = who_;
    }

    function _getRandomNumber(uint256 collectionId_, uint256 userProvidedSeed) private {
        require(linkToken.balanceOf(address(this)) > linkCost, "Not enough LINK");
        bytes32 requestId = requestRandomness(linkKeyHash, linkCost, userProvidedSeed);
        requestIdToCollectionId[requestId] = collectionId_;
    }

    /**
     * Callback function used by VRF Coordinator
     */
    function fulfillRandomness(bytes32 requestId, uint256 randomness) internal override {
        uint256 collectionId = requestIdToCollectionId[requestId];

        uint256 size = allCollections[collectionId].size;
        uint256 count = randomnessCount(size);
        require(count > 0, "Randomness count > 0");

        for (; allCollections[collectionId].slotPointerI < slotMap[collectionId].length;
                ++allCollections[collectionId].slotPointerI) {
            for (; allCollections[collectionId].slotPointerJ < 
                    slotMap[collectionId][allCollections[collectionId].slotPointerI].size;
                    ++allCollections[collectionId].slotPointerJ) {
                uint256 result = randomness / size;
                randomness = randomness % size;

                _takeIndex(slotMap[collectionId][allCollections[collectionId].slotPointerI].owner, collectionId, result);

                count--;
                if (count == 0) break;
            }

            if (allCollections[collectionId].slotPointerJ >= slotMap[collectionId][allCollections[collectionId].slotPointerI].size) {
                allCollections[collectionId].slotPointerJ = 0;
            }

            if (count == 0) break;
        }
    }
}
