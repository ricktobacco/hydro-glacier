pragma solidity >=0.4.0 <0.6.0;

import "./Escrow.sol";
import "./SnowflakeResolver.sol";
import "./interfaces/IdentityRegistryInterface.sol";
import "./interfaces/HydroInterface.sol";
import "./interfaces/SnowflakeInterface.sol";
import "./zeppelin/math/SafeMath.sol";

/**
 * @title Glacier
 * @notice Create interest-bearing escrow through Snowflake
 * @dev This contract is the base of the Hydro-Glacier dApp
 */

contract Glacier is SnowflakeResolver
{   
    /* Constants based on the following
     * average blocktime = 15.634 secs;
     * average days per month = 30.438;
     * average weeks per month = 4.34;
    */
    uint constant blocksPerDay = 5526; //(60/15.634)*60*24
    uint constant blocksPerWeek = 38685; //(60/15.634)*60*24*7
    uint constant blocksPerMonth = 168210; //(60/15.634)*60*24*(365.25/12)
    uint constant blocksPerYear = 2018524; //(60/15.634)*60*24*(365.25)

    enum Schedule { 
        Hourly, Daily, Weekly,
        Fortnightly, Monthly, 
        Quadannually, Triannually, 
        Biannually, Annually, 
        Biennially, Triennially, 
        Quadrennially 
    } 
    enum Status { Created, Locked, Repaid, Inactive }
    
    uint256 public debtIndex;

    /* for each seller of debt (payee), easily look up
     * any of their debts through the id of the debt
    */ 
    mapping (uint256 => mapping(uint256 => Debt)) debts;

    /* for given debt id return the address of the payee
     * who owns the debt: in a loan this is the lender, 
     * in savings this is the depositor 
    */ 
    mapping (uint256 => uint256) debtToPayee;
    // for given debt id return the address of the Escrow
    mapping (uint256 => address) debtToEscrow;

    // We keep track of the payments here (debtId => ein => amount)
    mapping (uint256 => mapping (uint256 => uint256)) public payments;
    // We keep track of the refunds here (debtId => ein => amount)
    mapping (uint256 => mapping (uint256 => uint256)) public refunds;

    struct Debt { //accured interest book-keeping component
        uint256  id;
        Status   status;
        uint     created; // block number of when created
        
        Schedule payments; // scheduled interest payments
        uint     nextPayment; // block number for next payment
        uint256  numPayments; // the number of payments to be made until endDate
        uint256  numEscrowed; // the number of payments that must be escrowed
        uint256  payInterval; // the number of blocks between payments
        
        Schedule accruals; // scheduled interest accrual
        uint     nextAccrual; // block number for next accrual 
        uint     numAccruals; 
        uint256  accrualInterval; // the number of blocks between accruals

        /* may grow via compound interest or direct deposit,
         * but not be depleted without termination 
        */ 
        uint256  principal;

        /* the cost of debt expressed in absolute terms; ie the
         * amount which payer must lock up in escrow for payee
         * to release their principal 
        */ 
        uint256  interest;

        /* the buyer of debt; 
         * in a loan this is the borrower,
         * in savings this is the lender
        */ 
        uint256  payer; 

        /* prevents spam-like misuse of the Glacier:
         * for loans it's the "order cost" of the debt, 
         * as a percentage of the principal;
         * so for savings it's the cost of withdrawal 
        */ 
        uint256  fee;
        
        /* the cost of debt expressed in annual percentage yield;
         * paid either to lender (when loaning) or depositor (when saving)
        */ 
        uint256  apr;

        /* also an instance of schedule.
         * 
        */
        uint256  expire;

        
        bool principalOwed; 
    }

    event InterestPaid( 
        uint256 indexed payee,
        uint256 indexed debtID,
        uint256 amount
    );
    event MissedPayment(
        uint256 indexed payer,
        uint256 indexed debtID,
        uint256 amount
    );

    /* at this initial point in the debt's lifecycle, the debt
     * becomes irreversibly linked to an escrow, whose state may
     * change based on the following activity related to the debt
    */ 
    event LockInterest(
        uint256 indexed payer, 
        uint256 indexed debtID, 
        uint256 amount
    );

    /* there are two situations where this may occur:
     * payer and payee both accept the transaction, the payee gets paid;
     * payer and payee agree to cancel the transaction,
     * payer's principal is instantly refunded
    */ 
    event ReleasePrincipal(
        uint256 indexed payee,
        uint256 indexed debtID,
        uint256 amount
    );

    /* the payer or the payee may have changes,
     * or the terms of the contract (accrual/payment schedule)
    */ 
    event Rearrangement(
        uint256 indexed payee,
        uint256 indexed debtID
    );

    constructor (address snowflakeAddress) public 
    SnowflakeResolver("Glacier", "Interest-bearing Escrow on Snowflake", 
    snowflakeAddress, false, false) { debtIndex = 0; }

    /**
     * @dev Create ledger entry for debt 
     * @param interest the APR for the debt
     * ^ once set, cannot be edited or modified.
     * defaults for other debt parameters are: 
     * accrual daily, payment monthly, infinite end date,
     * half a percent origination fee 
     */
    function setInterest(
        uint256 rate,
        uint256 fee
    ) public {
        SnowflakeInterface snowflake = SnowflakeInterface(snowflakeAddress);
        IdentityRegistryInterface identityRegistry = IdentityRegistryInterface(snowflake.identityRegistryAddress());

        uint256 ein = identityRegistry.getEIN(msg.sender);
        require(identityRegistry.isResolverFor(ein, address(this)), "The EIN has not set this resolver.");

        debtIndex += 1;

        Debt memory debt = Debt(
            debtIndex, Status.Created, now,
            Schedule.Monthly, 0, // payments: when, how many, next date
            Schedule.Daily, 0, // accruals: when, how many, next date,
            0, 0, 0, fee, // principal, interest, payer EIN, fee
            rate, 2**256-1, //annual percentage rate, expriation
            false
        );
        debts[ein][debtIndex] = debt;
        debtToPayee[debtIndex] = ein;
    }

    /**
     * @dev Set principal amount
     * @param debtId id of the debt
     * @param amount of the principle to put
     * Upon debt issuance, collateral tokens
     * are locked in escrow. 
     * Effectively borrower is buying back those tokens. 
     * If borrower is unable to buy back token at a 
     * scheduled time, lender will repossess tokens
     * worth that missed payment providing better 
     * breathing space in tough times.
     */
    function lockPrincipal(
        uint256 debtId,
        uint256 amount
    ) public payable {
        SnowflakeInterface snowflake = SnowflakeInterface(snowflakeAddress);
        IdentityRegistryInterface identityRegistry = IdentityRegistryInterface(snowflake.identityRegistryAddress());

        uint256 ein = identityRegistry.getEIN(msg.sender);
        require(identityRegistry.isResolverFor(ein, address(this)), "The EIN has not set this resolver.");
        require(ein == debtToPayee[debtId], "must be the payee");
        
        Debt memory debt = debts[debtToPayee[debtId]][debtId];
        require(!debt.owed == debtToPayee[debtId], "cannot lock more principal after it was released");
        
        //escrowed balances are gathered from calls to withdrawSnowflakeBalanceFrom with
        //address of the resolver smart contract as the to address.
        snowflake.withdrawSnowflakeBalanceFrom(ein, address(this), amount);
        
        debt.principal += amount;
        debt.interest = (debt.principal * debt.apr);
        debts[debtToPayee[debtId]][debtId] = debt;
        
        //snowflake.transferSnowflakeBalanceFrom(ein, debt.payee, amount);            
    }

    function getBlockInterval(uint _schedule) returns (uint256) {
        uint256 interval = 0;
        if (_schedule == Schedule.Hourly)             interval = blocksPerDay / 24;
        else if (_schedule == Schedule.Daily)         interval = blocksPerDay;
        else if (_schedule == Schedule.Weekly)        interval = blocksPerWeek;
        else if (_schedule == Schedule.Fortnightly)   interval = blocksPerWeek * 2;
        else if (_schedule == Schedule.Monthly)       interval = blocksPerMonth;
        else if (_schedule == Schedule.Quadannually)  interval = blocksPerYear / 4;
        else if (_schedule == Schedule.Triannually)   interval = blocksPerMonth * 4;
        else if (_schedule == Schedule.Biannually)    interval = blocksPerYear / 2;
        else if (_schedule == Schedule.Annually)      interval = blocksPerYear;
        else if (_schedule == Schedule.Biennially)    interval = blocksPerYear * 2;
        else if (_schedule == Schedule.Triennially)   interval = blocksPerYear * 3;
        else if (_schedule == Schedule.Quadrennially) interval = blocksPerYear * 4;
        require(interval, "incomprehensible schedule");
        return interval;
    }

    /**
     * @dev Set the Accrual Schedule
     * @param debtId the id of the debt
     * @param _accrual the Schedule enum
     */
    function setAccrual(
        uint256 debtId,
        uint _accrual
    ) public {
        SnowflakeInterface snowflake = SnowflakeInterface(snowflakeAddress);
        IdentityRegistryInterface identityRegistry = IdentityRegistryInterface(snowflake.identityRegistryAddress());

        uint256 ein = identityRegistry.getEIN(msg.sender);
        require(identityRegistry.isResolverFor(ein, address(this)), "The EIN has not set this resolver.");

        uint256 payee = debtToPayee[debtId];
        require(ein == payee, "only payee can change accrual schedule");
        
        //TODO: can do after owed = true, with Raindrop
        Debt memory debt = debts[payee][debtId];
        require(!debt.owed, "cannot change payment schedule after principal released");
        
        debt.accrualInterval = getBlockInterval(_accrual);
        debt.accruals = Schedule(_accrual);
        debts[debtToPayee[debtId]][debtId] = debt;
    }

    /**
     * @dev Set the Payment Schedule, to be signed via Raindrop,
     * determining how often interest payments are made to payee
     * @param debtId The id of the invoice
     * @param customers The updated customers list
     */
    function setPayment(
        uint256 debtId,
        uint _payment
    ) public {
        SnowflakeInterface snowflake = SnowflakeInterface(snowflakeAddress);
        IdentityRegistryInterface identityRegistry = IdentityRegistryInterface(snowflake.identityRegistryAddress());

        uint256 ein = identityRegistry.getEIN(msg.sender);
        require(identityRegistry.isResolverFor(ein, address(this)), "The EIN has not set this resolver.");

        uint256 payee = debtToPayee[debtId];
        require(ein == payee, "only payee can change payment schedule");
        
        //TODO: can do after owed = true, with Raindrop
        Debt memory debt = debts[payee][debtId]; 
        require(!debt.owed, "cannot change payment schedule after principal released");

        debt.payInterval = getBlockInterval(_payment);
        debt.payments = Schedule(_payment);
        debts[debtToPayee[debtId]][debtId] = debt;
    }

    /**
     * @dev Set the End date when principal should be sent back to payer
     * @param debtId the id of the debt
     */
    function setDeadline(
        uint256 debtId,
    ) public {
        
    }

    /** 
     * @dev Set principal amount, creating an escrow
     * @param debtId id of the debt
     * @param amount of the principle to put
     * Upon debt issuance, collateral tokens
     * are locked in escrow. 
     * Effectively borrower is buying back those tokens. 
     * If borrower is unable to buy back token at a 
     * scheduled time, lender will repossess tokens
     * worth that missed payment providing better 
     * breathing space in tough times.
     */
    function lockInterest(
        uint256 debtId,
        uint256 amount
    ) public payable {
        SnowflakeInterface snowflake = SnowflakeInterface(snowflakeAddress);
        IdentityRegistryInterface identityRegistry = IdentityRegistryInterface(snowflake.identityRegistryAddress());

        uint256 ein = identityRegistry.getEIN(msg.sender);
        require(identityRegistry.isResolverFor(ein, address(this)), "The EIN has not set this resolver.");
        
        uint256 payee = debtToPayee[debtId];
        Debt memory debt = debts[payee][debtId];
        require(!debt.owed, "cannot lock more interest after principal was released");

        if (debt.payer == 0) {
            require(ein != payee, "payer cannot be the payee");
            debt.payer = ein;
        } else 
            require(ein == debt.payer, "payer cannot be the payee");
        
        uint256 newInterest = debt.interestLocked + amount;

        if (debt.interest == newInterest) {
            withdrawHydroBalanceTo(msg.sender, debt.principal);
            debt.nextAccrual = now + debt.accrueInterval;
            debt.nextPayment = now + debt.payInterval;
            debt.owed = true;
        }
        else {
            require(debt.interest > newInterest, "cannot lock more interest than due");
            snowflake.withdrawSnowflakeBalanceFrom(ein, address(this), amount);    
        }
        debt.lockedInterest = newInterest;
        debts[payee][debtId] = debt;
    }

    /** 
     * @dev Set principal amount, creating an escrow
     * @param debtId id of the debt
     * @param amount of the principle to put
     * Upon debt issuance, collateral tokens
     * are locked in escrow. 
     * Effectively borrower is buying back those tokens. 
     * If borrower is unable to buy back token at a 
     * scheduled time, lender will repossess tokens
     * worth that missed payment providing better 
     * breathing space in tough times.
     */
    function payInterest(
        uint256 debtId,
        uint256 amount
    ) public payable {
        SnowflakeInterface snowflake = SnowflakeInterface(snowflakeAddress);
        IdentityRegistryInterface identityRegistry = IdentityRegistryInterface(snowflake.identityRegistryAddress());

        uint256 ein = identityRegistry.getEIN(msg.sender);
        require(identityRegistry.isResolverFor(ein, address(this)), "The EIN has not set this resolver.");
        
        uint256 payee = debtToPayee[debtId];
        require(ein == payee, "only payee can change payment schedule");

        Debt memory debt = debts[payee][debtId];
        require(debt.owed, "cannot lock more interest after principal was released");
        require(now >= debt.nextPayment && now <= debt.nextPayment + 20, "payment too early/late");
        
        //calculate accrued interest
        //uint n = blocksPerYear / debt.accrualInterval;
        //debt.principal * (1+debt.apr/n)^n
        
        require(debt.accrued >= amount, "payee cannot withdraw more interest than accrued");
    
        withdrawHydroBalanceTo(msg.sender, amount);
        debt.accrued -= amount;
        debt.nextPayment += debt.payInterval;
       
        debts[payee][debtId] = debt;
    }

    
    /**
     * @dev Set the payer and payee attributes
     * @param debtId the id of the debt
     * @param payer the new payer
     * @param payee the new payee
     */
    // function setMembers(
    //     uint256 invoiceId,
    // ) public {
    //     //require hasIdentity(address _address)
    //     //getEIN(address _address)
    // }

    /**
     * @dev Dispute terms
     * @param debtId the id of the debt
     */
    // function dispute(
    //     uint256 debtId,
    // ) public {

    // }

    // function release() {
        //withdrawHydroBalanceTo
    //}
       
    // function repay() {
        SnowflakeInterface snowflake = SnowflakeInterface(snowflakeAddress);
        IdentityRegistryInterface identityRegistry = IdentityRegistryInterface(snowflake.identityRegistryAddress());
        
        bytes memory snowflakeCallData;
        string memory functionSignature = "function processTransaction(address, uint, uint, uint, uint)";
        snowflakeCallData = abi.encodeWithSelector(bytes4(keccak256(bytes(functionSignature))), address(this), identityRegistry.getEIN(approvingAddress), ownerEIN(), itemListings[id].price, couponID);

        //Any Resolver maintaining a HYDRO token balance may call transferHydroBalanceTo with a target EIN and an amount to send HYDRO to an EIN.


// function transferSnowflakeBalanceFromVia(uint einFrom, address via, uint einTo, uint amount, bytes memory _bytes)

        snowflake.transferSnowflakeBalanceFromVia(identityRegistry.getEIN(approvingAddress), _MarketplaceCouponViaAddress, ownerEIN(), itemListings[id].price, snowflakeCallData);
    // }

}
