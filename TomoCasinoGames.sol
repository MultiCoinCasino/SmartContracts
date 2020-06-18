pragma solidity ^0.4.26;

contract TomoGame {
    function payoutBet(uint256 betData, uint256 entropy) public view returns (uint256, uint16, uint256);
}

contract TomoCasinoGames {
    uint8 constant MAXIMUM_RUNNING_GAMES = 100;

    // EVM BLOCKHASH opcode can query no further than 256 blocks into the
    // past. Given that settleBet uses block hash of placeBet as one of
    // complementary entropy sources, we cannot process bets older than this
    // threshold. On rare occasions tomodice's croupier may fail to invoke
    // settleBet in this timespan due to technical issues or extreme Tomochain
    // congestion; such bets can be refunded via invoking refundBet.
    uint constant BET_EXPIRATION_BLOCKS = 250;

    address[MAXIMUM_RUNNING_GAMES] public gameContracts;

    // Sicbo
    // blk#00 -> blk#23: place bet (45s)
    // blk#25 -> blk#27: settle bet (use blockhashes of 3 blocks #21 and #22 and #23)
    // blk#27 -> blk#30: shows result
    uint32[MAXIMUM_RUNNING_GAMES] public gameStartBlocks; // starting block for round 0
    uint32[MAXIMUM_RUNNING_GAMES] public gameSettledBlocks; // block number used to settleBet (less than gameRoutine)
    uint32[MAXIMUM_RUNNING_GAMES] public gameRoutines; // number of block for one round - set 0 to disable

    // Player balances
    mapping(address => uint256) public balances;

    // Croupier accounts.
    mapping(address => bool) public croupiers;

    // Standard contract ownership transfer.
    address public owner;
    address private nextOwner;

    event Deposit(address indexed player, uint256 amount, uint256 balance);
    event Withdraw(address indexed player, uint256 amount, uint256 balance);
    event SetBalance(address indexed player, uint256 balance);
    event Bet(address indexed player, uint8 gameId, uint32 round, uint16 betNumber, uint256 amount, uint256 payment, uint256 balance);
    event DepositFund(address indexed depositor, uint256 amount);
    event WithdrawFund(address indexed beneficiary, uint256 amount);

    // Constructor
    constructor () public {
        owner = msg.sender;
    }

    // Standard modifier on methods invokable only by contract owner.
    modifier onlyOwner {
        require(msg.sender == owner, "OnlyOwner methods called by non-owner.");
        _;
    }

    // Standard modifier on methods invokable only by contract owner.
    modifier onlyCroupier {
        require(croupiers[msg.sender], "OnlyCroupier methods called by non-croupier.");
        _;
    }

    // Standard contract ownership transfer implementation,
    function approveNextOwner(address _nextOwner) external onlyOwner {
        require(_nextOwner != owner, "Cannot approve current owner.");
        nextOwner = _nextOwner;
    }

    function acceptNextOwner() external {
        require(msg.sender == nextOwner, "Can only accept preapproved new owner.");
        owner = nextOwner;
    }

    // Set/unset the croupier address.
    function setCroupier(address croupier, bool croupierStatus) external onlyOwner {
        croupiers[croupier] = croupierStatus;
    }

    // user's deposit
    function() external payable {
        balances[msg.sender] = safeAdd(balances[msg.sender], msg.value);
        emit Deposit(msg.sender, msg.value, balances[msg.sender]);
    }

    function withdraw(address beneficiary, uint256 amount) external onlyOwner {
        require(balances[beneficiary] >= amount, "Exceed balance.");
        balances[beneficiary] = safeSub(balances[beneficiary], amount);
        require(beneficiary.send(amount), "Sending failed");
        emit Withdraw(beneficiary, amount, balances[beneficiary]);
    }

    // Banker deposits fund. Do not increase the sender's balance.
    function depositFund() external payable {
        emit DepositFund(msg.sender, msg.value);
    }

    function setBalance(address player, uint256 newBalance) external onlyOwner {
        balances[player] = newBalance;
        emit SetBalance(player, newBalance);
    }

    function setGameInfo(uint8 gameId, address gameContract, uint32 gameStartBlock, uint32 gameSettledBlock, uint32 gameRoutine) external onlyOwner {
        require(gameId >= 0 && gameId < MAXIMUM_RUNNING_GAMES, "gameId not in range.");
        gameContracts[gameId] = gameContract;
        gameStartBlocks[gameId] = gameStartBlock;
        gameSettledBlocks[gameId] = gameSettledBlock;
        gameRoutines[gameId] = gameRoutine;
    }

    // Contract may be destroyed only when there are no ongoing bets,
    // either settled or refunded. All funds are transferred to contract owner.
    function kill() external onlyOwner {
        selfdestruct(owner);
    }

    // This is the method used to settle 99% of the time. To process a bet with "commit" (sent to player),
    // settleBet should supply a "reveal" number that would Keccak256-hash to
    // "commit". "blockHash" is the block hash of placeBet block as seen by croupier; it
    // is additionally asserted to prevent changing the bet outcomes on Tomochain reorgs.
    function settleBets(uint8 gameId, uint32 round, uint16 numBets, address[] players, uint256[] bets) external onlyCroupier {
        uint32 settledBlockNumber = gameStartBlocks[gameId] + round * gameRoutines[gameId] + gameSettledBlocks[gameId];
        require(block.number > settledBlockNumber + 2, "settleBet too early.");
        require(block.number <= settledBlockNumber + BET_EXPIRATION_BLOCKS, "Blockhash can't be queried by EVM.");

        bytes32 sha3BlockHashes = keccak256(abi.encodePacked(blockhash(settledBlockNumber), blockhash(settledBlockNumber + 1), blockhash(settledBlockNumber + 2)));
        settleBetsCommon(gameId, round, numBets, players, bets, (uint256) (sha3BlockHashes));
    }

    // This is the method used to settle 0.1% of bets left with passed blockHash seen by croupier
    // It needs player to trust croupier and can only be executed after between [BET_EXPIRATION_BLOCKS, 100 * BET_EXPIRATION_BLOCKS]
    function settlesBetLate(uint8 gameId, uint32 round, uint16 numBets, address[] players, uint256[] bets, uint256 entropyBlockHashes) external onlyCroupier {
        require(block.number >= gameStartBlocks[gameId] + (round + 1) * gameRoutines[gameId] + BET_EXPIRATION_BLOCKS, "block.number needs to be after BET_EXPIRATION_BLOCKS");

        settleBetsCommon(gameId, round, numBets, players, bets, entropyBlockHashes);
    }

    function settleBetsCommon(uint8 gameId, uint32 round, uint16 numBets, address[] memory players, uint256[] memory bets, uint256 entropyBlockHashes) private {
        require(players.length == numBets, "players.length must equal to numBets.");
        require(bets.length == numBets, "bets.length must equal to numBets.");

        address gameContract = gameContracts[gameId];
        uint16 i;
        for (i = 0; i < numBets; i++) {
            address player = players[i];
            payoutBet(gameId, round, gameContract, player, bets[i], entropyBlockHashes);
        }
    }

    event Payout(uint256 betData, uint256 entropy);

    function payoutBet(uint8 gameId, uint32 round, address gameContract, address player, uint256 betData, uint256 entropyBlockHashes) private {
        emit Payout(betData, entropyBlockHashes);

        uint256 amount;
        uint16 betNumber;
        uint256 payMultipler;
        (amount, betNumber, payMultipler) = TomoGame(gameContract).payoutBet(betData, entropyBlockHashes);
        uint256 payment;
        if (payMultipler > 0) {
            payment = safeMul(amount, payMultipler);
            balances[player] = safeAdd(balances[player], payment);
        }
        balances[player] = safeSub(balances[player], amount);
        emit Bet(player, gameId, round, betNumber, amount, payment, balances[player]);
    }

    event EmergencyERC20Drain(address token, address owner, uint256 amount);

    // owner can drain tokens that are sent here by mistake
    function emergencyERC20Drain(ERC20 token, uint amount) external onlyOwner {
        emit EmergencyERC20Drain(address(token), owner, amount);
        token.transfer(owner, amount);
    }

    function safeMul(uint a, uint b) private pure returns (uint) {
        uint c = a * b;
        assert(a == 0 || c / a == b);
        return c;
    }

    function safeSub(uint a, uint b) private pure returns (uint) {
        assert(b <= a);
        return a - b;
    }

    function safeAdd(uint a, uint b) private pure returns (uint) {
        uint c = a + b;
        assert(c >= a && c >= b);
        return c;
    }
}

contract ERC20 {
    function transfer(address _to, uint256 _value) public returns (bool);
}
