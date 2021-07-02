// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./libs/IUniswapV2Router02.sol";
import "./libs/IUniswapV2Pair.sol";
import "./libs/IUniswapV2Factory.sol";

import "./FluxToken.sol";

// MasterChef is the master of FluxCake Token (FLUX). He can make FLUX and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. Initially the ownership is
// transferred to TimeLock contract and Later the ownership will be transferred to a governance smart
// contract once $FLUX is sufficiently distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Ownable, ReentrancyGuard {

//        __---~~~~--__                      __--~~~~---__
//   `\---~~~~~~~~\\                    //~~~~~~~~---/'
//     \/~~~~~~~~~\||                  ||/~~~~~~~~~\/
//                 `\\                //'
//                   `\\            //'
//                     ||          || 
//           ______--~~~~~~~~~~~~~~~~~~--______
//      ___ // _-~                        ~-_ \\ ___
//     `\__)\/~                              ~\/(__/'
//      _--`-___                            ___-'--_
//    /~     `\ ~~~~~~~~------------~~~~~~~~ /'     ~\
//   /|        `\                          /'        |\
//  | `\   ______`\_         DMC        _/'______   /' |
//  |   `\_~-_____\ ~-________________-~ /_____-~_/'   |
//  `.     ~-__________________________________-~     .'
//   `.      [_______/------|~~|------\_______]      .'
//    `\--___((____)(________\/________)(____))___--/'
//     |>>>>>>||                            ||<<<<<<|
//     `\<<<<</'                            `\>>>>>/'

    // What is this contract is about?
    // Lavacake fork with fixes:

    // - Added a fix to record the actual number of tokens deposited
    // - Tokens are minted at the harvest and not before, to get a better picture of the current total supply and prevent the whale limit % from being useless at harvest
    // - No tokens minted for the team, which reduces selling pressure and prevents any suspicion of dump from team at harvest
    // - Harvest is now dependent on a timestamp and not a block, which is fairer for everyone as exact block time is not an exact measure

    // Max deposit fee: 4%
    // Max referral rate: 5%

    // A 12h timelock will be added before farming starts - check the owner of this contract.

    // Min power amount: 1.21 Gigawatts
    // Min speed to time-travel: 88mph

    // We added quotes from the movies to entertain you while you read the contract

    // Synchronize your watches. The future's of defi is coming back…

    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
		uint256 rewardLockedUp; // Reward locked up.
        //
        // We do some fancy math here. Basically, any point in time, the amount of FLUXs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accFluxPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accFluxPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. FLUXs to distribute per block.
        uint256 lastRewardBlock; // Last block number that FLUXs distribution occurs.
        uint256 accFluxPerShare; // Accumulated FLUXs per share, times 1e12. See below.
        uint16 depositFeeBP; // Deposit fee in basis points
    }

    // Doc: The destruction might in fact be very localised, limited to merely our own galaxy.
    // Marty: Well, that's a relief.

    // The FLUX Token!
    FluxToken public flux;
    // FLUX tokens created per block.
    uint256 public fluxPerBlock;
    // Deposit Fee address
    address public feeAddress;
    // The swap router, modifiable. Will be changed to Flux's router when our own AMM release
    IUniswapV2Router02 public fluxRouter;
    // Harvest time (how many seconds can someone pull "harvest" after harvesting has started);
    uint256 public harvestTime; 
	// Start Timestamp Harvest - when someone can start to harvest
    uint256 public startTimeHarvest;    
    // The trading pair
    address public fluxPair;
    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when FLUX mining starts.
    uint256 public startBlock;
	// Total locked up rewards
    uint256 public totalLockedUpRewards;	
	
    // Referral Bonus in basis points. Initially set to 5%
    uint256 public refBonusBP = 500;
    // Max deposit fee: 4%.
    uint16 public constant MAXIMUM_DEPOSIT_FEE_BP = 400;
    // Max referral commission rate: 5%.
    uint16 public constant MAXIMUM_REFERRAL_BP = 500;
    // Referral Mapping
    mapping(address => address) public referrers; // account_address -> referrer_address
    mapping(address => uint256) public referredCount; // referrer_address -> num_of_referred
    // Pool Exists Mapper
    mapping(IBEP20 => bool) public poolExistence;
    // Pool ID Tracker Mapper
    mapping(IBEP20 => uint256) public poolIdForLpAddress;

    // Initial emission rate: 1 FLUX per block.
    uint256 public constant INITIAL_EMISSION_RATE = 10 ether;
	
    // Initial harvest time: 1 day.
    uint256 public constant INITIAL_HARVEST_TIME = 1 days;

    // Doc: What idiot dressed you in that outfit?
    // Marty: You did.
	
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event Referral(address indexed _referrer, address indexed _user);
    event ReferralPaid(address indexed _user, address indexed _userTo, uint256 _reward);
    event ReferralBonusBpChanged(uint256 _oldBp, uint256 _newBp);
    event EmissionRateUpdated(address indexed caller, uint256 previousAmount, uint256 newAmount);
	event UpdateHarvestTime(address indexed caller, uint256 _oldHarvestTime, uint256 _newHarvestTime);
	event UpdateStartTimeHarvest(address indexed caller, uint256 _oldStartTimeHarvest, uint256 _newStartTimeHarvest);
	event RewardLockedUp(address indexed user, uint256 indexed pid, uint256 amountLockedUp);

    constructor(
        FluxToken _flux,
        address _feeAddress,
        uint256 _startBlock,
        // Start time mush be equivalent to startblock
        uint256 _startTime
    ) public {
        flux = _flux;
        feeAddress = _feeAddress;
        fluxPerBlock = INITIAL_EMISSION_RATE;
        harvestTime = INITIAL_HARVEST_TIME;
        startBlock = _startBlock;
        startTimeHarvest = _startTime;
    }

    // Get number of pools added.
    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function getPoolIdForLpToken(IBEP20 _lpToken) external view returns (uint256) {
        require(poolExistence[_lpToken] != false, "getPoolIdForLpToken: do not exist");
        return poolIdForLpAddress[_lpToken];
    }

    // Modifier to check Duplicate pools
    modifier nonDuplicated(IBEP20 _lpToken) {
        require(poolExistence[_lpToken] == false, "nonDuplicated: duplicated");
        _;
    }

    // Marty: Hey, Doc! Where you going now? Back to the future?
    // Doc: Nope. Already been there.

    // Add a new lp to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IBEP20 _lpToken,
        uint16 _depositFeeBP,
        bool _withUpdate
    ) public onlyOwner nonDuplicated(_lpToken) {
        require(_depositFeeBP <= MAXIMUM_DEPOSIT_FEE_BP, "add: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolExistence[_lpToken] = true;
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accFluxPerShare: 0,
                depositFeeBP: _depositFeeBP
            })
        );
        poolIdForLpAddress[_lpToken] = poolInfo.length - 1;
    }

    // Update the given pool's FLUX allocation point and deposit fee. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        uint16 _depositFeeBP,
        bool _withUpdate
    ) public onlyOwner {
        require(_depositFeeBP <= MAXIMUM_DEPOSIT_FEE_BP, "set: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
    }

    // Doc: Roads? Where we're going we don't need... roads!

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
        public
        pure
        returns (uint256)
    {
        return _to.sub(_from);
    }

    // View function to see pending FLUXs on frontend.
    function pendingFlux(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accFluxPerShare = pool.accFluxPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 fluxReward = multiplier.mul(fluxPerBlock).mul(pool.allocPoint).div(
                    totalAllocPoint
                );
            accFluxPerShare = accFluxPerShare.add(
                fluxReward.mul(1e12).div(lpSupply)
            );
        }
        uint256 pending = user.amount.mul(accFluxPerShare).div(1e12).sub(user.rewardDebt);
        return pending.add(user.rewardLockedUp);		
    }

    // Doc: Is there a problem with Earth's gravitational pull in the future? Why is everything so heavy?

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 fluxReward =
            multiplier.mul(fluxPerBlock).mul(pool.allocPoint).div(
                totalAllocPoint
            );

        pool.accFluxPerShare = pool.accFluxPerShare.add(
            fluxReward.mul(1e12).div(lpSupply)
        );
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for FLUX allocation with referral.
    function deposit(uint256 _pid, uint256 _amount, address _referrer) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (_amount > 0 && _referrer != address(0) && _referrer == address(_referrer) && _referrer != msg.sender) {
            setReferral(msg.sender, _referrer);
        }
		payOrLockupPendingFlux(_pid);

        if (_amount > 0) {
            // How much tokens do we have now?
            uint beforeBalance = pool.lpToken.balanceOf(address(this));
            // We transfer the tokens
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            // How much did we get?
            _amount = pool.lpToken.balanceOf(address(this)).sub(beforeBalance);

            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);

                user.amount = user.amount.add(_amount).sub(depositFee);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
            } else {
                user.amount = user.amount.add(_amount);
            }
        }

        user.rewardDebt = user.amount.mul(pool.accFluxPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Marty: Wait a minute, Doc. Ah... Are you telling me that you built a time machine... out of a DeLorean?
    // Doc: The way I see it, if you're gonna build a time machine into a car, why not do it with some style?

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
		payOrLockupPendingFlux(_pid);
		
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accFluxPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
		user.rewardLockedUp = 0;
    }

	// Pay or lockup pending FLUXs.
    function payOrLockupPendingFlux(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 pending = user.amount.mul(pool.accFluxPerShare).div(1e12).sub(user.rewardDebt);
		uint256 totalRewards = pending.add(user.rewardLockedUp);

        uint256 lastTimeHarvest = startTimeHarvest.add(harvestTime);
        // Harvest needs to be after the startTimeHarvest and before the lastTimeHarvest
        if (block.timestamp >= startTimeHarvest && block.timestamp <= lastTimeHarvest) {

            if (pending > 0 || user.rewardLockedUp > 0) {        
                // reset lockup
                totalLockedUpRewards = totalLockedUpRewards.sub(user.rewardLockedUp);
                user.rewardLockedUp = 0;
                
                // We mint directly tokens to the harvester's account, so there's no transaction fee nor antiwhale problem
                flux.mint(msg.sender, totalRewards);
                payReferralCommission(msg.sender, totalRewards);
            }
        } else if (pending > 0) {
            user.rewardLockedUp = user.rewardLockedUp.add(pending);
            totalLockedUpRewards = totalLockedUpRewards.add(pending);
            emit RewardLockedUp(msg.sender, _pid, pending);
        }
    }
	
    // Safe flux transfer function, just in case if rounding error causes pool to not have enough FLUXs.
    function safeFluxTransfer(address _to, uint256 _amount) internal {
        uint256 fluxBal = flux.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > fluxBal) {
            transferSuccess = flux.transfer(_to, fluxBal);
        } else {
            transferSuccess = flux.transfer(_to, _amount);
        }
        require(transferSuccess, "safeFluxTransfer: transfer failed.");
    }

    // 1.21 GIGAWATTS!!!!!

    // Update fee address
    function setFeeAddress(address _feeAddress) external onlyOwner {
        require(_feeAddress != address(0), "setFeeAddress: invalid address");
        feeAddress = _feeAddress;
    }

    // updateEmissionRate
    function updateEmissionRate(uint256 _fluxPerBlock) external onlyOwner {
        massUpdatePools();
        emit EmissionRateUpdated(msg.sender, fluxPerBlock, _fluxPerBlock);
        fluxPerBlock = _fluxPerBlock;
    }

    // updateHarvestTime, how many blocks
    function updateHarvestTime(uint256 _harvestTime) external onlyOwner {
        harvestTime = _harvestTime;
		emit UpdateHarvestTime(msg.sender, harvestTime, _harvestTime);
    }

    

    // updateStartTimeHarvest
    function updateStartTimeHarvest(uint256 _startTimeHarvest) external onlyOwner {
        startTimeHarvest = _startTimeHarvest;
		emit UpdateStartTimeHarvest(msg.sender, startTimeHarvest, _startTimeHarvest);
    }

    // Set Referral Address for a user
    function setReferral(address _user, address _referrer) internal {
        if (_referrer == address(_referrer) && referrers[_user] == address(0) && _referrer != address(0) && _referrer != _user) {
            referrers[_user] = _referrer;
            referredCount[_referrer] += 1;
            emit Referral(_user, _referrer);
        }
    }

    // Get Referral Address for a Account
    function getReferral(address _user) public view returns (address) {
        return referrers[_user];
    }

    // Check how many people you referred
    function howManyPeopleDidIrefer(address _referrer) external view returns (uint) {
        return referredCount[_referrer];
    }

    // Pay referral commission to the referrer who referred this user.
    function payReferralCommission(address _user, uint256 _pending) internal {
        address referrer = getReferral(_user);
        if (referrer != address(0) && referrer != _user && refBonusBP > 0) {
            uint256 refBonusEarned = _pending.mul(refBonusBP).div(10000);
            flux.mint(referrer, refBonusEarned);
            emit ReferralPaid(_user, referrer, refBonusEarned);
        }
    }

    // Referral Bonus in basis points.
    // Initially set to 3%, this this the ability to increase or decrease the Bonus percentage based on
    // community voting and feedback.
    function updateReferralBonusBp(uint256 _newRefBonusBp) external onlyOwner {
        require(_newRefBonusBp <= MAXIMUM_REFERRAL_BP, "updateRefBonusPercent: invalid referral bonus basis points");
        require(_newRefBonusBp != refBonusBP, "updateRefBonusPercent: same bonus bp set");
        uint256 previousRefBonusBP = refBonusBP;
        refBonusBP = _newRefBonusBp;
        emit ReferralBonusBpChanged(previousRefBonusBP, _newRefBonusBp);
    }

    // Doc: If my calculations are correct, when this baby hits 88 miles per hour, you gonna see some serious shit.
}