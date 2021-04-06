// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import "./interfaces/ILinkAccessor.sol";
import "./interfaces/IUniswapV2Router02.sol";

// This contract is owned by Timelock.
contract NFTMaster is Ownable, IERC721Receiver {

    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    event CreateCollection(address _who, uint256 _collectionId);
    event PublishCollection(address _who, uint256 _collectionId);
    event UnpublishCollection(address _who, uint256 _collectionId);
    event NFTDeposit(address _who, address _tokenAddress, uint256 _tokenId);
    event NFTWithdraw(address _who, address _tokenAddress, uint256 _tokenId);
    event NFTClaim(address _who, address _tokenAddress, uint256 _tokenId);

    IERC20 public wETH;
    IERC20 public baseToken;
    IERC20 public blesToken;
    IERC20 public linkToken;

    uint256 public linkCost = 1e17;  // 0.1 LINK
    ILinkAccessor public linkAccessor;

    // Platform fee.
    uint256 constant FEE_BASE = 10000;
    uint256 public feeRate = 500;  // 5%

    address public feeTo;

    // Collection creating fee.
    uint256 creatingFee = 0;  // By default, 0

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
        bool willAcceptBLES;
        uint256 publishedAt;  // time that published.
        address[] collaborators;

        // The following are runtime variables
        uint256 timesToCall;
        uint256 soldCount;
        uint256 fee;
    }

    // collectionId => Collection
    mapping(uint256 => Collection) public allCollections;

    // owner => collectionId[]
    mapping(address => uint256[]) public collectionsByOwner;

    // collectionId => who => true/false
    mapping(uint256 => mapping(address => bool)) isCollaborator;

    // collectionId => nftId[]
    mapping(uint256 => uint256[]) public nftsByCollectionId;

    struct RequestInfo {
        uint256 collectionId;
        uint256 index;
    }

    mapping(bytes32 => RequestInfo) public requestInfoMap;

    struct Slot {
        address owner;
        uint256 size;
    }

    // collectionId => Slot[]
    mapping(uint256 => Slot[]) public slotMap;

    // collectionId => randomnessIndex => r
    mapping(uint256 => mapping(uint256 => uint256)) public nftMapping;

    uint256 public nftPriceFloor = 1e18;  // 1 USDC
    uint256 public nftPriceCeil = 1e24;  // 1M USDC
    uint256 public minimumCollectionSize = 3;  // 3 blind boxes
    uint256 public maximumDuration = 14 days;  // Refund if not sold out in 14 days.

    constructor() public { }

    function onERC721Received(address, address, uint256, bytes memory) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function setWETH(IERC20 wETH_) external onlyOwner {
        wETH = wETH_;
    }

    function setLinkToken(IERC20 linkToken_) external onlyOwner {
        linkToken = linkToken_;
    }

    function setBaseToken(IERC20 baseToken_) external onlyOwner {
        baseToken = baseToken_;
    }

    function setBlesToken(IERC20 blesToken_) external onlyOwner {
        blesToken = blesToken_;
    }

    function setLinkAccessor(ILinkAccessor linkAccessor_) external onlyOwner {
        linkAccessor = linkAccessor_;
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

    function setCreatingFee(uint256 creatingFee_) external onlyOwner {
        creatingFee = creatingFee_;
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

    function setMinimumCollectionSize(uint256 size_) external onlyOwner {
        minimumCollectionSize = size_;
    }

    function setMaximumDuration(uint256 maximumDuration_) external onlyOwner {
        maximumDuration = maximumDuration_;
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

        emit NFTDeposit(_msgSender(), tokenAddress_, tokenId_);
    }

    function _withdrawNFT(uint256 nftId_, bool isClaim_) private {
        allNFTs[nftId_].owner = address(0);
        allNFTs[nftId_].collectionId = 0;

        address tokenAddress = allNFTs[nftId_].tokenAddress;
        uint256 tokenId = allNFTs[nftId_].tokenId;

        IERC721(tokenAddress).safeTransferFrom(address(this), _msgSender(), tokenId);

        if (isClaim_) {
            emit NFTClaim(_msgSender(), tokenAddress, tokenId);
        } else {
            emit NFTWithdraw(_msgSender(), tokenAddress, tokenId);
        }
    }

    function withdrawNFT(uint256 nftId_) external {
        require(allNFTs[nftId_].owner == msg.sender && allNFTs[nftId_].collectionId == 0, "Not owned");
        _withdrawNFT(nftId_, false);
    }

    function claimNFT(uint256 collectionId_, uint256 index_) external {
        require(allCollections[collectionId_].soldCount ==
                allCollections[collectionId_].size, "Not finished");

        address winner = getWinner(collectionId_, index_);

        require(winner == _msgSender(), "Only winner can claim");

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

        _withdrawNFT(nftId, true);
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
        require(!collection.willAcceptBLES, "No fee if you accept BLES");

        if (feeTo != address(0)) {
            IERC20(baseToken).safeTransfer(feeTo, collection.fee);
        }

        // Mark it claimed.
        collection.fee = 0;
    }

    function createCollection(
        string calldata name_,
        uint256 size_,
        bool willAcceptBLES_,
        address[] calldata collaborators_
    ) external {
        require(size_ >= minimumCollectionSize, "Size too small");

        if (creatingFee > 0) {
            // Charges BLES for creating the collection.
            IERC20(blesToken).safeTransfer(feeTo, creatingFee);
        }

        Collection memory collection;
        collection.owner = msg.sender;
        collection.name = name_;
        collection.size = size_;
        collection.totalPrice = 0;
        collection.averagePrice = 0;
        collection.willAcceptBLES = willAcceptBLES_;
        collection.publishedAt = 0;
        collection.collaborators = collaborators_;

        uint256 collectionId = _generateNextCollectionId();

        allCollections[collectionId] = collection;
        collectionsByOwner[msg.sender].push(collectionId);

        for (uint256 i = 0; i < collaborators_.length; ++i) {
            isCollaborator[collectionId][collaborators_[i]] = true;
        }

        emit CreateCollection(msg.sender, collectionId);
    }

    function isPublished(uint256 collectionId_) public view returns(bool) {
        return allCollections[collectionId_].publishedAt > 0;
    }

    function addNFTToCollection(uint256 nftId_, uint256 collectionId_, uint256 price_) external {
        require(allNFTs[nftId_].owner == _msgSender(), "Only NFT owner can add");
        require(allCollections[collectionId_].owner == _msgSender() ||
                isCollaborator[collectionId_][_msgSender()], "Needs collection owner or collaborator");

        require(price_ >= nftPriceFloor && price_ <= nftPriceCeil, "Price not in range");

        require(allNFTs[nftId_].collectionId == 0, "Already added");
        require(!isPublished(collectionId_), "Collection already published");
        require(nftsByCollectionId[collectionId_].length < allCollections[collectionId_].size,
                "collection full");

        allNFTs[nftId_].price = price_;
        allNFTs[nftId_].collectionId = collectionId_;
        allNFTs[nftId_].indexInCollection = nftsByCollectionId[collectionId_].length;

        // Push to nftsByCollectionId.
        nftsByCollectionId[collectionId_].push(nftId_);

        allCollections[collectionId_].totalPrice = allCollections[collectionId_].totalPrice.add(price_);

        if (!allCollections[collectionId_].willAcceptBLES) {
            allCollections[collectionId_].fee = allCollections[collectionId_].fee.add(price_.mul(feeRate).div(FEE_BASE));
        }
    }

    function editNFTInCollection(uint256 nftId_, uint256 collectionId_, uint256 price_) external {
        require(allCollections[collectionId_].owner == _msgSender() ||
                allNFTs[nftId_].owner == _msgSender(), "Needs collection owner or NFT owner");

        require(price_ >= nftPriceFloor && price_ <= nftPriceCeil, "Price not in range");

        require(allNFTs[nftId_].collectionId == collectionId_, "NFT not in collection");
        require(!isPublished(collectionId_), "Collection already published");

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
        require(!isPublished(collectionId_), "Collection already published");

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

    function publishCollection(uint256 collectionId_, address[] calldata path, uint256 amountInMax_, uint256 deadline_) external {
        require(allCollections[collectionId_].owner == _msgSender(), "Only owner can publish");

        uint256 actualSize = nftsByCollectionId[collectionId_].length;
        require(actualSize >= minimumCollectionSize, "Not enough boxes");

        allCollections[collectionId_].size = actualSize;  // Fit the size.

        // Math.ceil(totalPrice / actualSize);
        allCollections[collectionId_].averagePrice = allCollections[collectionId_].totalPrice.add(actualSize.sub(1)).div(actualSize);
        allCollections[collectionId_].publishedAt = now;

        // Now buy LINK. Here is some math for calculating the time of calls needed from ChainLink.
        uint256 count = randomnessCount(actualSize);
        uint256 times = (actualSize + count - 1) / count;  // Math.ceil
        buyLink(times, path, amountInMax_, deadline_);

        allCollections[collectionId_].timesToCall = times;

        emit PublishCollection(msg.sender, collectionId_);
    }

    function unpublishCollection(uint256 collectionId_) external {
        // Anyone can call.

        Collection storage collection = allCollections[collectionId_];

        // Only if the boxes not sold out in maximumDuration, can we unpublish.
        require(now > collection.publishedAt + maximumDuration, "Not expired yet");
        require(collection.soldCount < collection.size, "Sold out");

        collection.publishedAt = 0;
        collection.soldCount = 0;
        collection.fee = 0;

        // Now refund to the buyers.
        uint256 length = slotMap[collectionId_].length;
        for (uint256 i = 0; i < length; ++i) {
            Slot memory slot = slotMap[collectionId_][length.sub(i + 1)];
            slotMap[collectionId_].pop();

            if (collection.willAcceptBLES) {
                IERC20(blesToken).transfer(slot.owner, collection.averagePrice.mul(slot.size));
            } else {
                IERC20(baseToken).transfer(slot.owner, collection.averagePrice.mul(slot.size));
            }
        }

        emit UnpublishCollection(msg.sender, collectionId_);
    }

    function buyLink(uint256 times_, address[] calldata path, uint256 amountInMax_, uint256 deadline_) internal virtual {
        require(path[path.length.sub(1)] == address(linkToken), "Last token must be LINK");

        uint256 amountToBuy = linkCost.mul(times_);

        if (path.length == 1) {
            // Pay with LINK.
            linkToken.transferFrom(msg.sender, address(this), amountToBuy);
        } else {
            // Pay with other token.
            router.swapTokensForExactTokens(
                amountToBuy,
                amountInMax_,
                path,
                address(linkAccessor),
                deadline_);
        }
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

        uint256 startFromIndex = allCollections[collectionId_].size - allCollections[collectionId_].timesToCall;
        for (uint256 i = startFromIndex;
                 i < allCollections[collectionId_].soldCount;
                 ++i) {
            getRandomNumber(collectionId_, i.sub(startFromIndex));
        }
    }

    function getWinner(uint256 collectionId_, uint256 nftIndex_) public view returns(address) {
        if (allCollections[collectionId_].soldCount <
                allCollections[collectionId_].size) {
            // Not sold all yet.
            return address(0);
        }

        uint256 size = allCollections[collectionId_].size;
        uint256 count = randomnessCount(size);

        uint256 lastRandomnessIndex = size.sub(1).div(count);
        uint256 lastR = nftMapping[collectionId_][lastRandomnessIndex];

        // Use lastR as an offset for rotating the sequence, to make sure that
        // we need to wait for all boxes being sold.
        nftIndex_ = nftIndex_.add(lastR).mod(size);

        uint256 randomnessIndex = nftIndex_.div(count);
        randomnessIndex = randomnessIndex.add(lastR).mod(lastRandomnessIndex + 1);

        uint256 r = nftMapping[collectionId_][randomnessIndex];

        uint256 i;

        for (i = 0; i < nftIndex_.mod(count); ++i) {
          r /= size;
        }

        r %= size;

        // Iterate through all slots.
        for (i = 0; i < slotMap[collectionId_].length; ++i) {
            if (r >= slotMap[collectionId_][i].size) {
                r -= slotMap[collectionId_][i].size;
            } else {
                return slotMap[collectionId_][i].owner;
            }
        }

        require(false, "r overflow");
    }

    function getRandomNumber(uint256 collectionId_, uint256 index_) private {
        bytes32 requestId = linkAccessor.requestRandomness(index_);
        requestInfoMap[requestId].collectionId = collectionId_;
        requestInfoMap[requestId].index = index_;
    }

    /**
     * Callback function used by VRF Coordinator
     */
    function fulfillRandomness(bytes32 requestId, uint256 randomness) public {
        require(_msgSender() == address(linkAccessor), "Only linkAccessor can call");

        uint256 collectionId = requestInfoMap[requestId].collectionId;
        uint256 randomnessIndex = requestInfoMap[requestId].index;

        uint256 size = allCollections[collectionId].size;
        bool[] memory filled = new bool[](size);

        uint256 r;
        uint256 i;
        uint256 count;

        for (i = 0; i < randomnessIndex; ++i) {
            r = nftMapping[collectionId][i];
            while (r > 0) {
                filled[r.mod(size)] = true;
                r = r.div(size);
                count = count.add(1);
            }
        }

        r = 0;

        uint256 t;

        while (randomness > 0 && count < size) {
            t = randomness.mod(size);
            randomness = randomness.div(size);

            t = t.mod(size.sub(count)).add(1);

            // Skips filled mappings.
            for (i = 0; i < size; ++i) {
                if (!filled[i]) {
                    t = t.sub(1);
                }

                if (t == 0) {
                  break;
                }
            }

            filled[i] = true;
            r = r.mul(size).add(i);
            count = count.add(1);
        }

        nftMapping[collectionId][randomnessIndex] = r;
    }
}
