// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

//  ==========  External imports    ==========

import "@openzeppelin/contracts/interfaces/IERC2981.sol";

//  ==========  Internal imports    ==========

import "../../openzeppelin-presets/metatx/ERC2771Context.sol";
import "../../lib/CurrencyTransferLib.sol";
import "../../lib/TWStrings.sol";

import "./ERC1155.sol";

//  ==========  Features    ==========

import "../../feature/ContractMetadata.sol";
import "../../feature/PlatformFee.sol";
import "../../feature/Royalty.sol";
import "../../feature/PrimarySale.sol";
import "../../feature/Ownable.sol";
import "../../feature/DelayedReveal.sol";
import "../../feature/LazyMint.sol";
import "../../feature/PermissionsEnumerable.sol";
import "../../feature/Drop.sol";
import "../../feature/Multicall.sol";

contract ERC1155Drop is
    ERC1155,
    ContractMetadata,
    Royalty,
    PrimarySale,
    Ownable,
    DelayedReveal,
    LazyMint,
    PermissionsEnumerable,
    Drop,
    Multicall
{
    using TWStrings for uint256;

    /*///////////////////////////////////////////////////////////////
                            State variables
    //////////////////////////////////////////////////////////////*/

    /// @dev Only transfers to or from TRANSFER_ROLE holders are valid, when transfers are restricted.
    bytes32 private constant TRANSFER_ROLE = keccak256("TRANSFER_ROLE");
    /// @dev Only MINTER_ROLE holders can sign off on `MintRequest`s and lazy mint tokens.
    bytes32 private constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @dev Max bps in the thirdweb system.
    uint256 private constant MAX_BPS = 10_000;

    string public name;
    string public symbol;

    /// @dev The tokenId of the next NFT that will be minted / lazy minted.
    uint256 public nextTokenIdToMint;

    /*///////////////////////////////////////////////////////////////
                                Mappings
    //////////////////////////////////////////////////////////////*/

    /// @dev Mapping from token ID => total circulating supply of tokens with that ID.
    mapping(uint256 => uint256) public totalSupply;

    /// @dev Mapping from token ID => maximum possible total circulating supply of tokens with that ID.
    mapping(uint256 => uint256) public maxTotalSupply;

    /*///////////////////////////////////////////////////////////////
                                Events
    //////////////////////////////////////////////////////////////*/

    event TokensLazyMinted(uint256 indexed startTokenId, uint256 endTokenId, string baseURI, bytes encryptedBaseURI);
    event TokenURIRevealed(uint256 indexed index, string revealedURI);

    /*///////////////////////////////////////////////////////////////
                            Custom Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when minting the given quantity will exceed available quantity.
    error NFTDrop__NotEnoughMintedTokens(uint256 currentIndex, uint256 quantity);

    /// @notice Emitted when given quantity to mint is zero.
    error NFTDrop__MintingZeroTokens();

    /// @notice Emitted when given amount for lazy-minting is zero.
    error NFTDrop__ZeroAmount();

    /// @notice Emitted when sent value doesn't match the total price of tokens.
    error NFTDrop__MustSendTotalPrice(uint256 sentValue, uint256 totalPrice);

    /// @notice Emitted when given address doesn't have transfer role.
    error NFTDrop__NotTransferRole();

    /*///////////////////////////////////////////////////////////////
                    Constructor + initializer logic
    //////////////////////////////////////////////////////////////*/

    /// @dev Initiliazes the contract, like a constructor.
    constructor(
        address _defaultAdmin,
        string memory _name,
        string memory _symbol,
        string memory _contractURI,
        address _saleRecipient,
        address _royaltyRecipient,
        uint128 _royaltyBps
    ) {
        name = _name;
        symbol = _symbol;
        
        _setupContractURI(_contractURI);
        _setupOwner(_defaultAdmin);

        _setupRole(DEFAULT_ADMIN_ROLE, _defaultAdmin);
        _setupRole(MINTER_ROLE, _defaultAdmin);
        _setupRole(TRANSFER_ROLE, _defaultAdmin);
        _setupRole(TRANSFER_ROLE, address(0));

        _setupDefaultRoyaltyInfo(_royaltyRecipient, _royaltyBps);
        _setupPrimarySaleRecipient(_saleRecipient);
    }

    /*///////////////////////////////////////////////////////////////
                        ERC 165 / 721 / 2981 logic
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the URI for a given tokenId.
    function uri(uint256 _tokenId) public view override returns (string memory _tokenURI) {
        uint256 batchId = getBatchId(_tokenId);
        string memory batchUri = getBaseURI(_tokenId);

        if (isEncryptedBatch(batchId)) {
            return string(abi.encodePacked(batchUri, "0"));
        } else {
            return string(abi.encodePacked(batchUri, _tokenId.toString()));
        }
    }

    /// @dev See ERC 165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC1155)
        returns (bool)
    {
        return super.supportsInterface(interfaceId) || type(IERC2981).interfaceId == interfaceId;
    }

    /*///////////////////////////////////////////////////////////////
                    Lazy minting + delayed-reveal logic
    //////////////////////////////////////////////////////////////*/

    /**
     *  @dev Lets an account with `MINTER_ROLE` lazy mint 'n' NFTs.
     *       The URIs for each token is the provided `_baseURIForTokens` + `{tokenId}`.
     */
    function lazyMint(
        uint256 _amount,
        string calldata _baseURIForTokens,
        bytes calldata _encryptedBaseURI
    ) external onlyRole(MINTER_ROLE) returns (uint256 batchId) {
        if (_amount == 0) {
            revert NFTDrop__ZeroAmount();
        }

        uint256 startId = nextTokenIdToMint;

        (nextTokenIdToMint, batchId) = _batchMint(startId, _amount, _baseURIForTokens);

        if (_encryptedBaseURI.length != 0) {
            _setEncryptedBaseURI(batchId, _encryptedBaseURI);
        }

        emit TokensLazyMinted(startId, startId + _amount - 1, _baseURIForTokens, _encryptedBaseURI);
    }

    /// @dev Lets an account with `MINTER_ROLE` reveal the URI for a batch of 'delayed-reveal' NFTs.
    function reveal(uint256 _index, bytes calldata _key)
        external
        onlyRole(MINTER_ROLE)
        returns (string memory revealedURI)
    {
        uint256 batchId = getBatchIdAtIndex(_index);
        revealedURI = getRevealURI(batchId, _key);

        _setEncryptedBaseURI(batchId, "");
        _setBaseURI(batchId, revealedURI);

        emit TokenURIRevealed(_index, revealedURI);
    }

    /*///////////////////////////////////////////////////////////////
                        Internal functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Runs before every `claim` function call.
    function _beforeClaim(
        address,
        uint256 _quantity,
        address,
        uint256,
        AllowlistProof calldata,
        bytes memory
    ) internal view override {
        require(msg.sender == tx.origin, "BOT");
        if (_currentIndex + _quantity > nextTokenIdToMint) {
            revert NFTDrop__NotEnoughMintedTokens(_currentIndex, _quantity);
        }
    }

    /// @dev Collects and distributes the primary sale value of NFTs being claimed.
    function collectPriceOnClaim(
        uint256 _quantityToClaim,
        address _currency,
        uint256 _pricePerToken
    ) internal override {
        if (_pricePerToken == 0) {
            return;
        }

        uint256 totalPrice = _quantityToClaim * _pricePerToken;

        if (_currency == CurrencyTransferLib.NATIVE_TOKEN) {
            if (msg.value != totalPrice) {
                revert NFTDrop__MustSendTotalPrice(msg.value, totalPrice);
            }
        }

        CurrencyTransferLib.transferCurrency(
            _currency,
            msg.sender,
            primarySaleRecipient(),
            totalPrice
        );
    }

    /// @dev Transfers the NFTs being claimed.
    function transferTokensOnClaim(address _to, uint256 _quantityBeingClaimed)
        internal
        override
        returns (uint256 startTokenId)
    {
        startTokenId = _currentIndex;
        _safeMint(_to, _quantityBeingClaimed);
    }

    /// @dev Checks whether primary sale recipient can be set in the given execution context.
    function _canSetPrimarySaleRecipient() internal view override returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @dev Checks whether owner can be set in the given execution context.
    function _canSetOwner() internal view override returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @dev Checks whether royalty info can be set in the given execution context.
    function _canSetRoyaltyInfo() internal view override returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @dev Checks whether contract metadata can be set in the given execution context.
    function _canSetContractURI() internal view override returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @dev Checks whether platform fee info can be set in the given execution context.
    function _canSetClaimConditions() internal view override returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /*///////////////////////////////////////////////////////////////
                        Miscellaneous
    //////////////////////////////////////////////////////////////*/

    /// @dev Burns `tokenId`. See {ERC721-_burn}.
    function burn(uint256 tokenId) external virtual {
        // note: ERC721AUpgradeable's `_burn(uint256,bool)` internally checks for token approvals.
        _burn(tokenId, true);
    }

    /// @dev See {ERC721-_beforeTokenTransfer}.
    function _beforeTokenTransfers(
        address from,
        address to,
        uint256 startTokenId,
        uint256 quantity
    ) internal virtual override {
        super._beforeTokenTransfers(from, to, startTokenId, quantity);

        // if transfer is restricted on the contract, we still want to allow burning and minting
        if (!hasRole(TRANSFER_ROLE, address(0)) && from != address(0) && to != address(0)) {
            if (!hasRole(TRANSFER_ROLE, from) && !hasRole(TRANSFER_ROLE, to)) {
                revert NFTDrop__NotTransferRole();
            }
        }
    }

    function _dropMsgSender() internal view virtual override returns (address) {
        return msg.sender;
    }
}
