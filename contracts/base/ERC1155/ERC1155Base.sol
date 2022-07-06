// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import "./ERC1155.sol";

import "../../feature/ContractMetadata.sol";
import "../../feature/Multicall.sol";
import "../../feature/Ownable.sol";
import "../../feature/Royalty.sol";

contract ERC1155Base is 
    ERC1155,
    ContractMetadata,
    Multicall,
    Ownable,
    Royalty
{
    /*//////////////////////////////////////////////////////////////
                        State variables
    //////////////////////////////////////////////////////////////*/

    string public name;
    string public symbol;

    uint256 public nextTokenIdToMint;

    /*//////////////////////////////////////////////////////////////
                            Mappings
    //////////////////////////////////////////////////////////////*/

    mapping(uint256 => uint256) public totalSupply;

    /*//////////////////////////////////////////////////////////////
                            Constructor
    //////////////////////////////////////////////////////////////*/

    constructor(
        string memory _name, 
        string memory _symbol,
        string memory _contractURI,
        address _royaltyRecipient,
        uint128 _royaltyBps
    )
    {
        name = _name;
        symbol = _symbol;

        _setupContractURI(_contractURI);
        _setupOwner(msg.sender);
        _setupDefaultRoyaltyInfo(_royaltyRecipient, _royaltyBps);
    }

    /*//////////////////////////////////////////////////////////////
                            Minting logic
    //////////////////////////////////////////////////////////////*/

    function mint(address _to, uint256 _tokenId, string memory _tokenURI, uint256 _amount, bytes memory _data) public virtual {
        require(_canMint(), "Not authorized to mint.");

        uint256 _id;
        
        if (_tokenId == type(uint256).max) {
            _id = _nextTokenIdToMint();

            require(bytes(_tokenURI).length > 0, "empty uri.");
            _setTokenURI(_id, _tokenURI);

        } else {
            require(_tokenId < nextTokenIdToMint, "invalid id");
            _id = _tokenId;
        }

        _mint(_to, _id, _amount, _data);
        totalSupply[_id] += _amount;
    }

    /*//////////////////////////////////////////////////////////////
                        Internal (overrideable) functions
    //////////////////////////////////////////////////////////////*/

    function _nextTokenIdToMint() internal virtual returns (uint256) {
        uint256 id = nextTokenIdToMint;
        uint256 startId = _startTokenId();

        if(id < startId) {
            id = startId;
        }

        nextTokenIdToMint = id + 1;

        return id;
    }

    function _startTokenId() internal view virtual returns (uint256) {
        return 0;
    }

    function _setTokenURI(uint256 tokenId, string memory _tokenURI) internal virtual {
        _uri[tokenId] = _tokenURI;
    }

    /// @dev Returns whether contract metadata can be set in the given execution context.
    function _canSetContractURI() internal virtual view override returns (bool) {
        return msg.sender == owner();
    }

    /// @dev Returns whether a token can be minted in the given execution context.
    function _canMint() internal virtual view returns (bool) {
        return msg.sender == owner();
    }

    /// @dev Returns whether owner can be set in the given execution context.
    function _canSetOwner() internal virtual view override returns (bool) {
        return msg.sender == owner();
    }

    /// @dev Returns whether royalty info can be set in the given execution context.
    function _canSetRoyaltyInfo() internal virtual override view returns (bool) {
        return msg.sender == owner();
    }
}