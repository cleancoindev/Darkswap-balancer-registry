pragma solidity 0.5.12;

// import "@nomiclabs/buidler/console.sol";

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";

interface IBPool {
    function getDenormalizedWeight(address token) external view returns(uint256);
    function getBalance(address token) external view returns(uint256);
    function getSwapFee() external view returns(uint256);
}

interface IBFactory {
    function isBPool(address b) external view returns (bool);
}


contract BRegistry {
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    struct PoolPairInfo {
        uint weight1;
        uint weight2;
        uint swapFee;
    }

    struct SortedPools {
        EnumerableSet.AddressSet pools;
        bytes32 indices;
    }

    event PoolTokenPairAdded(
        address indexed pool,
        address indexed token1,
        address indexed token2
    );

    event IndicesUpdated(
        address indexed token1,
        address indexed token2,
        bytes32 oldIndices,
        bytes32 newIndices
    );

    uint private constant BONE = 10**18;
    uint private constant MIN_SWAP_FEE = BONE / 100;

    mapping(bytes32 => SortedPools) private _pools;
    mapping(address => mapping(bytes32 => PoolPairInfo)) private _infos;

    IBFactory bfactory;

    constructor(address _bfactory) public {
        bfactory = IBFactory(_bfactory);
    }

    function getPairInfo(address pool, address fromToken, address destToken)
        external view returns(uint256 weight1, uint256 weight2, uint256 swapFee)
    {
        bytes32 key = _createKey(fromToken, destToken);
        PoolPairInfo memory info = _infos[pool][key];
        return (info.weight1, info.weight2, info.swapFee);
    }

    function getPoolsWithLimit(address fromToken, address destToken, uint256 offset, uint256 limit)
        public view returns(address[] memory result)
    {
        bytes32 key = _createKey(fromToken, destToken);
        result = new address[](Math.min(limit, _pools[key].pools.values.length - offset));
        for (uint i = 0; i < result.length; i++) {
            result[i] = _pools[key].pools.values[offset + i];
        }
    }

    function getBestPools(address fromToken, address destToken)
        external view returns(address[] memory pools)
    {
        return getBestPoolsWithLimit(fromToken, destToken, 32);
    }

    function getBestPoolsWithLimit(address fromToken, address destToken, uint256 limit)
        public view returns(address[] memory pools)
    {
        bytes32 key = _createKey(fromToken, destToken);
        bytes32 indices = _pools[key].indices;
        uint256 len = 0;
        while (indices[len] > 0 && len < Math.min(limit, indices.length)) {
            len++;
        }

        pools = new address[](len);
        for (uint i = 0; i < len; i++) {
            uint256 index = uint256(uint8(indices[i])).sub(1);
            pools[i] = _pools[key].pools.values[index];
        }
    }

    // Add and update registry

    function addPoolPair(address pool, address token1, address token2) public returns(uint256 listed) {

        require(bfactory.isBPool(pool), "ERR_NOT_BPOOL");

        uint256 swapFee = IBPool(pool).getSwapFee();
        require(swapFee <= MIN_SWAP_FEE, "ERR_FEE_TOO_HIGH");

        bytes32 key = _createKey(token1, token2);
        _pools[key].pools.add(pool);

         if (token1 < token2) {
            _infos[pool][key] = PoolPairInfo({
                weight1: IBPool(pool).getDenormalizedWeight(token1),
                weight2: IBPool(pool).getDenormalizedWeight(token2),
                swapFee: swapFee
            });
        } else {
            _infos[pool][key] = PoolPairInfo({
                weight1: IBPool(pool).getDenormalizedWeight(token2),
                weight2: IBPool(pool).getDenormalizedWeight(token1),
                swapFee: swapFee
            });
        }

        emit PoolTokenPairAdded(
            pool,
            token1,
            token2
        );

        listed++;

    }

    function addPools(address[] calldata pools, address token1, address token2) external returns(uint256[] memory listed) {
        listed = new uint256[](pools.length);
        for (uint i = 0; i < pools.length; i++) {
            listed[i] = addPoolPair(pools[i], token1, token2);
        }
    }

    function sortPools(address[] calldata tokens, uint256 lengthLimit) external {
        for (uint i = 0; i < tokens.length; i++) {
            for (uint j = i + 1; j < tokens.length; j++) {
                bytes32 key = _createKey(tokens[i], tokens[j]);
                address[] memory pools = getPoolsWithLimit(tokens[i], tokens[j], 0, Math.min(256, lengthLimit));
                uint256[] memory invs = _getInvsForPools(tokens[i], tokens[j], pools);

                bytes32 indices = _buildSortIndices(invs);

                // console.logBytes32(indices);

                if (indices != _pools[key].indices) {
                    emit IndicesUpdated(
                        tokens[i] < tokens[j] ? tokens[i] : tokens[j],
                        tokens[i] < tokens[j] ? tokens[j] : tokens[i],
                        _pools[key].indices,
                        indices
                    );
                    _pools[key].indices = indices;
                }
            }
        }
    }

    // Internal

    function _createKey(address token1, address token2)
        internal pure returns(bytes32)
    {
        return bytes32(
            (uint256(uint128((token1 < token2) ? token1 : token2)) << 128) |
            (uint256(uint128((token1 < token2) ? token2 : token1)))
        );
    }

    function _getInvsForPools(address token1, address token2, address[] memory pools)
        internal view returns(uint256[] memory invs)
    {
        invs = new uint256[](pools.length);
        for (uint i = 0; i < pools.length; i++) {
            bytes32 key = _createKey(token1, token2);
            PoolPairInfo memory info = _infos[pools[i]][key];
            if (token1 < token2) {
                invs[i] = (info.weight1.div(info.weight2)).add(BONE);
                invs[i] = invs[i].div((2 * BONE).mul(IBPool(pools[i]).getBalance(token2)));
            } else {
                invs[i] = (info.weight2.div(info.weight1)).add(BONE);
                invs[i] = invs[i].div((2 * BONE).mul(IBPool(pools[i]).getBalance(token1)));
            }
        }
    }

    function _buildSortIndices(uint256[] memory invs)
        internal pure returns(bytes32)
    {
        uint256 result = 0;
        uint256 prevInv = uint256(-1);
        for (uint i = 0; i < Math.min(invs.length, 32); i++) {
            uint256 bestIndex = 0;
            for (uint j = 0; j < invs.length; j++) {
                if ((invs[j] > invs[bestIndex] && invs[j] < prevInv) || invs[bestIndex] >= prevInv) {
                    bestIndex = j;
                }
            }
            prevInv = invs[bestIndex];
            result |= (bestIndex + 1) << (248 - i * 8);
        }
        return bytes32(result);
    }
}