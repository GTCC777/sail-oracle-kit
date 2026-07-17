// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PriceRouter} from "../src/PriceRouter.sol";
import {SailOracle} from "../src/SailOracle.sol";
import {MockAggregator, MockERC20, MockERC4626, RevertingToken} from "./Mocks.sol";

contract SailOracleTest is Test {
    PriceRouter router;
    SailOracle oracle;

    MockERC20 usdc; // 6 dec
    MockERC20 weth; // 18 dec
    MockAggregator usdcFeed; // $0.9999, 8 dec
    MockAggregator ethFeed; //  $2500,  8 dec

    uint256 constant T0 = 1_800_000_000;

    function setUp() public {
        vm.warp(T0);
        router = new PriceRouter(address(0), 3600);
        oracle = new SailOracle(address(router));

        usdc = new MockERC20(6);
        weth = new MockERC20(18);
        usdcFeed = new MockAggregator(8, 0.9999e8, T0 - 100);
        ethFeed = new MockAggregator(8, 2500e8, T0 - 50);

        router.setFeed(address(usdc), address(usdcFeed));
        router.setFeed(address(weth), address(ethFeed));
    }

    // ── Swap role ─────────────────────────────────────────────────────────────

    function test_swap_usdc_to_weth_exact() public view {
        (uint256 price, uint8 dec, uint256 up) = oracle.getPrice(address(usdc), address(weth));
        // 1 USDC unit = (0.9999/2500)·10^(18-6) whole-ratio ⇒ mantissa 3.9996e26 at 18 dec
        assertEq(price, 3.9996e26, "usdc->weth mantissa");
        assertEq(dec, 18);
        assertEq(up, T0 - 100, "oldest of the two feeds");

        // Template math: expectedOut = amountIn * price / 10^dec — 1 USDC -> 0.00039996 WETH
        uint256 expectedOut = (1e6 * price) / 1e18;
        assertEq(expectedOut, 0.00039996e18);
    }

    function test_swap_weth_to_usdc_exact() public view {
        (uint256 price, uint8 dec,) = oracle.getPrice(address(weth), address(usdc));
        // t = 2500e8·1e18/0.9999e8 = 2500.25...e18 ; price = t·10^6/10^18
        uint256 t = (uint256(2500e8) * 1e18) / uint256(0.9999e8);
        assertEq(price, t / 1e12, "weth->usdc mantissa");
        assertEq(dec, 18);

        // 1 WETH -> ~2500.25 USDC
        uint256 expectedOut = (1e18 * price) / 1e18;
        assertApproxEqAbs(expectedOut, 2500.25e6, 0.001e6);
    }

    function test_swap_same_token_is_identity() public view {
        (uint256 price, uint8 dec,) = oracle.getPrice(address(usdc), address(usdc));
        assertEq(price, 1e18);
        assertEq(dec, 18);
    }

    // ── Borrow role ───────────────────────────────────────────────────────────

    function test_borrow_role_per_unit_usd() public view {
        (uint256 price, uint8 dec, uint256 up) = oracle.getPrice(address(weth), address(0));
        assertEq(price, 2500e8);
        assertEq(dec, 8 + 18, "USD8 + token decimals = per-unit");
        assertEq(up, T0 - 50);
    }

    // ── Fail-closed paths ─────────────────────────────────────────────────────

    function test_unregistered_token_denied() public {
        MockERC20 dai = new MockERC20(18);
        (uint256 price,, uint256 up) = oracle.getPrice(address(dai), address(weth));
        assertEq(price, 0);
        assertEq(up, 0);
    }

    function test_negative_answer_denied() public {
        ethFeed.set(-1, T0);
        (uint256 price,, uint256 up) = oracle.getPrice(address(weth), address(0));
        assertEq(price, 0);
        assertEq(up, 0);
    }

    function test_zero_updatedAt_denied() public {
        ethFeed.set(2500e8, 0);
        (,, uint256 up) = oracle.getPrice(address(weth), address(0));
        assertEq(up, 0);
    }

    function test_updatedAt_never_fabricated() public {
        // Stale feed: adapter must pass the stale timestamp through (template denies),
        // never substitute block.timestamp.
        ethFeed.set(2500e8, T0 - 90_000);
        (,, uint256 up) = oracle.getPrice(address(weth), address(0));
        assertEq(up, T0 - 90_000);
    }

    function test_reverting_token_metadata_denied() public {
        RevertingToken bad = new RevertingToken();
        router.setFeed(address(bad), address(ethFeed));
        (uint256 price,,) = oracle.getPrice(address(bad), address(0));
        assertEq(price, 0);
    }

    // ── Sequencer gating ──────────────────────────────────────────────────────

    function test_sequencer_down_denies_all() public {
        MockAggregator seq = new MockAggregator(0, 0, T0 - 10_000);
        seq.setStartedAt(T0 - 10_000);
        PriceRouter gated = new PriceRouter(address(seq), 3600);
        gated.setFeed(address(weth), address(ethFeed));
        SailOracle gatedOracle = new SailOracle(address(gated));

        (uint256 p1,, uint256 u1) = gatedOracle.getPrice(address(weth), address(0));
        assertGt(p1, 0, "sequencer up + grace elapsed: serves");
        assertGt(u1, 0);

        seq.set(1, T0); // down
        (uint256 p2,, uint256 u2) = gatedOracle.getPrice(address(weth), address(0));
        assertEq(p2, 0, "sequencer down: denied");
        assertEq(u2, 0);

        seq.set(0, T0); // back up, but inside grace period
        seq.setStartedAt(T0 - 100);
        (uint256 p3,,) = gatedOracle.getPrice(address(weth), address(0));
        assertEq(p3, 0, "grace period: denied");
    }

    // ── ERC-4626 pricing ──────────────────────────────────────────────────────

    function test_vault_share_priced_via_underlying() public {
        // 6-dec vault on USDC, share price 1.05 underlying
        MockERC4626 vault = new MockERC4626(6, address(usdc), 1.05e6);
        router.setVault(address(vault));

        (uint256 price, uint8 dec, uint256 up) = oracle.getPrice(address(vault), address(0));
        assertEq(price, uint256(0.9999e8) * 1.05e6 / 1e6, "1.05 x underlying USD");
        assertEq(dec, 8 + 6);
        assertEq(up, T0 - 100, "inherits underlying feed freshness");
    }

    function test_vault_of_vault_denied() public {
        MockERC4626 inner = new MockERC4626(6, address(usdc), 1.05e6);
        MockERC4626 outer = new MockERC4626(6, address(inner), 1.02e6);
        router.setVault(address(inner));
        router.setVault(address(outer));
        (uint256 price,,) = oracle.getPrice(address(outer), address(0));
        assertEq(price, 0, "nesting refused, fail-closed");
    }

    // ── Alias pricing ─────────────────────────────────────────────────────────

    function test_alias_prices_as_target() public {
        MockERC20 aUsdc = new MockERC20(6);
        router.setAlias(address(aUsdc), address(usdc));
        (uint256 price, uint8 dec,) = oracle.getPrice(address(aUsdc), address(0));
        assertEq(price, 0.9999e8);
        assertEq(dec, 14);
    }

    // ── Fuzz: convention round-trip ───────────────────────────────────────────

    function testFuzz_swap_convention_roundtrip(uint128 amountIn) public view {
        vm.assume(amountIn > 0);
        (uint256 pAB,,) = oracle.getPrice(address(usdc), address(weth));
        (uint256 pBA,,) = oracle.getPrice(address(weth), address(usdc));
        // out = in·pAB/1e18, back = out·pBA/1e18 ⇒ back ≈ in (floor-rounding drift only)
        uint256 out = (uint256(amountIn) * pAB) / 1e18;
        uint256 back = (out * pBA) / 1e18;
        assertLe(back, amountIn, "round-trip never inflates");
        if (amountIn > 1e6) {
            assertGt(back, uint256(amountIn) * 99 / 100, "round-trip within 1%");
        }
    }
}
