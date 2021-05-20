/// StakedTokenAuctionHouse.sol

// Copyright (C) 2021 Reflexer Labs, INC
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity 0.6.7;

import "./utils/ReentrancyGuard.sol";

abstract contract TokenLike {
    function decimals() virtual public view returns (uint8);
    function totalSupply() virtual public view returns (uint256);
    function balanceOf(address) virtual public view returns (uint256);
    function mint(address, uint) virtual public;
    function burn(address, uint) virtual public;
    function approve(address, uint256) virtual external returns (bool);
    function transfer(address, uint256) virtual external returns (bool);
    function transferFrom(address,address,uint256) virtual external returns (bool);
}
abstract contract AuctionHouseLike {
    function activeStakedTokenAuctions() virtual public view returns (uint256);
    function startAuction(uint256, uint256) virtual external returns (uint256);
}
abstract contract AccountingEngineLike {
    function debtAuctionBidSize() virtual public view returns (uint256);
    function unqueuedUnauctionedDebt() virtual public view returns (uint256);
}
abstract contract SAFEEngineLike {
    function coinBalance(address) virtual public view returns (uint256);
    function debtBalance(address) virtual public view returns (uint256);
}
abstract contract RewardDripperLike {
    function dripReward() virtual external;
    function rewardPerBlock() virtual external returns (uint256);
    function rewardToken() virtual external returns (TokenLike);
}

contract LPTokenLenderFirstResort is ReentrancyGuard {
    // --- Auth ---
    mapping (address => uint) public authorizedAccounts;
    /**
     * @notice Add auth to an account
     * @param account Account to add auth to
     */
    function addAuthorization(address account) virtual external isAuthorized {
        authorizedAccounts[account] = 1;
        emit AddAuthorization(account);
    }
    /**
     * @notice Remove auth from an account
     * @param account Account to remove auth from
     */
    function removeAuthorization(address account) virtual external isAuthorized {
        authorizedAccounts[account] = 0;
        emit RemoveAuthorization(account);
    }
    /**
    * @notice Checks whether msg.sender can call an authed function
    **/
    modifier isAuthorized {
        require(authorizedAccounts[msg.sender] == 1, "ProtocolTokenLenderFirstResort/account-not-authorized");
        _;
    }

    // --- Structs ---
    struct ExitWindow {
        // Start time when the exit can happen
        uint256 start;
        // Exit window deadline
        uint256 end;
    }

    // --- Variables ---
    // Flag that allows/blocks joining
    bool      public canJoin;
    // Flag that indicates whether canPrintProtocolTokens can ignore auctioning ancestor tokens
    bool      public bypassAuctions;
    // Whether the contract allows forced exits or not
    bool      public forcedExit;
    // Last block when a reward was pulled
    uint256   public lastRewardBlock;
    // The current delay enforced on an exit
    uint256   public exitDelay;
    // Time during which an address can exit without requesting a new window
    uint256   public exitWindow;
    // Min maount of ancestor tokens that must remain in the contract and not be auctioned
    uint256   public minStakedTokensToKeep;
    // Max number of auctions that can be active at a time
    uint256   public maxConcurrentAuctions;
    // Amount of ancestor tokens to auction at a time
    uint256   public tokensToAuction;
    // Initial amount of system coins to request in exchange for tokensToAuction
    uint256   public systemCoinsToRequest;
    // Amount of rewards per share accumulated (total, see rewardDebt for more info)
    uint256   public accTokensPerShare;

    // Exit data
    mapping(address => ExitWindow) public exitWindows;

    // The amount of tokens inneligible for claim, see formula below
    mapping(address => uint256) internal rewardDebt;
    // Pending reward = (descendant.balanceOf(user) * accTokensPerShare) - rewardDebt[user]

    // The token being deposited in the pool
    TokenLike            public ancestor;
    // The token being backed by ancestor tokens
    TokenLike            public descendant;
    // The token used to pay rewards
    TokenLike            public rewardToken;
    // Auction house for staked tokens
    AuctionHouseLike     public auctionHouse;
    // Accounting engine contract
    AccountingEngineLike public accountingEngine;
    // The safe engine contract
    SAFEEngineLike       public safeEngine;
    // Contract that drips rewards
    RewardDripperLike    public rewardDripper;

    // Max delay that can be enforced for an exit
    uint256 public immutable MAX_DELAY;
    // Minimum exit window during which an address can exit without waiting again for another window
    uint256 public immutable MIN_EXIT_WINDOW;
    // Max exit window during which an address can exit without waiting again for another window
    uint256 public immutable MAX_EXIT_WINDOW;

    // --- Events ---
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);
    event ModifyParameters(bytes32 indexed parameter, uint256 data);
    event ModifyParameters(bytes32 indexed parameter, address data);
    event ToggleJoin(bool canJoin);
    event ToggleBypassAuctions(bool bypassAuctions);
    event ToggleForcedExit(bool forcedExit);
    event AuctionAncestorTokens(address auctionHouse, uint256 amountAuctioned, uint256 amountRequested);
    event RequestExit(address indexed account, uint256 start, uint256 end);
    event Join(address indexed account, uint256 price, uint256 amount);
    event Exit(address indexed account, uint256 price, uint256 amount);
    event RewardsPaid(address account, uint256 amount);
    event PoolUpdated(uint256 accTokensPerShare, uint256 descendantSupply);

    constructor(
      address ancestor_,
      address descendant_,
      address auctionHouse_,
      address accountingEngine_,
      address safeEngine_,
      address rewardDripper_,
      uint256 maxDelay_,
      uint256 minExitWindow_,
      uint256 maxExitWindow_,
      uint256 exitDelay_,
      uint256 exitWindow_,
      uint256 minStakedTokensToKeep_,
      uint256 tokensToAuction_,
      uint256 systemCoinsToRequest_
    ) public {
        require(maxDelay_ > 0, "ProtocolTokenLenderFirstResort/null-max-delay");
        require(both(maxExitWindow_ > 0, maxExitWindow_ > minExitWindow_), "ProtocolTokenLenderFirstResort/invalid-max-exit-window");
        require(minExitWindow_ > 0, "ProtocolTokenLenderFirstResort/invalid-min-exit-window");
        require(exitDelay_ <= maxDelay_, "ProtocolTokenLenderFirstResort/invalid-exit-delay");
        require(both(exitWindow_ >= minExitWindow_, exitWindow_ <= maxExitWindow_), "ProtocolTokenLenderFirstResort/invalid-exit-window");
        require(minStakedTokensToKeep_ > 0, "ProtocolTokenLenderFirstResort/null-min-staked-tokens");
        require(tokensToAuction_ > 0, "ProtocolTokenLenderFirstResort/null-tokens-to-auction");
        require(systemCoinsToRequest_ > 0, "ProtocolTokenLenderFirstResort/null-sys-coins-to-request");
        require(auctionHouse_ != address(0), "ProtocolTokenLenderFirstResort/null-auction-house");
        require(accountingEngine_ != address(0), "ProtocolTokenLenderFirstResort/null-accounting-engine");
        require(safeEngine_ != address(0), "ProtocolTokenLenderFirstResort/null-safe-engine");
        require(rewardDripper_ != address(0), "ProtocolTokenLenderFirstResort/null-reward-dripper");

        authorizedAccounts[msg.sender] = 1;
        canJoin                        = true;
        maxConcurrentAuctions          = uint(-1);

        MAX_DELAY                      = maxDelay_;
        MIN_EXIT_WINDOW                = minExitWindow_;
        MAX_EXIT_WINDOW                = maxExitWindow_;

        exitDelay                      = exitDelay_;
        exitWindow                     = exitWindow_;

        minStakedTokensToKeep          = minStakedTokensToKeep_;
        tokensToAuction                = tokensToAuction_;
        systemCoinsToRequest           = systemCoinsToRequest_;

        auctionHouse                   = AuctionHouseLike(auctionHouse_);
        accountingEngine               = AccountingEngineLike(accountingEngine_);
        safeEngine                     = SAFEEngineLike(safeEngine_);
        rewardDripper                  = RewardDripperLike(rewardDripper_);

        ancestor                       = TokenLike(ancestor_);
        descendant                     = TokenLike(descendant_);
        rewardToken                    = TokenLike(rewardDripper.rewardToken());

        require(ancestor_ != address(rewardToken), "ProtocolTokenLenderFirstResort/invalid-ancestor-reward-tokens");

        lastRewardBlock                = block.number;

        require(ancestor.decimals() == 18, "ProtocolTokenLenderFirstResort/ancestor-decimal-mismatch");
        require(descendant.decimals() == 18, "ProtocolTokenLenderFirstResort/descendant-decimal-mismatch");

        emit AddAuthorization(msg.sender);
    }

    // --- Boolean Logic ---
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y)}
    }
    function either(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := or(x, y)}
    }

    // --- Math ---
    uint256 public constant WAD = 10 ** 18;
    uint256 public constant RAY = 10 ** 27;

    function addition(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x, "ProtocolTokenLenderFirstResort/add-overflow");
    }
    function subtract(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x, "ProtocolTokenLenderFirstResort/sub-underflow");
    }
    function multiply(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x, "ProtocolTokenLenderFirstResort/mul-overflow");
    }
    function wdivide(uint x, uint y) internal pure returns (uint z) {
        require(y > 0, "ProtocolTokenLenderFirstResort/wdiv-by-zero");
        z = multiply(x, WAD) / y;
    }
    function wmultiply(uint x, uint y) internal pure returns (uint z) {
        z = multiply(x, y) / WAD;
    }

    // --- Administration ---
    /*
    * @notify Switch between allowing and disallowing joins
    */
    function toggleJoin() external isAuthorized {
        canJoin = !canJoin;
        emit ToggleJoin(canJoin);
    }
    /*
    * @notify Switch between ignoring and taking into account auctions in canPrintProtocolTokens
    */
    function toggleBypassAuctions() external isAuthorized {
        bypassAuctions = !bypassAuctions;
        emit ToggleBypassAuctions(bypassAuctions);
    }
    /*
    * @notify Switch between allowing exits when the system is underwater or blocking them
    */
    function toggleForcedExit() external isAuthorized {
        forcedExit = !forcedExit;
        emit ToggleForcedExit(forcedExit);
    }
    /*
    * @notify Modify an uint256 parameter
    * @param parameter The name of the parameter to modify
    * @param data New value for the parameter
    */
    function modifyParameters(bytes32 parameter, uint256 data) external isAuthorized {
        if (parameter == "exitDelay") {
          require(data <= MAX_DELAY, "ProtocolTokenLenderFirstResort/invalid-exit-delay");
          exitDelay = data;
        }
        else if (parameter == "exitWindow") {
          require(both(data >= MIN_EXIT_WINDOW, data <= MAX_EXIT_WINDOW), "ProtocolTokenLenderFirstResort/invalid-exit-window");
          exitWindow = data;
        }
        else if (parameter == "minStakedTokensToKeep") {
          require(data > 0, "ProtocolTokenLenderFirstResort/null-min-staked-tokens");
          minStakedTokensToKeep = data;
        }
        else if (parameter == "tokensToAuction") {
          require(data > 0, "ProtocolTokenLenderFirstResort/invalid-tokens-to-auction");
          tokensToAuction = data;
        }
        else if (parameter == "systemCoinsToRequest") {
          require(data > 0, "ProtocolTokenLenderFirstResort/invalid-sys-coins-to-request");
          systemCoinsToRequest = data;
        }
        else if (parameter == "maxConcurrentAuctions") {
          require(data > 1, "ProtocolTokenLenderFirstResort/invalid-max-concurrent-auctions");
          maxConcurrentAuctions = data;
        }
        else revert("ProtocolTokenLenderFirstResort/modify-unrecognized-param");
        emit ModifyParameters(parameter, data);
    }
    /*
    * @notify Modify an address parameter
    * @param parameter The name of the parameter to modify
    * @param data New value for the parameter
    */
    function modifyParameters(bytes32 parameter, address data) external isAuthorized {
        require(data != address(0), "ProtocolTokenLenderFirstResort/null-data");

        if (parameter == "auctionHouse") {
          auctionHouse = AuctionHouseLike(data);
        }
        else if (parameter == "accountingEngine") {
          accountingEngine = AccountingEngineLike(data);
        }
        else if (parameter == "rewardDripper") {
          rewardDripper = RewardDripperLike(data);
        }
        else revert("ProtocolTokenLenderFirstResort/modify-unrecognized-param");
        emit ModifyParameters(parameter, data);
    }

    // --- Getters ---
    /*
    * @notify Return the ancestor token balance for this contract
    */
    function depositedAncestor() public view returns (uint256) {
        return ancestor.balanceOf(address(this));
    }
    /*
    * @notify Returns how many ancestor tokens are offered for one descendant token
    */
    function ancestorPerDescendant() public view returns (uint256) {
        return descendant.totalSupply() == 0 ? WAD : wdivide(depositedAncestor(), descendant.totalSupply());
    }
    /*
    * @notify Returns how many descendant tokens are offered for one ancestor token
    */
    function descendantPerAncestor() public view returns (uint256) {
        return descendant.totalSupply() == 0 ? WAD : wdivide(descendant.totalSupply(), depositedAncestor());
    }
    /*
    * @notify Given a custom amount of ancestor tokens, it returns the corresponding amount of descendant tokens to mint when someone joins
    * @param wad The amount of ancestor tokens to compute the descendant tokens for
    */
    function joinPrice(uint256 wad) public view returns (uint256) {
        return wmultiply(wad, descendantPerAncestor());
    }
    /*
    * @notify Given a custom amount of descendant tokens, it returns the corresponding amount of ancestor tokens to send when someone exits
    * @param wad The amount of descendant tokens to compute the ancestor tokens for
    */
    function exitPrice(uint256 wad) public view returns (uint256) {
        return wmultiply(wad, ancestorPerDescendant());
    }

    /*
    * @notice Returns whether the protocol is underwater or not
    */
    function protocolUnderwater() public view returns (bool) {
        uint256 unqueuedUnauctionedDebt = accountingEngine.unqueuedUnauctionedDebt();

        return both(
          accountingEngine.debtAuctionBidSize() <= unqueuedUnauctionedDebt,
          safeEngine.coinBalance(address(accountingEngine)) < unqueuedUnauctionedDebt
        );
    }

    /*
    * @notice Returns whether the pool can auction ancestor tokens
    */
    function canAuctionTokens() public view returns (bool) {
        return both(
          both(protocolUnderwater(), addition(minStakedTokensToKeep, tokensToAuction) <= depositedAncestor()),
          auctionHouse.activeStakedTokenAuctions() < maxConcurrentAuctions
        );
    }

    /*
    * @notice Returns whether the system can mint new ancestor tokens
    */
    function canPrintProtocolTokens() public view returns (bool) {
        return both(
          !canAuctionTokens(),
          either(auctionHouse.activeStakedTokenAuctions() == 0, bypassAuctions)
        );
    }

    // --- Core Logic ---

    /*
    * @notify Updates the pool and pays rewards (if any)
    * @dev Must be included in deposits and withdrawals
    */
    modifier payRewards() {
        // Updates the pool
        updatePool();

        if (descendant.balanceOf(msg.sender) > 0 && rewardToken.balanceOf(address(this)) > 0) {
            // Pays the reward
            uint256 pending = subtract(multiply(descendant.balanceOf(msg.sender), accTokensPerShare) / RAY, rewardDebt[msg.sender]);
            rewardToken.transferFrom(address(this), msg.sender, pending);
            emit RewardsPaid(msg.sender, pending);
        }
        _;
        rewardDebt[msg.sender] = multiply(descendant.balanceOf(msg.sender), accTokensPerShare) / RAY;
    }

    /*
    * @notify Pays outstanding rewards to msg.sender
    */
    function getRewards() external nonReentrant payRewards {}

    /*
    * @notify Updates pool data
    */
    function updatePool() public {
        if (block.number <= lastRewardBlock) return;

        lastRewardBlock = block.number;

        uint256 descendantSupply = descendant.totalSupply();
        if (descendantSupply == 0) return;

        uint256 prevBalance = rewardToken.balanceOf(address(this));
        rewardDripper.dripReward();
        uint256 increaseInBalance = rewardToken.balanceOf(address(this)) - prevBalance;

        // Updates distribution info
        accTokensPerShare = addition(accTokensPerShare, multiply(increaseInBalance, RAY) / descendantSupply);
        emit PoolUpdated(accTokensPerShare, descendantSupply);
    }

    /*
    * @notify Create a new auction that sells ancestor tokens in exchange for system coins
    */
    function auctionAncestorTokens() external nonReentrant {
        require(canAuctionTokens(), "ProtocolTokenLenderFirstResort/cannot-auction-tokens");

        ancestor.approve(address(auctionHouse), tokensToAuction);
        auctionHouse.startAuction(tokensToAuction, systemCoinsToRequest);

        updatePool();

        emit AuctionAncestorTokens(address(auctionHouse), tokensToAuction, systemCoinsToRequest);
    }

    /*
    * @notify Join ancestor tokens in exchange for descendant tokens
    * @param wad The amount of ancestor tokens to join
    */
    function join(uint256 wad) external nonReentrant payRewards {
        require(both(canJoin, !protocolUnderwater()), "ProtocolTokenLenderFirstResort/join-not-allowed");
        require(wad > 0, "ProtocolTokenLenderFirstResort/null-ancestor-to-join");

        uint256 price = joinPrice(wad);
        require(price > 0, "ProtocolTokenLenderFirstResort/null-join-price");

        require(ancestor.transferFrom(msg.sender, address(this), wad), "ProtocolTokenLenderFirstResort/could-not-transfer-ancestor");
        descendant.mint(msg.sender, price);

        emit Join(msg.sender, price, wad);
    }
    /*
    * @notice Request a new exit window during which you can burn descendant tokens in exchange for ancestor tokens
    */
    function requestExit() external {
        require(now > exitWindows[msg.sender].end, "ProtocolTokenLenderFirstResort/ongoing-request");
        exitWindows[msg.sender].start = addition(now, exitDelay);
        exitWindows[msg.sender].end   = addition(exitWindows[msg.sender].start, exitWindow);
        emit RequestExit(msg.sender, exitWindows[msg.sender].start, exitWindows[msg.sender].end);
    }
    /*
    * @notify Burn descendant tokens in exchange for getting ancestor tokens from this contract
    * @param wad The amount of descendant tokens to exit/burn
    */
    function exit(uint256 wad) external nonReentrant payRewards {
        require(wad > 0, "ProtocolTokenLenderFirstResort/null-descendant-to-burn");
        require(both(both(now >= exitWindows[msg.sender].start, now <= exitWindows[msg.sender].end), exitWindows[msg.sender].end > 0), "ProtocolTokenLenderFirstResort/not-in-window");
        require(either(!protocolUnderwater(), forcedExit), "ProtocolTokenLenderFirstResort/exit-not-allowed");

        uint256 price = exitPrice(wad);

        require(ancestor.transfer(msg.sender, price), "ProtocolTokenLenderFirstResort/could-not-transfer-ancestor");
        descendant.burn(msg.sender, wad);
        emit Exit(msg.sender, price, wad);
    }
}
