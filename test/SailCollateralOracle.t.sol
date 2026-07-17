// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PriceRouter} from "../src/PriceRouter.sol";
import {SailOracle} from "../src/SailOracle.sol";
import {SailCollateralOracle} from "../src/SailCollateralOracle.sol";
import {MockAggregator, MockERC20, MockERC4626} from "./Mocks.sol";

contract SailCollateralOracleTest is Test {
    PriceRouter router;
    SailCollateralOracle collateral;
    SailOracle borrowOracle;

    MockERC20 usdc;
    MockERC20 weth;
    MockERC20 aUsdc;
    MockERC4626 vault;
    MockAggregator usdcFeed;
    MockAggregator ethFeed;

    address account = address(0xA11CE);
    uint256 constant T0 = 1_800_000_000;

    function setUp() public {
        vm.warp(T0);
        router = new PriceRouter(address(0), 3600);
        collateral = new SailCollateralOracle(address(router));
        borrowOracle = new SailOracle(address(router));

        usdc = new MockERC20(6);
        weth = new MockERC20(18);
        aUsdc = new MockERC20(6);
        vault = new MockERC4626(6, address(usdc), 1.05e6);

        usdcFeed = new MockAggregator(8, 0.9999e8, T0 - 100);
        ethFeed = new MockAggregator(8, 2500e8, T0 - 50);

        router.setFeed(address(usdc), address(usdcFeed));
        router.setFeed(address(weth), address(ethFeed));
        router.setAlias(address(aUsdc), address(usdc));
        router.setVault(address(vault));
    }

    function _positions2() internal {
        address[] memory tokens = new address[](2);
        tokens[0] = address(aUsdc);
        tokens[1] = address(weth);
        collateral.setPositions(account, tokens);
    }

    function test_aggregate_value_exact() public {
        _positions2();
        aUsdc.mint(account, 1000e6); // $999.90
        weth.mint(account, 0.5e18); //  $1250.00

        (uint256 value, uint8 dec, uint256 up) = collateral.getPrice(account, address(0));
        assertEq(value, 99_990_000_000 + 125_000_000_000, "$2249.90 in USD8");
        assertEq(dec, 8);
        assertEq(up, T0 - 100, "oldest feed timestamp");
    }

    function test_empty_positions_denied() public view {
        (uint256 value,, uint256 up) = collateral.getPrice(account, address(0));
        assertEq(value, 0);
        assertEq(up, 0);
    }

    function test_nonzero_quote_denied() public {
        _positions2();
        (uint256 value,,) = collateral.getPrice(account, address(usdc));
        assertEq(value, 0, "collateral role requires quote == address(0)");
    }

    function test_one_bad_leg_poisons_total() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(aUsdc);
        tokens[1] = address(new MockERC20(18)); // unregistered
        collateral.setPositions(account, tokens);
        aUsdc.mint(account, 1000e6);

        (uint256 value,, uint256 up) = collateral.getPrice(account, address(0));
        assertEq(value, 0, "must not silently under/over-report");
        assertEq(up, 0);
    }

    function test_vault_share_position() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(vault);
        collateral.setPositions(account, tokens);
        vault.mint(account, 100e6); // 100 shares -> 105 USDC -> $104.9895

        (uint256 value,,) = collateral.getPrice(account, address(0));
        assertEq(value, uint256(0.9999e8) * 1.05e6 / 1e6 * 100e6 / 1e6);
    }

    function test_only_owner_sets_positions() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        vm.prank(address(0xBEEF));
        vm.expectRevert(SailCollateralOracle.NotOwner.selector);
        collateral.setPositions(account, tokens);
    }

    function test_max_positions_enforced() public {
        address[] memory tokens = new address[](7);
        for (uint256 i = 0; i < 7; i++) {
            tokens[i] = address(usdc);
        }
        vm.expectRevert(SailCollateralOracle.TooManyPositions.selector);
        collateral.setPositions(account, tokens);
    }

    /// End-to-end check of BorrowPermission's LTV formula with this kit's two roles:
    /// maxAmountAllowed = mulDiv(mulDiv(colValue, ltvBps, 10_000), 10^borDec, 10^colDec) / borPrice
    function test_ltv_formula_end_to_end() public {
        _positions2();
        aUsdc.mint(account, 1000e6);
        weth.mint(account, 0.5e18);

        (uint256 colValue, uint8 colDec,) = collateral.getPrice(account, address(0));
        (uint256 borPrice, uint8 borDec,) = borrowOracle.getPrice(address(usdc), address(0));

        uint256 ltvBps = 5000; // 50%
        uint256 maxAmountAllowed =
            ((colValue * ltvBps / 10_000) * (10 ** borDec) / (10 ** colDec)) / borPrice;

        // $2249.90 halved = $1124.95 of USDC at $0.9999 ≈ 1125.0625 USDC (6-dec units)
        assertApproxEqAbs(maxAmountAllowed, 1125_062500, 100, "borrow ceiling in USDC units");
    }
}
