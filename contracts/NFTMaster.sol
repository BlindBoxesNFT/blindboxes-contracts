// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

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

    event nftDeposit(bytes32 _msgId, address _who, address _tokenAddress, uint256 _tokenId);
    event nftWithdraw(bytes32 _msgId, address _who, address _tokenAddress, uint256 _tokenId);
    event failedMessageFixed(bytes32 _msgId, address _recipient, address _tokenAddress, uint256 _tokenId);

    struct NFTOwner {
        address owner;
        uint256 index;
    }

    mapping(address => mapping(uint256 => NFTOwner)) public nftOwnerMap;

    struct NFTInfo {
        address tokenAddress;
        uint256 tokenId;
    }

    mapping(address => NFTInfo[]) public nftInfoMap;

    struct Collection {
        address owner;
        string name;
        uint256 size;
        address[] collaborators;
        bool willAcceptBLES;
        bool isFeatured;
    }

    Collection[] public allCollections;
    mapping(address => uint256[]) public collectionsByOwner;

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

    function deposit(address from_, address tokenAddress_, uint256 tokenId_) external {
        require(msg.sender == address(bridgeContract()));
        require(bridgeContract().messageSender() == mediatorContractOnOtherSide());

        NFTInfo memory info;
        info.tokenAddress = tokenAddress_;
        info.tokenId = tokenId_;
        nftInfoMap[from_].push(info);

        NFTOwner memory nftOwner;
        nftOwner.owner = from_;
        nftOwner.index = nftInfoMap[from_].length - 1;
        nftOwnerMap[tokenAddress_][tokenId_] = nftOwner;

        bytes32 msgId = messageId();
        emit nftDeposit(msgId, from_, tokenAddress_, tokenId_);
    }

    function withdraw(address to_, address tokenAddress_, uint256 tokenId_) public returns(bytes32) {
    }

    function fixFailedMessage(bytes32 _msgId) external {
    }

    function createCollection(
        string calldata name_,
        uint256 size_,
        bool willAcceptBLES_,
        address[] calldata collaborators_
    ) public {
        Collection memory collection;
        collection.owner = msg.sender;
        collection.name = name_;
        collection.size = size_;
        collection.willAcceptBLES = willAcceptBLES_;
        collection.isFeatured = false;
        collection.collaborators = collaborators_;

        allCollections.push(collection);
        collectionsByOwner[msg.sender].push(allCollections.length - 1);
    }

    function addNFTToCollection(uint256 collectionIndex, address tokenAddress_, uint256 tokenId_) public {
    }
}
