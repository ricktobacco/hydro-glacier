# hydrogen-glacier
Snowflakes bearing interest in an escrow forms a Glacier

# Project Details
An Ethereum smart contract on top of Hydro Snowflake that allows a certain percentage of interest on a defined principal amount, in HYDRO, to accrue and be charged (or paid) to a wallet tied to a SnowflakeID, and then for that balance to automatically be withdrawn (or paid). The smart contract will guarantee that the money is in the account by enforcing an escrow of the accruing payment within the wallet, thus eliminating payment default, or fraud from institutions. This utility smart contract will power charging interest in many future savings, lending, credit, and mortgage Hydro dApps. There will be Layer-3 dApps and Layer-4 APIs that hook into this utility smart contract function.

# Background:
* The market for interest bearing notes and accounts is huge globally
* The market for interest paying debt products is even larger globally
* One of the largest problems facing the lending markets is default; in the student loan market alone, 22% of all borrowers default on their payments every year
* From 2009-2017, nearly 500 banks failed in the U.S. costing the FDIC over $75 Billion to make clients whole
* By holding interest from an issuer or borrower in an escrow within a Snowflake, counterparties can eliminate fraud, default, and validate all terms on-chain
# Features:
* Create Interest Rate - et a defined interest rate from 0%-100%
* Set Principal Amount - set the principal amount that the interest will be calculated on
* Define Snowflake IDs - set the Snowflake ID for the payer and the payee
* Accrual - set the accrual date for the interest payments (the default can be daily)
* Payment Schedule - set the payment schedule for the interest payments (the default can be monthly)
* End Date - set the end date, or term, of the payments. For savings the default can be infinite, for loans and credit, the default can be 1 year.
* Escrow - remove the set amount of HYDRO from the SnowflakeID wallet to an escrow contract on the payment schedule intervals, to insure there will be no default
* Send Interest - distribute the interest HYDRO from the escrow on the Payment Schedule date
* Send Principal - in the case of a debt contract, send the principal amount on the contract from the Snowflake ID on the End Date.
* Confirm Payment - use the Hydro Raindrop smart contract to confirm receipt and payment of the interest from the payer to the payee
* Dispute - create a flag for a disputed interest payment
The interest rate, once set, cannot be edited or modified. The terms can be deleted by mutual consent of both parties via a Hydro Raindrop transaction.
