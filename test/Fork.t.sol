// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PriceRouter} from "../src/PriceRouter.sol";
import {SailOracle} from "../src/SailOracle.sol";
import {SailCollateralOracle} from "../src/SailCollateralOracle.sol";

interface IERC20Meta {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

interface IFeedMeta {
    function description() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/// Fork tests against Base mainnet — run with BASE_RPC_URL set:
///   BASE_RPC_URL=https://base.drpc.org forge test --match-contract ForkTest
/// Skipped automatically when BASE_RPC_URL is not set.
contract ForkTest is Test {
    address constant SEQUENCER_UPTIME = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    address constant FEED_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant FEED_USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant A_BAS_USDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address constant GAUNTLET_USDC_PRIME = 0xeE8F4eC5672F09119b96Ab6fB59C27E1b7e44b61;

    PriceRouter router;
    SailOracle oracle;
    SailCollateralOracle collateral;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        router = new PriceRouter(SEQUENCER_UPTIME, 3600);
        oracle = new SailOracle(address(router));
        collateral = new SailCollateralOracle(address(router));
        router.setFeed(WETH, FEED_ETH_USD);
        router.setFeed(USDC, FEED_USDC_USD);
        router.setAlias(A_BAS_USDC, USDC);
        router.setVault(GAUNTLET_USDC_PRIME);
    }

    function test_fork_address_book_sanity() public view {
        if (!forked) return;
        assertEq(IERC20Meta(WETH).symbol(), "WETH");
        assertEq(IERC20Meta(USDC).symbol(), "USDC");
        assertEq(IERC20Meta(USDC).decimals(), 6);
        assertEq(IERC20Meta(A_BAS_USDC).symbol(), "aBasUSDC");
        assertEq(IERC20Meta(GAUNTLET_USDC_PRIME).symbol(), "gtUSDCp");
        assertEq(IFeedMeta(FEED_ETH_USD).description(), "ETH / USD");
        assertEq(IFeedMeta(FEED_USDC_USD).description(), "USDC / USD");
        assertEq(IFeedMeta(FEED_ETH_USD).decimals(), 8);
    }

    function test_fork_swap_price_live() public view {
        if (!forked) return;
        (uint256 price, uint8 dec, uint256 up) = oracle.getPrice(WETH, USDC);
        assertEq(dec, 18);
        assertGt(up, block.timestamp - 90_000, "feed updated within 25h");
        // 1 WETH-unit -> USDC-units at 18-dec mantissa: a whole ETH (1e18 units) yields
        // `price` USDC units, so price/1e6 = whole-dollar ETH price.
        uint256 ethUsdWhole = price / 1e6;
        assertGt(ethUsdWhole, 500, "ETH > $500");
        assertLt(ethUsdWhole, 50_000, "ETH < $50k");
    }

    function test_fork_borrow_role_live() public view {
        if (!forked) return;
        (uint256 price, uint8 dec, uint256 up) = oracle.getPrice(USDC, address(0));
        assertEq(dec, 8 + 6);
        assertGt(up, 0);
        assertApproxEqRel(price, 1e8, 0.02e18, "USDC within 2% of $1");
    }

    function test_fork_vault_share_live() public view {
        if (!forked) return;
        (uint256 price, uint8 dec, uint256 up) = oracle.getPrice(GAUNTLET_USDC_PRIME, address(0));
        assertEq(dec, 8 + IERC20Meta(GAUNTLET_USDC_PRIME).decimals());
        assertGt(up, 0);
        // Share price known >= 1.0 underlying (live read 2026-07-17: ~1.1035)
        uint256 sharePriceUsd8 = price; // per whole share after decimals fold: price/1e8 per 10^shareDec units
        assertGt(sharePriceUsd8, 0);
    }

    function test_fork_collateral_valuation_live() public {
        if (!forked) return;
        // A real Base account holding aBasUSDC would work; use a synthetic one via deal on WETH.
        address acct = address(0xA11CE);
        deal(WETH, acct, 2e18);
        address[] memory tokens = new address[](1);
        tokens[0] = WETH;
        collateral.setPositions(acct, tokens);
        (uint256 value, uint8 dec, uint256 up) = collateral.getPrice(acct, address(0));
        assertEq(dec, 8);
        assertGt(up, 0);
        assertGt(value, 1000e8, "2 ETH > $1000");
        assertLt(value, 100_000e8, "2 ETH < $100k");
    }

    /// MEASURED LIMITATION (2026-07-17, cold storage): pricing a multi-market MetaMorpho
    /// share via live convertToAssets costs ~318k gas — MetaMorpho totalAssets() loops
    /// its withdrawQueue over Morpho Blue markets. That EXCEEDS Sail's 150k evaluation
    /// budget on its own: MetaMorpho shares must NOT be used in mandate-gated oracle
    /// paths. Feed/alias paths fit comfortably. See README "Gas fits the budget".
    function test_fork_gas_measured() public view {
        if (!forked) return;
        uint256 g0 = gasleft();
        oracle.getPrice(WETH, USDC);
        uint256 swapGas = g0 - gasleft();
        g0 = gasleft();
        oracle.getPrice(GAUNTLET_USDC_PRIME, address(0));
        uint256 metaMorphoGas = g0 - gasleft();
        assertLt(swapGas, 100_000, "feed-pair swap read leaves template headroom in 150k");
        assertGt(metaMorphoGas, 150_000, "documents the MetaMorpho exclusion; if this ever fits the budget, celebrate and update README");
    }
}
