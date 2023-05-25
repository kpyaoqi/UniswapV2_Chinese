pragma solidity >=0.5.0;

import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import '@uniswap/lib/contracts/libraries/FixedPoint.sol';

// 具有与计算平均价格有关的预言机辅助方法的库
library UniswapV2OracleLibrary {
    using FixedPoint for *;

    // 返回 uint32 范围内的当前区块时间戳的辅助函数，即 [0, 2**32 -1]
    function currentBlockTimestamp() internal view returns (uint32) {
        return uint32(block.timestamp % 2 ** 32);
    }

    // 使用反事实生成累积价格以节省 gas 并避免调用同步。
    function currentCumulativePrices(
        address pair
    ) internal view returns (uint price0Cumulative, uint price1Cumulative, uint32 blockTimestamp) {
        blockTimestamp = currentBlockTimestamp();
        price0Cumulative = IUniswapV2Pair(pair).price0CumulativeLast();
        price1Cumulative = IUniswapV2Pair(pair).price1CumulativeLast();

        // 如果自货币对上次更新以来已经过去了时间，则模拟累计价格值
        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = IUniswapV2Pair(pair).getReserves();
        if (blockTimestampLast != blockTimestamp) {
            //需要减法溢出
            uint32 timeElapsed = blockTimestamp - blockTimestampLast;
            //需要加法溢出
            //反事实
            price0Cumulative += uint(FixedPoint.fraction(reserve1, reserve0)._x) * timeElapsed;
            //反事实
            price1Cumulative += uint(FixedPoint.fraction(reserve0, reserve1)._x) * timeElapsed;
        }
    }
}
