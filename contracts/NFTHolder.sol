// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import "./interfaces/INFTMaster.sol";

import "./AMBMediator.sol";


// This contract is owned by Timelock.
contract NFTHolder is Ownable, AMBMediator {

    mapping (bytes32 => address) private msgTokenAddress;
    mapping (bytes32 => uint256) private msgTokenId;
    mapping (bytes32 => address) private msgRecipient;

    event nftDeposit(bytes32 _msgId, address _who, address _tokenAddress, uint256 _tokenId);
    event nftWithdraw(bytes32 _msgId, address _who, address _tokenAddress, uint256 _tokenId);
    event failedMessageFixed(bytes32 _msgId, address _recipient, address _tokenAddress, uint256 _tokenId);

    function deposit(address tokenAddress_, uint256 tokenId_) public returns(bytes32) {
        IERC721(tokenAddress_).safeTransferFrom(msg.sender, address(this), tokenId_);

        bytes4 methodSelector = INFTMaster(address(0)).deposit.selector;
        bytes memory data = abi.encodeWithSelector(methodSelector, msg.sender, tokenAddress_, tokenId_);
        bytes32 msgId = bridgeContract().requireToPassMessage(
            mediatorContractOnOtherSide(),
            data,
            requestGasLimit
        );

        msgTokenAddress[msgId] = tokenAddress_;
        msgTokenId[msgId] = tokenId_;
        msgRecipient[msgId] = msg.sender;

        emit nftDeposit(msgId, msg.sender, tokenAddress_, tokenId_);

        return msgId;
    }

    function withdraw(address to_, address tokenAddress_, uint256 tokenId_) public {
        require(msg.sender == address(bridgeContract()));
        require(bridgeContract().messageSender() == mediatorContractOnOtherSide());

        IERC721(tokenAddress_).safeTransferFrom(address(this), to_, tokenId_);

        bytes32 msgId = messageId();
        emit nftWithdraw(msgId, to_, tokenAddress_, tokenId_);
    }

    function fixFailedMessage(bytes32 _msgId) external {
        require(msg.sender == address(bridgeContract()));
        require(bridgeContract().messageSender() == mediatorContractOnOtherSide());
        require(!messageFixed[_msgId]);

        address recipient = msgRecipient[_msgId];
        address tokenAddress = msgTokenAddress[_msgId];
        uint256 tokenId = msgTokenId[_msgId];

        messageFixed[_msgId] = true;
        IERC721(tokenAddress).safeTransferFrom(address(this), recipient, tokenId);

        emit failedMessageFixed(_msgId, recipient, tokenAddress, tokenId);
    }
}
