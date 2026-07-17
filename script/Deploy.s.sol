// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {PriceRouter} from "../src/PriceRouter.sol";
import {SailOracle} from "../src/SailOracle.sol";
import {SailCollateralOracle} from "../src/SailCollateralOracle.sol";

/// @notice Deploys the kit on Base mainnet and registers the canonical feed set.
///         All addresses verified 2026-07-17 against Chainlink RDD / protocol
///         registries AND live onchain description()/symbol() reads.
contract DeployBase is Script {
    // Chainlink Base mainnet (canonical proxies, 8 decimals)
    address constant SEQUENCER_UPTIME = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    address constant FEED_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant FEED_USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address constant FEED_CBBTC_USD = 0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D;
    address constant FEED_CBETH_USD = 0xd7818272B9e248357d13057AAb0B417aF31E817d;
    address constant FEED_EURC_USD = 0xDAe398520e2B67cd3f27aeF9Cf14D93D927f8250;

    // Base mainnet tokens
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant CBETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    address constant EURC = 0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42;

    // Aave v3 Base receipt token (rebasing 1:1 claim on USDC)
    address constant A_BAS_USDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;

    // Largest USDC MetaMorpho vaults (ERC-4626), symbol-verified onchain
    address constant SPARK_USDC = 0x7BfA7C4f149E7415b73bdeDfe609237e29CBF34A;
    address constant MW_FLAGSHIP_USDC = 0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca;
    address constant GAUNTLET_USDC_PRIME = 0xeE8F4eC5672F09119b96Ab6fB59C27E1b7e44b61;
    address constant SEAMLESS_USDC = 0x616a4E1db48e22028f6bbf20444Cd3b8e3273738;

    uint256 constant SEQUENCER_GRACE = 3600;

    function run() external {
        vm.startBroadcast();

        PriceRouter router = new PriceRouter(SEQUENCER_UPTIME, SEQUENCER_GRACE);
        SailOracle oracle = new SailOracle(address(router));
        SailCollateralOracle collateral = new SailCollateralOracle(address(router));

        router.setFeed(WETH, FEED_ETH_USD);
        router.setFeed(USDC, FEED_USDC_USD);
        router.setFeed(CBBTC, FEED_CBBTC_USD);
        router.setFeed(CBETH, FEED_CBETH_USD);
        router.setFeed(EURC, FEED_EURC_USD);

        router.setAlias(A_BAS_USDC, USDC);

        // MetaMorpho registrations are for OFF-MANDATE reads (dashboards, agents' own
        // fetch loops). Measured ~318k gas cold — they exceed Sail's 150k evaluation
        // budget and must not back a mandate-gated swap/borrow/collateral path.
        router.setVault(SPARK_USDC);
        router.setVault(MW_FLAGSHIP_USDC);
        router.setVault(GAUNTLET_USDC_PRIME);
        router.setVault(SEAMLESS_USDC);

        vm.stopBroadcast();

        // solhint-disable no-console
        console2.log("PriceRouter:         ", address(router));
        console2.log("SailOracle:          ", address(oracle));
        console2.log("SailCollateralOracle:", address(collateral));
    }
}
