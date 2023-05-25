# UniswapV2Factory

在构造函数中传入一个设置feeTo的权限者地址，主要用于创建两种token的交易对，并为其部署一个UniswapV2Pair合约用于管理这个交易对，UniswapV2Factory还包含一些手续费的一些设置.

## 合约当中具有的方法:

- function feeTo() external view returns (address)：返回收取手续费地址
- function feeToSetter() external view returns (address)：设置手续费收取地址的权限地址
- function getPair(address tokenA, address tokenB) external view returns (address pair)：获取两个token的交易对地址
- function allPairs(uint) external view returns (address pair)：返回指定位置的交易对地址
- function allPairsLength() external view returns (uint)：返回所有交易对的长度
- function createPair(address tokenA, address tokenB) external returns (address pair)：创建两个token的交易对地址
- function setFeeTo(address) external：更改收取手续费地址
- function setFeeToSetter(address) external：更改设置手续费收取地址的权限地址

在 Uniswap 协议中，`feeTo` 是一个变量，用于指定手续费收取地址。当用户在 Uniswap 上进行交易时，一定比例的交易手续费会被收取，并根据协议的设定进行分配。这个手续费分配的过程包括将一部分手续费发送给流动性提供者，同时还有一部分手续费发送到 `feeTo` 地址。

#### createPair:(address tokenA, address tokenB) returns (address pair)

```solidity
bytes32 salt = keccak256(abi.encodePacked(token0, token1));
bytes memory bytecode = type(UniswapV2Pair).creationCode;
assembly {
	//add(bytecode, 32)：opcode操作码的add方法,将bytecode偏移后32位字节处,因为前32位字节存的是bytecode长度
	//mload(bytecode)：opcode操作码的方法,获得bytecode长度
	pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
}
```

pair地址是通过**内联汇编assembly做create2**方法创建的，其中**salt**盐值是通过两个两个代币的地址计算

> 内联汇编：在 Solidity 源程序中嵌入汇编代码，对 EVM 有更细粒度的控制

# UniswapV2Pair

在构造函数中factory地址为msg.sender，因为该合约是由UniswapV2Factory进行部署，该合约继承了UniswapV2ERC20，主要用于管理以及操作交易对，托管两种token

## 合约当中比较重要的方法有(lptoken即UniswapV2ERC20):

  function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external：判断签名的有效性

  function mint(address to) external returns (uint liquidity)：铸造lptoken

  function burn(address to) external returns (uint amount0, uint amount1)：销毁lptoken退出流动性

  function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external：根据tokenA的数量在交易池中进行兑换tokenB

  function skim(address to) external：使两个token的余额与储备相等

  function sync() external：使两个token的储备与余额相匹配

  function initialize(address, address) external：设置pair地址交易对的两种token

#### permit:(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s)

```solidity
// ecrecover 函数可以返回与签名者对应的公钥地址
address recoveredAddress = ecrecover(digest, v, r, s);
// 判断签名者对应的公钥地址与授权地址是否一致
require(recoveredAddress != address(0) && recoveredAddress == owner, 'UniswapV2: INVALID_SIGNATURE');
_approve(owner, spender, value);
```

用户现在签名一笔交易，用该方法可有判断该签名的有效性,如果通过判断，则进行授权

#### mint：(address to) lock returns (uint liquidity)

```solidity
// 1.获取进行添加流动性的两个token的数量
(uint112 _reserve0, uint112 _reserve1, ) = getReserves();
uint balance0 = IERC20(token0).balanceOf(address(this));
uint balance1 = IERC20(token1).balanceOf(address(this));
uint amount0 = balance0.sub(_reserve0);
uint amount1 = balance1.sub(_reserve1);
// 2.调用_mintFee方法
// 3.添加流动性所获得的lptoken数量(进行添加流动性的两种token的数量*目前lptoken的数量/当前token的储备量-->取较小值)
liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
// 4.铸造lptoken函数和更新储备函数
_mint(to, liquidity);
_update(balance0, balance1, _reserve0, _reserve1);
```

主要是根据两个token在交易对的增量计算出应该铸造lptoken的数量，然后将lptoken铸造给to地址，具有防重入锁lock

#### burn：(address to) lock returns (uint amount0, uint amount1)

```solidity
// 1.为什么用addres(this)?-->因为获取退出lptoken数量时，是在Route合约中先将lptoken转到当前合约，然后直接获得当前合约lptoken的数量
uint liquidity = balanceOf[address(this)];
// 2.调用_mintFee方法
// 3.使用余额确保按比例分配-->(持有lptoken/总lptoken)*合约中持有token的数量
amount0 = liquidity.mul(balance0) / _totalSupply; 
amount1 = liquidity.mul(balance1) / _totalSupply; 
// 4.转账两种token并更新储备量
_safeTransfer(_token0, to, amount0);
_safeTransfer(_token1, to, amount1);
balance0 = IERC20(_token0).balanceOf(address(this));
balance1 = IERC20(_token1).balanceOf(address(this));
_update(balance0, balance1, _reserve0, _reserve1);
```

根据lptokne的比例计算出两种token的各自的数量，然后销毁lptoken并将转账两种token给to地址

#### swap：(uint amount0Out, uint amount1Out, address to, bytes calldata data)

```solidity
// 1.转移代币
if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); 
if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); 
// 2.用于回调合约来实现一些特定的业务逻辑或其他自定义功能(例如：闪电贷....)
if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
// 3.确保在交易完成后，资金池的储备量满足 Uniswap V2 中的 K 恒定公式，即 K = _reserve0 * _reserve1
// 4.更新储备
```

1.在Route合约用户已经将需要兑换的tokenA转入pair合约中，在Route合约中传入需要输出的tokenB的数量和一个data，转移tokenB后判断data长度是否大于零去进行回调合约

2.直接调用swap方法进行回调合约获得套利，只要套利后满足后续条件即可

## 合约内部调用的方法：

#### _update：(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private

```solidity
// 1.更新priceCumulativeLast，永远不会溢出，+ overflow是理想的
price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
// 2.更新储备量
reserve0 = uint112(balance0);
reserve1 = uint112(balance1);
```

更新储备方法：四个参数前两个为更新后两个token的储备量，后两个为更新前两个token的储备量

#### _mintFee：(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn)

```solidity
// 1.获取收取手续费的地址如果不是零地址并且kLast!=0则继续下面部分
// 2.获取上一次交易后和目前交易对中的K值
uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
uint rootKLast = Math.sqrt(_kLast);
// 3.如果rootK>rootKLast
uint numerator = totalSupply.mul(rootK.sub(rootKLast));
uint denominator = rootK.mul(5).add(rootKLast);
uint liquidity = numerator / denominator;
// 4.如果liquidity大于零为收取手续费地址铸造lptoken 
if (liquidity > 0) _mint(feeTo, liquidity);
```

收取手续费方法，参数为当前两个token的储备量
