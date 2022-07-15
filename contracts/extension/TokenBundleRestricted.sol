// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import "./TokenBundle.sol";

abstract contract TokenBundleRestricted is TokenBundle {

    uint256 private restrictedAssetCount;    
    mapping(address => uint256) private indexOfrestrictedAsset;
    mapping(uint256 => Token) private restrictedAssetAt;

    function getRestrictionsCount() public view returns(uint256) {
        return restrictedAssetCount;
    }

    function checkTokenRestrictions(Token[] calldata _tokensToBind) public view returns(bool) {
        uint256 count = restrictedAssetCount;
        
        if(count == 0) {
            return true;
        }
        uint256[] memory requiredAmounts = new uint256[](count);
        for(uint256 i = 0; i < _tokensToBind.length; i++) {
            
            if(indexOfrestrictedAsset[_tokensToBind[i].assetContract] > 0) {
                if(restrictedAssetAt[indexOfrestrictedAsset[_tokensToBind[i].assetContract]].tokenId == _tokensToBind[i].tokenId) {
                    requiredAmounts[indexOfrestrictedAsset[_tokensToBind[i].assetContract] - 1] += _tokensToBind[i].totalAmount;
                }
            }
        }

        for(uint256 i = 0; i < count; i++) {
            if(requiredAmounts[i] < restrictedAssetAt[i + 1].totalAmount) {
                return false;
            }
        }
        return true;
    }
    
    function setTokenRestrictions(Token[] calldata _restrictions) public {
        require(_canSetTokenRestrictions(), "Unauthorized caller");
        
        uint256 index;

        if(restrictedAssetCount > 0) {
            clearRestrictions();
        }
        for(; index < _restrictions.length; index++) {
            _checkTokenType(_restrictions[index]);
            
            indexOfrestrictedAsset[_restrictions[index].assetContract] = index + 1;
            restrictedAssetAt[index + 1] = _restrictions[index];
        }
        restrictedAssetCount = index;
    }

    function clearRestrictions() public {
        require(_canSetTokenRestrictions(), "Unauthorized caller");

        uint256 index = restrictedAssetCount;

        if(index == 0) {
            revert("nothing to clear");
        }

        for(; index > 0; index--) {
            delete indexOfrestrictedAsset[restrictedAssetAt[index].assetContract];
            delete restrictedAssetAt[index];
        }
        restrictedAssetCount = index;  
    }

    function _canSetTokenRestrictions() internal virtual returns(bool);
}
