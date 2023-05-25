# UniswapV2Router02

在构造函数中传入factory合约和WETH合约地址，WETH的作用是将以太币包装成ERC-20代币，Route合约是与pair交易对进行交互的合约，常用于添加流动性、移除流动性、兑换、获取交易对信息......

**其中amountMin用于控制滑点，若amount_min = amount_desired - (amount_desired * 0.01)  表示 1%滑点容忍度**

## 合约当中比较重要的方法有：

#### addLiquidity：(address tokenA, address tokenB,uint amountADesired,uint amountBDesired,uint amountAMin,uint amountBMin,address to,uint deadline) ensure(deadline) returns (uint amountA, uint amountB, uint liquidity)

```solidity
// 1.调用 _addLiquidity方法，返回amountA，amountB
// 2.获取两个token的pair合约地址,并转账两个token
address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
// 3.向to地址铸造lptoken
liquidity = IUniswapV2Pair(pair).mint(to);
```

添加流动性方法：通过_addLiquidity方法传入期望添加token的数量和愿意接受的最低token数量返回实际添加到资金池中token的数量，想pair合约转账token并铸造lptoken

#### removeLiquidity：(address tokenA, address tokenB,uint liquidity,uint amountAMin,uint amountBMin,address to,uint deadline) ensure(deadline) returns (uint amountA, uint amountB)

```solidity
// 1.获取两个token的pair合约地址并将lptoken发送到pair合约
address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
IUniswapV2Pair(pair).transferFrom(msg.sender, pair, liquidity);
// 2.销毁lptoken，返回销毁lptoken获得两种token的数量
(uint amount0, uint amount1) = IUniswapV2Pair(pair).burn(to);
```

移除流动性方法：通过pair合约销毁lptoken移除流动性，获得的两个token需要大于愿意接受的最低token数量

#### swapExactTokensForTokens：(uint amountIn,uint amountOutMin,address[] calldata path,address to,uint deadline ) ensure(deadline) returns (uint[] memory amounts)

```solidity
// 根据传入的tokenA的数量和path获得amounts
amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
// 判断最终获得的tokenB的数量是否大于amountOutMin
require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
// 将tokenA传入第一对交易对中
TransferHelper.safeTransferFrom(path[0],msg.sender,UniswapV2Library.pairFor(factory, path[0], path[1]),amounts[0]);
// 兑换
_swap(amounts, path, to);
```

兑换：根据确切的tokenA的数量兑换tokenB

## 合约内部调用的方法：

#### _addLiquidity：(address tokenA, address tokenB,uint amountADesired,uint amountBDesired,uint amountAMin,uint amountBMin)  returns (uint amountA, uint amountB uint liquidity)

```solidity
// 1.获取两个token的pair地址，若不存则创建新的交易对
// 2.获取储备量并且不等于零
// 根据两种token的储备量和期望tokenA的数额获取tokenB最佳的数额
uint amountBOptimal = UniswapV2Library.quote(amountADesired, reserveA, reserveB);
// 3.根据期望值和愿意接受的最低token数量通过判断返回amountA，amountB
```

#### _swap：(uint[] memory amounts, address[] memory path, address _to)

```solidity
// 1.循环path路径
// 2.计算每对交易对的兑换量
// 3.如果中间还有其他的路径，to地址为其中交易对的pair地址
address to = i < path.length - 2 ? UniswapV2Library.pairFor(factory, output, path[i + 2]) : _to;
// 进行兑换
IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output)).swap(amount0Out,amount1Out,to,new bytes(0));
```

