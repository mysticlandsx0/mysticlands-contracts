// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title MysticLands Reward Pool
/// @notice Holds the POL that funds in-game rewards. Players turn the LE they farmed into POL with a
///         claim signed by the game server. Rewards are variable and limited by this pool:
///         - every UTC day at most `dailyBps` of the balance (1% by default) can be paid out in total;
///         - every wallet has a daily maximum;
///         - the owner can end the pool at any time with `emergencyWithdraw`, but the POL can only go to
///           the treasury fixed at deploy (a stolen owner key cannot send it anywhere else);
///         - moving the pool to a new contract (any address) needs an on-chain notice of 7 days.
/// @dev Anyone can fund the pool (the revenue splitter sends 40% of game sales here).
contract MysticRewardPool is EIP712, Ownable2Step, Pausable, ReentrancyGuard {
    bytes32 public constant CLAIM_TYPEHASH =
        keccak256("PolClaim(address player,uint256 amount,uint256 nonce,uint256 deadline)");

    uint256 public constant MAX_DAILY_BPS = 500; // nunca mais que 5% do pool por dia
    uint256 public constant MIGRATION_DELAY = 7 days;

    /// @notice Unico destino possivel do saque de emergencia (gravado no deploy, nunca muda).
    address public immutable treasury;
    address public signer;
    uint256 public dailyBps;
    uint256 public walletDailyMax; // POL wei por carteira por dia

    mapping(uint256 day => uint256 budget) public budgetOfDay;
    mapping(uint256 day => uint256 paid) public paidOnDay;
    mapping(uint256 day => mapping(address wallet => uint256 paid)) public paidToWalletOnDay;
    mapping(uint256 nonce => bool) public nonceUsed;
    uint256 public totalFunded;
    uint256 public totalPaid;

    address public pendingPool;
    uint256 public migrationReadyAt;

    event Funded(address indexed from, uint256 amount);
    event Claimed(address indexed player, uint256 amount, uint256 indexed nonce);
    event SignerUpdated(address signer);
    event LimitsUpdated(uint256 dailyBps, uint256 walletDailyMax);
    event MigrationProposed(address indexed newPool, uint256 readyAt);
    event MigrationCancelled(address indexed newPool);
    event Migrated(address indexed newPool, uint256 amount);
    event EmergencyWithdrawn(address indexed treasury, uint256 amount);

    error ZeroAddress();
    error Expired();
    error NonceUsed();
    error InvalidSignature();
    error DailyBudgetReached(uint256 remaining);
    error WalletLimitReached(uint256 remaining);
    error TooHigh();
    error NoMigration();
    error TooEarly(uint256 readyAt);
    error TransferFailed();

    constructor(address initialOwner, address treasury_, address signer_, uint256 dailyBps_, uint256 walletDailyMax_)
        EIP712("MysticLands Reward Pool", "1")
        Ownable(initialOwner)
    {
        if (treasury_ == address(0) || signer_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        if (dailyBps_ > MAX_DAILY_BPS) revert TooHigh();
        signer = signer_;
        dailyBps = dailyBps_;
        walletDailyMax = walletDailyMax_;
    }

    receive() external payable {
        totalFunded += msg.value;
        emit Funded(msg.sender, msg.value);
    }

    /// @notice POL que ainda pode sair hoje (todas as carteiras juntas).
    function remainingToday() public view returns (uint256) {
        uint256 day = block.timestamp / 1 days;
        uint256 budget = budgetOfDay[day];
        if (budget == 0) budget = (address(this).balance * dailyBps) / 10_000;
        uint256 paid = paidOnDay[day];
        return paid >= budget ? 0 : budget - paid;
    }

    /// @notice POL que esta carteira ainda pode receber hoje.
    function remainingTodayFor(address wallet) external view returns (uint256) {
        uint256 paid = paidToWalletOnDay[block.timestamp / 1 days][wallet];
        uint256 own = paid >= walletDailyMax ? 0 : walletDailyMax - paid;
        uint256 all = remainingToday();
        return own < all ? own : all;
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Recebe a recompensa em POL assinada pelo servidor do jogo.
    function claim(uint256 amount, uint256 nonce, uint256 deadline, bytes calldata signature) external whenNotPaused nonReentrant {
        if (block.timestamp > deadline) revert Expired();
        if (nonceUsed[nonce]) revert NonceUsed();
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(CLAIM_TYPEHASH, msg.sender, amount, nonce, deadline)));
        if (ECDSA.recover(digest, signature) != signer) revert InvalidSignature();

        uint256 day = block.timestamp / 1 days;
        // o orcamento do dia e fixado no primeiro pagamento do dia (1% do saldo naquele momento)
        uint256 budget = budgetOfDay[day];
        if (budget == 0) {
            budget = (address(this).balance * dailyBps) / 10_000;
            budgetOfDay[day] = budget;
        }
        uint256 paid = paidOnDay[day];
        if (paid + amount > budget) revert DailyBudgetReached(budget > paid ? budget - paid : 0);
        uint256 walletPaid = paidToWalletOnDay[day][msg.sender];
        if (walletPaid + amount > walletDailyMax) revert WalletLimitReached(walletDailyMax > walletPaid ? walletDailyMax - walletPaid : 0);

        nonceUsed[nonce] = true;
        paidOnDay[day] = paid + amount;
        paidToWalletOnDay[day][msg.sender] = walletPaid + amount;
        totalPaid += amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Claimed(msg.sender, amount, nonce);
    }

    // ---------------------------------------------------------------- admin (sem saque do pool)

    function setSigner(address signer_) external onlyOwner {
        if (signer_ == address(0)) revert ZeroAddress();
        signer = signer_;
        emit SignerUpdated(signer_);
    }

    function setLimits(uint256 dailyBps_, uint256 walletDailyMax_) external onlyOwner {
        if (dailyBps_ > MAX_DAILY_BPS) revert TooHigh();
        dailyBps = dailyBps_;
        walletDailyMax = walletDailyMax_;
        emit LimitsUpdated(dailyBps_, walletDailyMax_);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Encerra o pool na hora: pausa as trocas e manda todo o POL para a tesouraria fixa.
    function emergencyWithdraw() external onlyOwner nonReentrant {
        if (!paused()) _pause();
        pendingPool = address(0);
        migrationReadyAt = 0;
        uint256 amount = address(this).balance;
        (bool ok,) = treasury.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit EmergencyWithdrawn(treasury, amount);
    }

    /// @notice Anuncia a mudanca do pool para um contrato novo (so pode acontecer 7 dias depois).
    function proposeMigration(address newPool) external onlyOwner {
        if (newPool == address(0)) revert ZeroAddress();
        pendingPool = newPool;
        migrationReadyAt = block.timestamp + MIGRATION_DELAY;
        emit MigrationProposed(newPool, migrationReadyAt);
    }

    function cancelMigration() external onlyOwner {
        emit MigrationCancelled(pendingPool);
        pendingPool = address(0);
        migrationReadyAt = 0;
    }

    /// @notice Depois do aviso de 7 dias, move todo o saldo para o pool novo anunciado.
    function executeMigration() external onlyOwner nonReentrant {
        if (pendingPool == address(0)) revert NoMigration();
        if (block.timestamp < migrationReadyAt) revert TooEarly(migrationReadyAt);
        address target = pendingPool;
        uint256 amount = address(this).balance;
        pendingPool = address(0);
        migrationReadyAt = 0;
        (bool ok,) = target.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Migrated(target, amount);
    }
}
