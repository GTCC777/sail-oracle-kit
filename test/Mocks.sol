// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

contract MockAggregator {
    int256 public answer;
    uint256 public updatedAt;
    uint256 public startedAt;
    uint8 public immutable decimals;

    constructor(uint8 decimals_, int256 answer_, uint256 updatedAt_) {
        decimals = decimals_;
        answer = answer_;
        updatedAt = updatedAt_;
        startedAt = updatedAt_;
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function setStartedAt(uint256 startedAt_) external {
        startedAt = startedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, startedAt, updatedAt, 1);
    }
}

contract MockERC20 {
    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract MockERC4626 is MockERC20 {
    address public immutable asset;
    uint256 public assetsPerWholeShare; // in underlying units, for 10^decimals shares

    constructor(uint8 decimals_, address asset_, uint256 assetsPerWholeShare_) MockERC20(decimals_) {
        asset = asset_;
        assetsPerWholeShare = assetsPerWholeShare_;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * assetsPerWholeShare) / (10 ** decimals);
    }
}

contract RevertingToken {
    function decimals() external pure returns (uint8) {
        revert("nope");
    }

    function balanceOf(address) external pure returns (uint256) {
        revert("nope");
    }
}
