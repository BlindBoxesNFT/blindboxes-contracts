// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import "./interfaces/INFTHolder.sol";

import "./interfaces/IPOSDAORandom.sol";
import "./AMBMediator.sol";


// This contract is owned by Timelock.
contract NFTMaster is Ownable, AMBMediator {

    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    IPOSDAORandom private _posdaoRandomContract; // address of RandomAuRa contract
    uint256 private _seed;
    uint256 private _seedLastBlock;
    uint256 private _updateInterval;

    mapping (bytes32 => address) private msgTokenAddress;
    mapping (bytes32 => uint256) private msgTokenId;
    mapping (bytes32 => address) private msgRecipient;

    event nftDeposit(bytes32 _msgId, address _who, address _tokenAddress, uint256 _tokenId);
    event nftWithdraw(bytes32 _msgId, address _who, address _tokenAddress, uint256 _tokenId);
    event failedMessageFixed(bytes32 _msgId, address _recipient, address _tokenAddress, uint256 _tokenId);

    uint256 public nextNFTId;
    uint256 public nextCollectionId;

    struct NFT {
        address tokenAddress;
        uint256 tokenId;
        address owner;
        uint256 price;
        uint256 collectionId;
        uint256 indexInCollection;
    }

    // nftId => NFT
    mapping(uint256 => NFT) public allNFTs;

    // owner => nftId[]
    mapping(address => uint256[]) public nftsByOwner;

    // tokenAddress => tokenId => nftId
    mapping(address => mapping(uint256 => uint256)) nftMap;

    struct Collection {
        address owner;
        string name;
        uint256 size;
        bool willAcceptBLES;
        bool isFeatured;
        bool isPublished;
        address[] collaborators;
    }

    // collectionId => Collection
    mapping(uint256 => Collection) public allCollections;

    // owner => collectionId[]
    mapping(address => uint256[]) public collectionsByOwner;

    // collectionId => who => true/false
    mapping(uint256 => mapping(address => bool)) isCollaborator;

    // collectionId => nftId[]
    mapping(uint256 => uint256[]) public nftsByCollectionId;

    constructor(IPOSDAORandom _randomContract) public {
        require(_randomContract != IPOSDAORandom(0));
        _posdaoRandomContract = _randomContract;
        _seed = _randomContract.currentSeed();
        _seedLastBlock = block.number;
        _updateInterval = _randomContract.collectRoundLength();
        require(_updateInterval != 0);
    }

    function useSeed() public {
        if (_wasSeedUpdated()) {
            // using updated _seed ...
        } else {
            // using _seed ...
        }
    }

    function _wasSeedUpdated() private returns(bool) {
        if (block.number - _seedLastBlock <= _updateInterval) {
            return false;
        }

        _updateInterval = _posdaoRandomContract.collectRoundLength();

        uint256 remoteSeed = _posdaoRandomContract.currentSeed();
        if (remoteSeed != _seed) {
            _seed = remoteSeed;
            _seedLastBlock = block.number;
            return true;
        }
        return false;
    }

    function _generateNextNFTId() private returns(uint256) {
        return ++nextNFTId;
    }

    function _generateNextCollectionId() private returns(uint256) {
        return ++nextCollectionId;
    }

    function deposit(address from_, address tokenAddress_, uint256 tokenId_) external {
        require(msg.sender == address(bridgeContract()));
        require(bridgeContract().messageSender() == mediatorContractOnOtherSide());

        NFT memory nft;
        nft.tokenAddress = tokenAddress_;
        nft.tokenId = tokenId_;
        nft.owner = from_;
        nft.collectionId = 0;
        nft.indexInCollection = 0;

        uint256 nftId;

        if (nftMap[tokenAddress_][tokenId_] > 0) {
            nftId = nftMap[tokenAddress_][tokenId_];
        } else {
            nftId = _generateNextNFTId();
            nftMap[tokenAddress_][tokenId_] = nftId;
        }

        allNFTs[nftId] = nft;
        nftsByOwner[from_].push(nftId);

        bytes32 msgId = messageId();
        emit nftDeposit(msgId, from_, tokenAddress_, tokenId_);
    }

    function withdraw(uint256 nftId_) external returns(bytes32) {
        require(allNFTs[nftId_].owner == msg.sender && allNFTs[nftId_].collectionId == 0, "Not owned");
        allNFTs[nftId_].owner = address(0);

        address tokenAddress = allNFTs[nftId_].tokenAddress;
        uint256 tokenId = allNFTs[nftId_].tokenId;

        bytes4 methodSelector = INFTHolder(address(0)).withdraw.selector;
        bytes memory data = abi.encodeWithSelector(methodSelector, msg.sender, tokenAddress, tokenId);
        bytes32 msgId = bridgeContract().requireToPassMessage(
            mediatorContractOnOtherSide(),
            data,
            requestGasLimit
        );

        msgTokenAddress[msgId] = tokenAddress;
        msgTokenId[msgId] = tokenId;
        msgRecipient[msgId] = msg.sender;

        emit nftWithdraw(msgId, msg.sender, tokenAddress, tokenId);

        return msgId;
    }

    function fixFailedMessage(bytes32 _msgId) external {
        require(msg.sender == address(bridgeContract()));
        require(bridgeContract().messageSender() == mediatorContractOnOtherSide());
        require(!messageFixed[_msgId]);

        address recipient = msgRecipient[_msgId];
        address tokenAddress = msgTokenAddress[_msgId];
        uint256 tokenId = msgTokenId[_msgId];

        messageFixed[_msgId] = true;

        // Revert
        uint256 nftId = nftMap[tokenAddress][tokenId];
        allNFTs[nftId].owner = recipient;

        emit failedMessageFixed(_msgId, recipient, tokenAddress, tokenId);
    }

    function createCollection(
        string calldata name_,
        uint256 size_,
        bool willAcceptBLES_,
        address[] calldata collaborators_
    ) external {
        Collection memory collection;
        collection.owner = msg.sender;
        collection.name = name_;
        collection.size = size_;
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
        require(allNFTs[nftId_].owner == _msgSender(), "Only owner can add");
        require(allCollections[collectionId_].owner == _msgSender() ||
                isCollaborator[collectionId_][_msgSender()], "Needs owner or collaborator");
        require(allNFTs[nftId_].collectionId == 0, "Already added");
        require(!allCollections[collectionId_].isPublished, "Collection already published");
        require(nftsByCollectionId[collectionId_].length < allCollections[collectionId_].size,
                "collection full");

        allNFTs[nftId_].price = price_;
        allNFTs[nftId_].collectionId = collectionId_;
        allNFTs[nftId_].indexInCollection = nftsByCollectionId[collectionId_].length;

        // Push to nftsByCollectionId.
        nftsByCollectionId[collectionId_].push(nftId_);
    }

    function removeNFTFromCollection(uint256 nftId_, uint256 collectionId_) external {
        require(allNFTs[nftId_].owner == _msgSender() ||
                allCollections[collectionId_].owner == _msgSender(),
                "Only NFT owner or collection owner can remove");
        require(allNFTs[nftId_].collectionId == collectionId_, "NFT not in collection");
        require(!allCollections[collectionId_].isPublished, "Collection already published");

        allNFTs[nftId_].collectionId = 0;

        // Removes from nftsByCollectionId
        uint256 index = allNFTs[nftId_].indexInCollection;
        uint256 lastNFTId = nftsByCollectionId[collectionId_][nftsByCollectionId[collectionId_].length - 1];

        nftsByCollectionId[collectionId_][index] = lastNFTId;
        allNFTs[lastNFTId].indexInCollection = index;
        nftsByCollectionId[collectionId_].pop();
    }

    function publishCollection(uint256 collectionId_) public {
        require(allCollections[collectionId_].owner == _msgSender(), "Only owner can publish");

        allCollections[collectionId_].isPublished = true;
    }
}
