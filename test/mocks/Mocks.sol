// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPonsFactory} from "../../src/interfaces/IPons.sol";
import {IUnlockCallback, PoolKey, SwapParams} from "../../src/interfaces/IUniswapV4.sol";

/// @dev A fixed-supply-shaped launch token stand-in with an open mint for tests.
contract MockSTILL is ERC20 {
    constructor() ERC20("STILL", "STILL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev pons fee escrow: balances credited in ETH, claimed by the recipient.
contract MockEscrow {
    mapping(address => uint256) public balanceOf;
    bool public claimReverts;

    function credit(address recipient) external payable {
        balanceOf[recipient] += msg.value;
    }

    function setClaimReverts(bool v) external {
        claimReverts = v;
    }

    function claim() external {
        require(!claimReverts, "escrow: claim disabled");
        uint256 amount = balanceOf[msg.sender];
        balanceOf[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "escrow: send failed");
    }
}

/// @dev pons bonding curve: mints tokens at a fixed rate, can refund part of the input,
///      and can hold unswept fees that `sweepFees` moves into the escrow.
contract MockCurve {
    MockSTILL public immutable token;
    MockEscrow public immutable escrow;
    address public feeRecipient;
    uint256 public tokensPerEth = 1_000_000e18; // 1 ETH -> 1,000,000 STILL
    uint256 public refundBps; // portion of quoteIn handed back, simulating a clamped final buy
    uint256 public unsweptFees;
    bool public sweepReverts;

    constructor(MockSTILL token_, MockEscrow escrow_, address feeRecipient_) {
        token = token_;
        escrow = escrow_;
        feeRecipient = feeRecipient_;
    }

    function setFeeRecipient(address r) external {
        feeRecipient = r;
    }

    function setRefundBps(uint256 bps) external {
        refundBps = bps;
    }

    function setSweepReverts(bool v) external {
        sweepReverts = v;
    }

    function addUnsweptFees() external payable {
        unsweptFees += msg.value;
    }

    function sweepFees(uint256) external {
        require(!sweepReverts, "curve: InternalSwapRequiresOperator");
        uint256 amount = unsweptFees;
        unsweptFees = 0;
        if (amount > 0) escrow.credit{value: amount}(feeRecipient);
    }

    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256 tokensOut) {
        require(msg.value == quoteIn, "curve: NativeValueMismatch");
        uint256 refund = (quoteIn * refundBps) / 10_000;
        uint256 spent = quoteIn - refund;
        tokensOut = (spent * tokensPerEth) / 1e18;
        require(tokensOut >= minTokensOut, "curve: SlippageExceeded");
        token.mint(recipient, tokensOut);
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            require(ok, "curve: refund failed");
        }
    }
}

/// @dev Launch record with a settable phase.
contract MockFactory {
    IPonsFactory.LaunchedToken private _launch;

    function set(IPonsFactory.LaunchedToken memory launch) external {
        _launch = launch;
    }

    function setPhase(uint8 p) external {
        _launch.phase = p;
    }

    function getLaunchedToken(address) external view returns (IPonsFactory.LaunchedToken memory) {
        return _launch;
    }
}

/// @dev pons meme hook: sweeps either revert (operator-only path) or credit the escrow.
contract MockHook {
    MockEscrow public immutable escrow;
    address public poolManager;
    address public feeRecipient;
    bool public sweepReverts = true;
    uint256 public unsweptFees;

    constructor(MockEscrow escrow_, address poolManager_, address feeRecipient_) {
        escrow = escrow_;
        poolManager = poolManager_;
        feeRecipient = feeRecipient_;
    }

    function setFeeRecipient(address r) external {
        feeRecipient = r;
    }

    function setSweepReverts(bool v) external {
        sweepReverts = v;
    }

    function addUnsweptFees() external payable {
        unsweptFees += msg.value;
    }

    function sweepPoolFees(bytes32, uint256, uint256) external {
        require(!sweepReverts, "hook: InternalSwapRequiresOperator");
        uint256 amount = unsweptFees;
        unsweptFees = 0;
        if (amount > 0) escrow.credit{value: amount}(feeRecipient);
    }
}

/// @dev Enough of the Uniswap v4 PoolManager to exercise the unlock/swap/settle/take cycle:
///      exact-input ETH in, tokens out at a fixed rate, packed BalanceDelta, settlement check.
contract MockPoolManager {
    MockSTILL public immutable token;
    uint256 public tokensPerEth = 800_000e18; // post-graduation price, a bit worse than the curve
    uint256 private _owed;
    uint256 private _settled;
    address private _locker;
    PoolKey public lastKey;
    SwapParams public lastParams;

    constructor(MockSTILL token_) {
        token = token_;
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(_locker == address(0), "pm: AlreadyUnlocked");
        _locker = msg.sender;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        require(_settled == _owed, "pm: CurrencyNotSettled");
        _owed = 0;
        _settled = 0;
        _locker = address(0);
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata) external returns (int256 delta) {
        require(msg.sender == _locker, "pm: ManagerLocked");
        require(params.zeroForOne && params.amountSpecified < 0, "pm: unsupported swap");
        lastKey = key;
        lastParams = params;
        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 amountOut = (amountIn * tokensPerEth) / 1e18;
        _owed += amountIn;
        int128 a0 = -int128(int256(amountIn));
        int128 a1 = int128(int256(amountOut));
        assembly ("memory-safe") {
            delta := or(shl(128, a0), and(sub(shl(128, 1), 1), a1))
        }
    }

    function settle() external payable returns (uint256) {
        require(msg.sender == _locker, "pm: ManagerLocked");
        _settled += msg.value;
        return msg.value;
    }

    function take(address currency, address to, uint256 amount) external {
        require(msg.sender == _locker, "pm: ManagerLocked");
        require(currency == address(token), "pm: unknown currency");
        token.mint(to, amount);
    }

    function sync(address) external {}

    function extsload(bytes32) external pure returns (bytes32) {
        return bytes32(0);
    }
}
