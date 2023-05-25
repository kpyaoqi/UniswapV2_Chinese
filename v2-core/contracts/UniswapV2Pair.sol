pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath for uint;
    using UQ112x112 for uint224;
    // 用于表示流动性池中的最小流动性份额
    uint public constant MINIMUM_LIQUIDITY = 10 ** 3;
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));
    //对应的UniswapV2Factory合约地址
    address public factory;
    // 交易对中的两个token地址
    address public token0;
    address public token1;
    // 两个token在交易对中的储备量
    uint112 private reserve0;
    uint112 private reserve1;
    // 相对于上一次更新储备量的时间间隔
    uint32 private blockTimestampLast;
    // 价格累计值
    uint public price0CumulativeLast;
    uint public price1CumulativeLast;
    // 常量乘积模型的k值
    uint public kLast;
    uint private unlocked = 1;
    // 防重入锁
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    // 获取token在交易对中的储备量和相对于上一次更新储备量的时间间隔
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    /**
     * @dev: 转账token函数
     * @param {address} token:进行转账的token地址
     * @param {address} to:接受转账的地址
     * @param {uint} uint:转账的数量
     */
    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor() public {
        factory = msg.sender;
    }

    // 在部署时由工厂调用一次
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    /**
     * @dev: 更新储备，并在每个区块的第一次调用时更新价格累加器
     * @param {uint} balance0:更新后tokenA的储备量
     * @param {uint} balance1:更新后tokenA的储备量
     * @param {uint112} _reserve0:当前tokenA的储备量
     * @param {uint112} _reserve1:当前tokenB的储备量
     */
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');
        // 取时间戳的低 32 位
        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        // 时间间隔
        uint32 timeElapsed = blockTimestamp - blockTimestampLast;
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // 永远不会溢出，+ overflow是理想的
            // priceCumulativeLast += ((_reserve1 * 2 ** 112 ) / _reserve0 ) * timeElapsed
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    /**
     * @dev: 如果打开收费功能，就约等于1/6的增长的根号(k)
     * @param {uint112} _reserve0:tokenA的储备量
     * @param {uint112} _reserve1:tokenB的储备量
     * @return {bool} feeOn: 返回是否接受手续费
     */
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        // 获取收取手续费的地址
        address feeTo = IUniswapV2Factory(factory).feeTo();
        feeOn = feeTo != address(0);
        // 节省gas
        uint _kLast = kLast;
        if (feeOn) {
            if (_kLast != 0) {
                // rootk=sqrt(_reserve0 * _reserve1)
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                // 上一次交易后的sqrt(k)值
                uint rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    // 分子(lptoken总量*(rootK-rootKLast))
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    // 分母(rooL*5+rooKLast)
                    uint denominator = rootK.mul(5).add(rootKLast);
                    // liquidity = ( totalSupply * ( sqrt(_reserve0 * _reserve1) -  sqrt(_kLast) ) ) / sqrt(_reserve0 * _reserve1) * 5 + sqrt(_kLast)
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    /**
     * @dev: 铸造lptoken
     * @param {address} to:接受lptoken的地址
     * @return {uint} liquidity: lptoken的数量
     */
    function mint(address to) external lock returns (uint liquidity) {
        //  节省gas
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves();
        // 获取进行添加流动性的两个token的数量
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);
        // 判断是否进行收取手续费
        bool feeOn = _mintFee(_reserve0, _reserve1);
        // 节省gas，必须在这里定义，因为totalSupply可以在_mintFee中更新
        uint _totalSupply = totalSupply;
        // 创建一个新的流动性池
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
            // 永久锁定MINIMUM_LIQUIDITY
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            // 添加流动性所获得的lptoken数量(进行添加流动性的两种token的数量*目前lptoken的数量/当前token的储备量-->取较小值)
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        // 铸造lptoken函数
        _mint(to, liquidity);
        // 更新储备函数
        _update(balance0, balance1, _reserve0, _reserve1);
        // 如果收取手续费，更新交易后的k值
        if (feeOn) kLast = uint(reserve0).mul(reserve1);
        emit Mint(msg.sender, amount0, amount1);
    }

    /**
     * @dev: 销毁lptoken退出流动性
     * @param {address} to:接受交易对返回token的地址
     * @return {uint} amount0: 返回获得的tokenA的数量
     * @return {uint} amount1: 返回获得的tokenB的数量
     */
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        // 节省gas
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); 
        address _token0 = token0; 
        address _token1 = token1; 
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        // 为什么用addres(this)?-->因为获取退出lptoken数量时，是在route合约中先将lptoken转到当前合约，然后直接获得当前合约lptoken的数量
        uint liquidity = balanceOf[address(this)];
        // 收取手续费
        bool feeOn = _mintFee(_reserve0, _reserve1);
        // 节省gas，必须在这里定义，因为totalSupply可以在_mintFee中更新
        uint _totalSupply = totalSupply; 
        // 使用余额确保按比例分配-->(持有lptoken/总lptoken)*合约中持有token的数量
        amount0 = liquidity.mul(balance0) / _totalSupply; 
        amount1 = liquidity.mul(balance1) / _totalSupply; 
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        _burn(address(this), liquidity);
        // 转账两种token
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        // 更新储备量函数
        _update(balance0, balance1, _reserve0, _reserve1);
         // 如果收取手续费，更新交易后的k值
        if (feeOn) kLast = uint(reserve0).mul(reserve1); 
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /**
     * @dev: 根据tokenA的数量在交易池中进行交换tokenB
     * @param {uint} amount0Out:to地址接受tokenA的数量
     * @param {uint} amount1Out:to地址接受tokenB的数量
     * @param {address} to:接受token交换的地址
     * @param {bytes} data:是否进行回调其他方法
     */
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        // 获取token在交易对中的储备量，节省gas
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves();
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');
        uint balance0;
        uint balance1;
        {
            // _token{0,1}的作用域，避免堆栈过深的错误
            address _token0 = token0;
            address _token1 = token1;
            require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');
            // 转移代币
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); 
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); 
            // 用于回调合约来实现一些特定的业务逻辑或其他自定义功能(闪电贷....)
            if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
            // 合约拥有两种token的数量
            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
        }
        // 进行兑换的token量
        // 获得合约两种token的数量，前提是(balance > _reserve - amountOut)，就是当前合约拥有的token数量应该是大于(储备值-输出到to地址的值)，返回之间的差值
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        // 投入金额不足
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');
        {
            // Adjusted{0,1}的作用域，避免堆栈过深的错误
            // balanceAdjusted = balance * 1000 - amountIn * 3(确保在计算余额调整后的值时不会因为小数精度问题而导致错误)
            uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
            uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
            // 确保在交易完成后，资金池的储备量满足 Uniswap V2 中的 K 恒定公式，即 K = _reserve0 * _reserve1
            require(
                // balance0Adjusted * balance1Adjusted >= _reserve0 * _reserve0 * 1000 ** 2
                balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000 ** 2),
                'UniswapV2: K'
            );
        }
        // 更新储备量函数
        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /**
     * @dev: 使两个token的余额与储备相等
     * @param {address} to:接受两个token的余额与储备之间差值的地址
     */
    function skim(address to) external lock {
        // 节省汽油
        address _token0 = token0;
        address _token1 = token1;
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    /**
     * @dev: 使两个token的储备与余额相匹配
     */
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
