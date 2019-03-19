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
    uint constant blocksPerYear = 2102400;

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

    struct Debt {
        uint256  id;
        Status   status;
        uint     created; // block number of when created
        
        Schedule payments; // scheduled interest payments
        uint     nextPayment; // block number for next payment
        
        Schedule accruals; // scheduled interest accrual
        uint     nextAccrual; // block number for next accrual 
        
        /* may grow via compound interest or direct deposit,
         * but not be depleted without termination 
        */ 
        uint256  principal;

        /* the cost of debt expressed in annual percentage yield;
         * paid either to lender (when loaning) or depositor (when saving)
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

        uint256  expire;
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
    event LockPrincipal(
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
        uint256 indexed payer,
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
    SnowflakeResolver("Glacier", "Create interest-bearing escrow", 
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
        uint256 interest
    ) public {
        SnowflakeInterface snowflake = SnowflakeInterface(snowflakeAddress);
        IdentityRegistryInterface identityRegistry = IdentityRegistryInterface(snowflake.identityRegistryAddress());

        uint256 ein = identityRegistry.getEIN(msg.sender);
        require(identityRegistry.isResolverFor(ein, address(this)), "The EIN has not set this resolver.");

        debtIndex += 1;
        Debt memory debt = Debt(
            debtIndex, Status.Created, now,
            Schedule.Monthly, 0, // payment schedule, next date
            Schedule.Daily, 0, // accrual schedule, next date
            0, interest, // principal, interest
            0, 1, 2**256-1 //payer EIN, fee (TODO), expriation
        );
        debts[ein][debtIndex] = debt;
        debtToPayee[debtIndex] = ein;
    }

    /**
     * @dev Set principal amount, creating an escrow
     * @param debtId id of the debt
     * @param amount of the principle to put
     */
    function putPrincipal(
        uint256 debtId
    ) public payable {
        SnowflakeInterface snowflake = SnowflakeInterface(snowflakeAddress);
        IdentityRegistryInterface identityRegistry = IdentityRegistryInterface(snowflake.identityRegistryAddress());

        uint256 ein = identityRegistry.getEIN(msg.sender);
        require(identityRegistry.isResolverFor(ein, address(this)), "The EIN has not set this resolver.");

        Debt memory debt = debts[debtToPayee[debtId]][debtId];
        if (debt.payer == 0){
            require(ein != debtToPayee[debtId], "payer cannot also be the payee");
            debt.payer = ein;
        } else  
            require(debt.payer == ein, "only payer can put principal");

        debt.payer = ein;
        debt.status = Status.Locked;
        debts[debtToPayee[debtId]][debtId] = debt;
        //Escrow escrow = (new Escrow).value(msg.value)(debtId, msg.sender, debtToPayee[debtId]);
        //debtToEscrow[debtId] = escrow;
        //snowflake.transferSnowflakeBalanceFrom(ein, invoices[invoiceId].merchant, amount);
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
        
        Debt memory debt = debts[payee][debtId]; //TODO: can do, with Raindrop
        require(debt.payer == 0, "cannot change schedule while engaged");

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
        
        Debt memory debt = debts[payee][debtId]; //TODO: can do, with Raindrop
        require(debt.payer == 0, "cannot change schedule while engaged");

        debt.payments = Schedule(_payment);
        debts[debtToPayee[debtId]][debtId] = debt;
    }

     /**
     * @dev Set the End date when principal should be sent back to payer
     * @param debtId the id of the debt
     */
    // function setDeadline(
    //     uint256 debtId,
    // ) public {

    // }
    
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

    // function repay() {
        
    // }


}