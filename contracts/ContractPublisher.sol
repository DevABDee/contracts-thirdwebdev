// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

//  ==========  External imports    ==========
import "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";

//  ==========  Internal imports    ==========
import { IContractPublisher } from "./interfaces/IContractPublisher.sol";

//  ==========  Custom Errors    ==========
error ContractPublisher__UnapprovedCaller();

contract ContractPublisher is IContractPublisher, ERC2771Context, AccessControlEnumerable, Multicall {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /*///////////////////////////////////////////////////////////////
                            State variables
    //////////////////////////////////////////////////////////////*/

    /// @dev Whether the registry is paused.
    bool public isPaused;

    /*///////////////////////////////////////////////////////////////
                                Mappings
    //////////////////////////////////////////////////////////////*/

    /// @dev Mapping from publisher address => set of published contracts.
    mapping(address => CustomContractSet) private contractsOfPublisher;
    /// @dev Mapping publisher address => profile uri
    mapping(address => string) private profileUriOfPublisher;
    /// @dev Mapping compilerMetadataUri => publishedMetadataUri
    mapping(string => PublishedMetadataSet) private compilerMetadataUriToPublishedMetadataUris;

    /*///////////////////////////////////////////////////////////////
                    Constructor + modifiers
    //////////////////////////////////////////////////////////////*/

    /// @dev Checks whether caller is publisher TODO enable external approvals
    modifier onlyPublisher(address _publisher) {
        if (_msgSender() != _publisher) {
            revert ContractPublisher__UnapprovedCaller();
        }
        _;
    }

    /// @dev Checks whether contract is unpaused or the caller is a contract admin.
    modifier onlyUnpausedOrAdmin() {
        require(!isPaused || hasRole(DEFAULT_ADMIN_ROLE, _msgSender()), "registry paused");
        _;
    }

    constructor(address _trustedForwarder) ERC2771Context(_trustedForwarder) {
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /*///////////////////////////////////////////////////////////////
                            Getter logic
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the latest version of all contracts published by a publisher.
    function getAllPublishedContracts(address _publisher)
        external
        view
        returns (CustomContractInstance[] memory published)
    {
        uint256 total = EnumerableSet.length(contractsOfPublisher[_publisher].contractIds);

        published = new CustomContractInstance[](total);

        for (uint256 i = 0; i < total; i += 1) {
            bytes32 contractId = EnumerableSet.at(contractsOfPublisher[_publisher].contractIds, i);
            published[i] = contractsOfPublisher[_publisher].contracts[contractId].latest;
        }
    }

    /// @notice Returns all versions of a published contract.
    function getPublishedContractVersions(address _publisher, string memory _contractId)
        external
        view
        returns (CustomContractInstance[] memory published)
    {
        bytes32 id = keccak256(bytes(_contractId));
        uint256 total = contractsOfPublisher[_publisher].contracts[id].total;

        published = new CustomContractInstance[](total);

        for (uint256 i = 0; i < total; i += 1) {
            published[i] = contractsOfPublisher[_publisher].contracts[id].instances[i];
        }
    }

    /// @notice Returns the latest version of a contract published by a publisher.
    function getPublishedContract(address _publisher, string memory _contractId)
        external
        view
        returns (CustomContractInstance memory published)
    {
        published = contractsOfPublisher[_publisher].contracts[keccak256(bytes(_contractId))].latest;
    }

    /*///////////////////////////////////////////////////////////////
                            Publish logic
    //////////////////////////////////////////////////////////////*/

    /// @notice Let's an account publish a contract. The account must be approved by the publisher, or be the publisher.
    function publishContract(
        address _publisher,
        string memory _contractId,
        string memory _publishMetadataUri,
        string memory _compilerMetadataUri,
        bytes32 _bytecodeHash,
        address _implementation
    ) external onlyPublisher(_publisher) onlyUnpausedOrAdmin {
        CustomContractInstance memory publishedContract = CustomContractInstance({
            contractId: _contractId,
            publishTimestamp: block.timestamp,
            publishMetadataUri: _publishMetadataUri,
            bytecodeHash: _bytecodeHash,
            implementation: _implementation
        });

        bytes32 contractIdInBytes = keccak256(bytes(_contractId));
        EnumerableSet.add(contractsOfPublisher[_publisher].contractIds, contractIdInBytes);

        contractsOfPublisher[_publisher].contracts[contractIdInBytes].latest = publishedContract;

        uint256 index = contractsOfPublisher[_publisher].contracts[contractIdInBytes].total;
        contractsOfPublisher[_publisher].contracts[contractIdInBytes].total += 1;
        contractsOfPublisher[_publisher].contracts[contractIdInBytes].instances[index] = publishedContract;

        uint256 metadataIndex = compilerMetadataUriToPublishedMetadataUris[_compilerMetadataUri].index;
        compilerMetadataUriToPublishedMetadataUris[_compilerMetadataUri].uris[index] = _publishMetadataUri;
        compilerMetadataUriToPublishedMetadataUris[_compilerMetadataUri].index = metadataIndex + 1;

        emit ContractPublished(_msgSender(), _publisher, publishedContract);
    }

    /// @notice Lets an account unpublish a contract and all its versions. The account must be approved by the publisher, or be the publisher.
    function unpublishContract(address _publisher, string memory _contractId)
        external
        onlyPublisher(_publisher)
        onlyUnpausedOrAdmin
    {
        bytes32 contractIdInBytes = keccak256(bytes(_contractId));

        bool removed = EnumerableSet.remove(contractsOfPublisher[_publisher].contractIds, contractIdInBytes);
        require(removed, "given contractId DNE");

        delete contractsOfPublisher[_publisher].contracts[contractIdInBytes];

        emit ContractUnpublished(_msgSender(), _publisher, _contractId);
    }

    /// @notice Lets an account set its own publisher profile uri
    function setPublisherProfileUri(address publisher, string memory uri) public onlyPublisher(publisher) {
        profileUriOfPublisher[publisher] = uri;
    }

    // @notice Get a publisher profile uri
    function getPublisherProfileUri(address publisher) public view returns (string memory uri) {
        uri = profileUriOfPublisher[publisher];
    }

    /// @notice Retrieve the published metadata URI from a compiler metadata URI
    function getPublishedUriFromCompilerUri(string memory compilerMetadataUri)
        public
        view
        returns (string[] memory publishedMetadataUris)
    {
        uint256 length = compilerMetadataUriToPublishedMetadataUris[compilerMetadataUri].index;
        publishedMetadataUris = new string[](length);
        for (uint256 i = 0; i < length; i += 1) {
            publishedMetadataUris[i] = compilerMetadataUriToPublishedMetadataUris[compilerMetadataUri].uris[i];
        }
    }

    /*///////////////////////////////////////////////////////////////
                            Miscellaneous 
    //////////////////////////////////////////////////////////////*/

    /// @dev Lets a contract admin pause the registry.
    function setPause(bool _pause) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, _msgSender()), "unapproved caller");
        isPaused = _pause;
        emit Paused(_pause);
    }

    function _msgSender() internal view virtual override(Context, ERC2771Context) returns (address sender) {
        return ERC2771Context._msgSender();
    }

    function _msgData() internal view virtual override(Context, ERC2771Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }
}
