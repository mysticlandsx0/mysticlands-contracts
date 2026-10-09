// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {MysticPlant} from "./MysticPlant.sol";
import {MysticLand} from "./MysticLand.sol";

/// @title MysticLands NFT Shop
/// @notice Sells seeds, starter kits, lands and bundles for POL. Prices are set in US dollars and charged
///         in POL through the Chainlink POL/USD feed. Every POL goes straight to the treasury (the revenue
///         splitter); the contract holds no funds.
///         Seeds germinate for {GROW_TIME} before anything is drawn: the purchase only records the order,
///         and the Chainlink VRF random word is requested by {germinate} once the seed is grown. So nobody,
///         not even by reading the blockchain, can know what a seed will become while it germinates.
///         After Chainlink answers, anyone calls {claim} and the NFTs are minted to the buyer.
///         Mother Trees are never sold directly: every seed has a small chance (`motherBps`) to grow into one.
///         Orders with lands only (no seeds) can be germinated right away.
contract MysticNftShop is VRFConsumerBaseV2Plus, EIP712, Pausable, ReentrancyGuard {
    struct Product {
        uint256 usdPrice; // US dollars with 8 decimals (1e8 = $1)
        uint16 plants;
        uint16 lands;
        bool active;
    }

    /// @dev The first five fields keep the layout of the first shop (buyer, plants, lands, minted, ready).
    struct Order {
        address buyer;
        uint16 plants;
        uint16 lands;
        uint16 minted;
        bool ready;
        uint64 plantedAt;
        uint64 requestedAt; // 0 = random word not requested yet (still germinating)
        uint256 vrfRequestId;
        uint256 seed;
    }

    struct VrfConfig {
        uint256 subscriptionId;
        bytes32 keyHash;
        uint32 callbackGasLimit;
        uint16 requestConfirmations;
        bool nativePayment;
    }

    uint256 public constant MAX_ITEMS_PER_ORDER = 300;
    uint16 public constant MAX_VOUCHER_SEEDS = 50;
    uint256 public constant RETRY_DELAY = 1 days;
    uint256 public constant GROW_TIME = 1 days;
    uint256 public constant MAX_MOTHER_BPS = 1_000; // nunca mais que 10% das seeds viram Mother Tree

    MysticPlant public immutable plants;
    MysticLand public immutable lands;

    address public treasury;
    AggregatorV3Interface public priceFeed;
    uint256 public maxStaleness = 1 days;
    /// @notice Chance (in basis points) of each seed becoming a Mother Tree. 100 = 1%.
    uint256 public motherBps = 100;
    VrfConfig public vrf;
    uint256 public orderCount;

    mapping(uint256 productId => Product) public products;
    mapping(uint256 orderId => Order) public orders;
    mapping(uint256 vrfRequestId => uint256 orderId) public orderOfRequest;
    // pedidos em aberto de cada jogador (o jogo le direto do contrato)
    mapping(address buyer => uint256[]) private _open;
    mapping(uint256 orderId => uint256 indexPlusOne) private _openIndex;

    bytes32 public constant SEED_VOUCHER_TYPEHASH =
        keccak256("SeedVoucher(address player,uint16 quantity,uint256 nonce,uint256 deadline)");
    address public seedSigner;
    uint256 public voucherDailyLimit;
    mapping(uint256 day => uint256 seeds) public voucherSeedsOnDay;
    mapping(uint256 nonce => bool) public voucherUsed;

    event Purchased(address indexed buyer, uint256 indexed orderId, uint256 indexed productId, uint16 quantity, uint256 polPaid);
    event Germinated(uint256 indexed orderId, uint256 indexed vrfRequestId);
    event RandomnessFulfilled(uint256 indexed orderId);
    event RandomnessRetried(uint256 indexed orderId, uint256 indexed newVrfRequestId);
    event OrderClaimed(uint256 indexed orderId, address indexed buyer, uint16 minted, bool completed);
    event ProductUpdated(uint256 indexed productId, uint256 usdPrice, uint16 plants, uint16 lands, bool active);
    event TreasuryUpdated(address treasury);
    event PricingUpdated(address feed, uint256 maxStaleness);
    event MotherChanceUpdated(uint256 motherBps);
    event VrfConfigUpdated(uint256 subscriptionId, bytes32 keyHash, uint32 callbackGasLimit, uint16 requestConfirmations);
    event SeedVoucherRedeemed(address indexed player, uint256 indexed orderId, uint16 quantity, uint256 nonce);
    event SeedSignerUpdated(address signer, uint256 dailyLimit);

    error InvalidQuantity();
    error InvalidProduct();
    error InvalidPrice();
    error StalePrice();
    error TooHigh();
    error Underpaid(uint256 sent, uint256 expected);
    error NativeTransferFailed();
    error UnknownOrder();
    error NotReady();
    error StillGerminating(uint256 readyAt);
    error AlreadyGerminated();
    error NotGerminated();
    error AlreadyFulfilled();
    error TooEarly();
    error VoucherExpired();
    error VoucherUsed();
    error InvalidVoucher();
    error VoucherDailyLimit(uint256 remaining);

    constructor(address coordinator, MysticPlant plants_, MysticLand lands_, address treasury_, address feed, VrfConfig memory vrf_)
        VRFConsumerBaseV2Plus(coordinator)
        EIP712("MysticLands Seeds", "1")
    {
        if (treasury_ == address(0) || feed == address(0)) revert ZeroAddress();
        plants = plants_;
        lands = lands_;
        treasury = treasury_;
        priceFeed = AggregatorV3Interface(feed);
        vrf = vrf_;
        _setProduct(1, 10e8, 1, 0, true); // seed: 1 planta (ou Mother Tree, por sorte)
        _setProduct(2, 17e8, 2, 0, true); // kit inicial: 2 seeds
        _setProduct(3, 100e8, 0, 1, true); // terreno aleatorio
        _setProduct(4, 150e8, 10, 1, true); // Efficient: 10 seeds + 1 terreno
        _setProduct(5, 500e8, 25, 3, true); // Landlord: 25 seeds + 3 terrenos
    }

    // ---------------------------------------------------------------- prices

    /// @notice POL (wei) charged right now for one unit of `productId`.
    function priceInPol(uint256 productId) public view returns (uint256) {
        Product memory p = products[productId];
        if (!p.active) revert InvalidProduct();
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (block.timestamp - updatedAt > maxStaleness) revert StalePrice();
        return (p.usdPrice * 1e18) / uint256(answer);
    }

    // ---------------------------------------------------------------- reading

    /// @notice When an order can be germinated (seeds: {GROW_TIME} after purchase; lands only: right away).
    function readyAt(uint256 orderId) public view returns (uint256) {
        Order memory o = orders[orderId];
        if (o.buyer == address(0)) revert UnknownOrder();
        return o.plants == 0 ? o.plantedAt : uint256(o.plantedAt) + GROW_TIME;
    }

    /// @notice Open orders of a player (germinating, waiting for Chainlink or partially minted).
    function openOrdersOf(address buyer) external view returns (uint256[] memory) {
        return _open[buyer];
    }

    // ---------------------------------------------------------------- purchases

    /// @notice Buys `quantity` units of a product. Send at least {priceInPol} x quantity; any excess is returned.
    function buy(uint256 productId, uint16 quantity) external payable whenNotPaused nonReentrant returns (uint256 orderId) {
        Product memory p = products[productId];
        if (!p.active) revert InvalidProduct();
        uint256 items = (uint256(p.plants) + p.lands) * quantity;
        if (quantity == 0 || items > MAX_ITEMS_PER_ORDER) revert InvalidQuantity();
        uint256 cost = priceInPol(productId) * quantity;
        if (msg.value < cost) revert Underpaid(msg.value, cost);

        orderId = _newOrder(msg.sender, uint16(uint256(p.plants) * quantity), uint16(uint256(p.lands) * quantity));
        _send(treasury, cost);
        if (msg.value > cost) _send(msg.sender, msg.value - cost);
        emit Purchased(msg.sender, orderId, productId, quantity, cost);
    }

    /// @notice Turns seeds earned in the game into an order, using a voucher signed by the game server.
    function redeemSeedVoucher(uint16 quantity, uint256 nonce, uint256 deadline, bytes calldata signature)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 orderId)
    {
        if (quantity == 0 || quantity > MAX_VOUCHER_SEEDS) revert InvalidQuantity();
        if (block.timestamp > deadline) revert VoucherExpired();
        if (voucherUsed[nonce]) revert VoucherUsed();
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(SEED_VOUCHER_TYPEHASH, msg.sender, quantity, nonce, deadline)));
        if (seedSigner == address(0) || ECDSA.recover(digest, signature) != seedSigner) revert InvalidVoucher();

        uint256 day = block.timestamp / 1 days;
        uint256 used = voucherSeedsOnDay[day];
        if (used + quantity > voucherDailyLimit) revert VoucherDailyLimit(voucherDailyLimit - used);
        voucherSeedsOnDay[day] = used + quantity;
        voucherUsed[nonce] = true;

        orderId = _newOrder(msg.sender, quantity, 0);
        emit SeedVoucherRedeemed(msg.sender, orderId, quantity, nonce);
    }

    /// @notice After the seeds have grown, asks Chainlink for the random word. Anyone can call it.
    function germinate(uint256 orderId) external whenNotPaused nonReentrant {
        Order storage o = orders[orderId];
        if (o.buyer == address(0)) revert UnknownOrder();
        if (o.requestedAt != 0) revert AlreadyGerminated();
        uint256 at = readyAt(orderId);
        if (block.timestamp < at) revert StillGerminating(at);
        _request(orderId, o);
        emit Germinated(orderId, o.vrfRequestId);
    }

    /// @notice Mints up to `maxItems` NFTs of a fulfilled order to its buyer. Anyone can call it.
    ///         Lands are minted first, then plants. Call again until the order is completed.
    function claim(uint256 orderId, uint16 maxItems) external nonReentrant {
        Order storage o = orders[orderId];
        if (o.buyer == address(0)) revert UnknownOrder();
        if (!o.ready) revert NotReady();

        uint256 total = uint256(o.plants) + o.lands;
        uint256 end = uint256(o.minted) + maxItems;
        if (end > total) end = total;
        address buyer = o.buyer;
        uint256 seed = o.seed;
        uint256 landCount = o.lands;
        uint256 start = o.minted;
        o.minted = uint16(end);

        for (uint256 i = start; i < end; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            if (i < landCount) {
                lands.mint(buyer, _landRarity(r >> 8), r);
            } else {
                plants.mint(buyer, _species(r), uint8((r >> 16) % 3), _plantRarity(r >> 8), r);
            }
        }

        bool completed = end == total;
        if (completed) {
            _close(buyer, orderId);
            delete orders[orderId];
        }
        emit OrderClaimed(orderId, buyer, uint16(end - start), completed);
    }

    /// @notice If Chainlink has not answered {RETRY_DELAY} after germination, anyone can ask again.
    function retryRandomness(uint256 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        if (o.buyer == address(0)) revert UnknownOrder();
        if (o.requestedAt == 0) revert NotGerminated();
        if (o.ready) revert AlreadyFulfilled();
        if (block.timestamp < uint256(o.requestedAt) + RETRY_DELAY) revert TooEarly();
        delete orderOfRequest[o.vrfRequestId];
        _request(orderId, o);
        emit RandomnessRetried(orderId, o.vrfRequestId);
    }

    // ---------------------------------------------------------------- VRF

    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        uint256 orderId = orderOfRequest[requestId];
        Order storage o = orders[orderId];
        // pedidos desconhecidos, refeitos ou ja respondidos sao ignorados
        if (orderId == 0 || o.buyer == address(0) || o.ready || o.vrfRequestId != requestId) return;
        o.seed = randomWords[0];
        o.ready = true;
        emit RandomnessFulfilled(orderId);
    }

    // ---------------------------------------------------------------- admin

    function setProduct(uint256 productId, uint256 usdPrice, uint16 plantCount, uint16 landCount, bool active) external onlyOwner {
        _setProduct(productId, usdPrice, plantCount, landCount, active);
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    function setPricing(address feed, uint256 maxStaleness_) external onlyOwner {
        if (feed == address(0)) revert ZeroAddress();
        priceFeed = AggregatorV3Interface(feed);
        maxStaleness = maxStaleness_;
        emit PricingUpdated(feed, maxStaleness_);
    }

    function setMotherChance(uint256 motherBps_) external onlyOwner {
        if (motherBps_ > MAX_MOTHER_BPS) revert TooHigh();
        motherBps = motherBps_;
        emit MotherChanceUpdated(motherBps_);
    }

    function setVrfConfig(VrfConfig calldata vrf_) external onlyOwner {
        vrf = vrf_;
        emit VrfConfigUpdated(vrf_.subscriptionId, vrf_.keyHash, vrf_.callbackGasLimit, vrf_.requestConfirmations);
    }

    /// @notice Server that signs seed vouchers and the max seeds redeemable per UTC day.
    function setSeedSigner(address signer_, uint256 dailyLimit_) external onlyOwner {
        seedSigner = signer_;
        voucherDailyLimit = dailyLimit_;
        emit SeedSignerUpdated(signer_, dailyLimit_);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ---------------------------------------------------------------- internals

    function _setProduct(uint256 productId, uint256 usdPrice, uint16 plantCount, uint16 landCount, bool active) private {
        if (productId == 0 || plantCount + landCount == 0 || usdPrice == 0) revert InvalidProduct();
        products[productId] = Product(usdPrice, plantCount, landCount, active);
        emit ProductUpdated(productId, usdPrice, plantCount, landCount, active);
    }

    function _send(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }

    function _newOrder(address buyer, uint16 plantCount, uint16 landCount) private returns (uint256 orderId) {
        orderId = ++orderCount;
        orders[orderId] = Order(buyer, plantCount, landCount, 0, false, uint64(block.timestamp), 0, 0, 0);
        _open[buyer].push(orderId);
        _openIndex[orderId] = _open[buyer].length;
    }

    // remove o pedido da lista de abertos em O(1)
    function _close(address buyer, uint256 orderId) private {
        uint256 index = _openIndex[orderId];
        if (index == 0) return;
        uint256[] storage list = _open[buyer];
        uint256 last = list[list.length - 1];
        list[index - 1] = last;
        _openIndex[last] = index;
        list.pop();
        delete _openIndex[orderId];
    }

    function _request(uint256 orderId, Order storage o) private {
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: vrf.keyHash,
                subId: vrf.subscriptionId,
                requestConfirmations: vrf.requestConfirmations,
                callbackGasLimit: vrf.callbackGasLimit,
                numWords: 1,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: vrf.nativePayment}))
            })
        );
        o.requestedAt = uint64(block.timestamp);
        o.vrfRequestId = requestId;
        orderOfRequest[requestId] = orderId;
    }

    /// @dev Especie: com chance `motherBps` vira uma das 4 Mother Trees (90-93); senao, uma das 40 plantas.
    function _species(uint256 r) private view returns (uint8) {
        if ((r >> 40) % 10_000 < motherBps) return uint8(90 + ((r >> 24) % 4));
        return uint8(r % 40);
    }

    /// @dev 70% common, 20% uncommon, 8% rare, 2% mythic (same odds as the game).
    function _plantRarity(uint256 r) private pure returns (uint8) {
        uint256 roll = r % 100;
        if (roll < 70) return 0;
        if (roll < 90) return 1;
        if (roll < 98) return 2;
        return 3;
    }

    /// @dev 75% common, 20% rare, 5% mythic.
    function _landRarity(uint256 r) private pure returns (uint8) {
        uint256 roll = r % 100;
        if (roll < 75) return 0;
        if (roll < 95) return 1;
        return 2;
    }
}
