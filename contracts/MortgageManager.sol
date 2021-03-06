pragma solidity ^0.4.19;

import "./interfaces/Token.sol";
import "./interfaces/Cosigner.sol";
import "./interfaces/Engine.sol";
import "./interfaces/ERC721.sol";
import "./utils/SafeWithdraw.sol";
import "./utils/BytesUtils.sol";
import "./interfaces/Oracle.sol";
import "./interfaces/TokenConverter.sol";
import "./ERC721Base.sol";

contract LandMarket {
    struct Auction {
        // Auction ID
        bytes32 id;
        // Owner of the NFT
        address seller;
        // Price (in wei) for the published item
        uint256 price;
        // Time when this sale ends
        uint256 expiresAt;
    }

    mapping (uint256 => Auction) public auctionByAssetId;
    function executeOrder(uint256 assetId, uint256 price) public;
}

contract Land is ERC721 {
    function updateLandData(int x, int y, string data) public;
    function decodeTokenId(uint value) view public returns (int, int);
    function safeTransferFrom(address from, address to, uint256 assetId) public;
    function ownerOf(uint256 landID) public view returns (address);
    function setUpdateOperator(uint256 assetId, address operator) external;
}

/**
    @notice The contract is used to handle all the lifetime of a mortgage, uses RCN for the Loan and Decentraland for the parcels. 

    Implements the Cosigner interface of RCN, and when is tied to a loan it creates a new ERC721 to handle the ownership of the mortgage.

    When the loan is resolved (paid, pardoned or defaulted), the mortgaged parcel can be recovered. 

    Uses a token converter to buy the Decentraland parcel with MANA using the RCN tokens received.
*/
contract MortgageManager is Cosigner, ERC721Base, SafeWithdraw, BytesUtils {
    uint256 constant internal PRECISION = (10**18);
    uint256 constant internal RCN_DECIMALS = 18;

    bytes32 public constant MANA_CURRENCY = 0x4d414e4100000000000000000000000000000000000000000000000000000000;
    uint256 public constant REQUIRED_ALLOWANCE = 1000000000 * 10**18;

    event RequestedMortgage(
        uint256 _id,
        address _borrower,
        address _engine,
        uint256 _loanId,
        address _landMarket,
        uint256 _landId,
        uint256 _deposit,
        address _tokenConverter
    );

    event ReadedOracle(
        address _oracle,
        bytes32 _currency,
        uint256 _decimals,
        uint256 _rate
    );

    event StartedMortgage(uint256 _id);
    event CanceledMortgage(address _from, uint256 _id);
    event PaidMortgage(address _from, uint256 _id);
    event DefaultedMortgage(uint256 _id);
    event UpdatedLandData(address _updater, uint256 _parcel, string _data);
    event SetCreator(address _creator, bool _status);
    event SetEngine(address _engine, bool _status);

    Token public rcn;
    Token public mana;
    Land public land;
    
    constructor(
        Token _rcn,
        Token _mana,
        Land _land
    ) public ERC721Base("Decentraland RCN Mortgage", "LAND-RCN-M") {
        rcn = _rcn;
        mana = _mana;
        land = _land;
        mortgages.length++;
    }

    enum Status { Pending, Ongoing, Canceled, Paid, Defaulted }

    struct Mortgage {
        LandMarket landMarket;
        address owner;
        Engine engine;
        uint256 loanId;
        uint256 deposit;
        uint256 landId;
        uint256 landCost;
        Status status;
        TokenConverter tokenConverter;
    }

    uint256 internal flagReceiveLand;

    Mortgage[] public mortgages;

    mapping(address => bool) public creators;
    mapping(address => bool) public engines;

    mapping(uint256 => uint256) public mortgageByLandId;
    mapping(address => mapping(uint256 => uint256)) public loanToLiability;

    function url() public view returns (string) {
        return "";
    }

    function setEngine(address engine, bool authorized) external onlyOwner returns (bool) {
        emit SetEngine(engine, authorized);
        engines[engine] = authorized;
        return true;
    }

    function setURIProvider(URIProvider _provider) external onlyOwner returns (bool) {
        return _setURIProvider(_provider);
    }

    /**
        @notice Sets a new third party creator
        
        The third party creator can request loans for other borrowers. The creator should be a trusted contract, it could potentially take funds.
    
        @param creator Address of the creator
        @param authorized Enables or disables the permission

        @return true If the operation was executed
    */
    function setCreator(address creator, bool authorized) external onlyOwner returns (bool) {
        emit SetCreator(creator, authorized);
        creators[creator] = authorized;
        return true;
    }

    /**
        @notice Returns the cost of the cosigner

        This cosigner does not have any risk or maintenance cost, so its free.

        @return 0, because it's free
    */
    function cost(address, uint256, bytes, bytes) public view returns (uint256) {
        return 0;
    }

    /**
        @notice Requests a mortgage with a loan identifier

        @dev The loan should exist in the designated engine

        @param engine RCN Engine
        @param loanIdentifier Identifier of the loan asociated with the mortgage
        @param deposit MANA to cover part of the cost of the parcel
        @param landId ID of the parcel to buy with the mortgage
        @param tokenConverter Token converter used to exchange RCN - MANA

        @return id The id of the mortgage
    */
    function requestMortgage(
        Engine engine,
        bytes32 loanIdentifier,
        uint256 deposit,
        LandMarket landMarket,
        uint256 landId,
        TokenConverter tokenConverter
    ) external returns (uint256 id) {
        return requestMortgageId(engine, landMarket, engine.identifierToIndex(loanIdentifier), deposit, landId, tokenConverter);
    }

    /**
        @notice Request a mortgage with a loan id

        @dev The loan should exist in the designated engine

        @param engine RCN Engine
        @param loanId Id of the loan asociated with the mortgage
        @param deposit MANA to cover part of the cost of the parcel
        @param landId ID of the parcel to buy with the mortgage
        @param tokenConverter Token converter used to exchange RCN - MANA

        @return id The id of the mortgage
    */
    function requestMortgageId(
        Engine engine,
        LandMarket landMarket,
        uint256 loanId,
        uint256 deposit,
        uint256 landId,
        TokenConverter tokenConverter
    ) public returns (uint256 id) {
        // Validate the associated loan
        require(engine.getCurrency(loanId) == MANA_CURRENCY, "Loan currency is not MANA");
        address borrower = engine.getBorrower(loanId);

        require(engines[engine], "Engine not authorized");
        require(engine.getStatus(loanId) == Engine.Status.initial, "Loan status is not inital");
        require(
            msg.sender == borrower || (msg.sender == engine.getCreator(loanId) && creators[msg.sender]),
            "Creator should be borrower or authorized"
        );
        require(engine.isApproved(loanId), "Loan is not approved");
        require(rcn.allowance(borrower, this) >= REQUIRED_ALLOWANCE, "Manager cannot handle borrower's funds");
        require(tokenConverter != address(0), "Token converter not defined");
        require(loanToLiability[engine][loanId] == 0, "Liability for loan already exists");

        // Get the current parcel cost
        uint256 landCost;
        (, , landCost, ) = landMarket.auctionByAssetId(landId);
        uint256 loanAmount = engine.getAmount(loanId);

        // the remaining will be sent to the borrower
        require(loanAmount + deposit >= landCost, "Not enought total amount");

        // Pull the deposit and lock the tokens
        require(mana.transferFrom(msg.sender, this, deposit), "Error pulling mana");
        
        // Create the liability
        id = mortgages.push(Mortgage({
            owner: borrower,
            engine: engine,
            loanId: loanId,
            deposit: deposit,
            landMarket: landMarket,
            landId: landId,
            landCost: landCost,
            status: Status.Pending,
            tokenConverter: tokenConverter
        })) - 1;

        loanToLiability[engine][loanId] = id;

        emit RequestedMortgage({
            _id: id,
            _borrower: borrower,
            _engine: engine,
            _loanId: loanId,
            _landMarket: landMarket,
            _landId: landId,
            _deposit: deposit,
            _tokenConverter: tokenConverter
        });
    }

    /**
        @notice Cancels an existing mortgage
        @dev The mortgage status should be pending
        @param id Id of the mortgage
        @return true If the operation was executed

    */
    function cancelMortgage(uint256 id) external returns (bool) {
        Mortgage storage mortgage = mortgages[id];
        
        // Only the owner of the mortgage and if the mortgage is pending
        require(msg.sender == mortgage.owner, "Only the owner can cancel the mortgage");
        require(mortgage.status == Status.Pending, "The mortgage is not pending");
        
        mortgage.status = Status.Canceled;

        // Transfer the deposit back to the borrower
        require(mana.transfer(msg.sender, mortgage.deposit), "Error returning MANA");

        emit CanceledMortgage(msg.sender, id);
        return true;
    }

    /**
        @notice Request the cosign of a loan

        Buys the parcel and locks its ownership until the loan status is resolved.
        Emits an ERC721 to manage the ownership of the mortgaged property.
    
        @param engine Engine of the loan
        @param index Index of the loan
        @param data Data with the mortgage id
        @param oracleData Oracle data to calculate the loan amount

        @return true If the cosign was performed
    */
    function requestCosign(Engine engine, uint256 index, bytes data, bytes oracleData) public returns (bool) {
        // The first word of the data MUST contain the index of the target mortgage
        Mortgage storage mortgage = mortgages[uint256(readBytes32(data, 0))];
        
        // Validate that the loan matches with the mortgage
        // and the mortgage is still pending
        require(mortgage.engine == engine, "Engine does not match");
        require(mortgage.loanId == index, "Loan id does not match");
        require(mortgage.status == Status.Pending, "Mortgage is not pending");
        require(engines[engine], "Engine not authorized");

        // Update the status of the mortgage to avoid reentrancy
        mortgage.status = Status.Ongoing;

        // Mint mortgage ERC721 Token
        _generate(uint256(readBytes32(data, 0)), mortgage.owner);

        // Transfer the amount of the loan in RCN to this contract
        uint256 loanAmount = convertRate(engine.getOracle(index), engine.getCurrency(index), oracleData, engine.getAmount(index));
        require(rcn.transferFrom(mortgage.owner, this, loanAmount), "Error pulling RCN from borrower");
        
        // Convert the RCN into MANA using the designated
        // and save the received MANA
        uint256 boughtMana = convertSafe(mortgage.tokenConverter, rcn, mana, loanAmount);
        delete mortgage.tokenConverter;

        // Load the new cost of the parcel, it may be changed
        uint256 currentLandCost;
        (, , currentLandCost, ) = mortgage.landMarket.auctionByAssetId(mortgage.landId);
        require(currentLandCost <= mortgage.landCost, "Parcel is more expensive than expected");
        
        // Buy the land and lock it into the mortgage contract
        require(mana.approve(mortgage.landMarket, currentLandCost), "Error approving mana transfer");
        flagReceiveLand = mortgage.landId;
        mortgage.landMarket.executeOrder(mortgage.landId, currentLandCost);
        require(mana.approve(mortgage.landMarket, 0), "Error removing approve mana transfer");
        require(flagReceiveLand == 0, "ERC721 callback not called");
        require(land.ownerOf(mortgage.landId) == address(this), "Error buying parcel");

        // Set borrower as update operator
        land.setUpdateOperator(mortgage.landId, mortgage.owner);

        // Calculate the remaining amount to send to the borrower and 
        // check that we didn't expend any contract funds.
        uint256 totalMana = boughtMana.add(mortgage.deposit);        
        uint256 rest = totalMana.sub(currentLandCost);

        // Return rest of MANA to the owner
        require(mana.transfer(mortgage.owner, rest), "Error returning MANA");
        
        // Cosign contract, 0 is the RCN required
        require(mortgage.engine.cosign(index, 0), "Error performing cosign");
        
        // Save mortgage id registry
        mortgageByLandId[mortgage.landId] = uint256(readBytes32(data, 0));

        // Emit mortgage event
        emit StartedMortgage(uint256(readBytes32(data, 0)));

        return true;
    }

    /**
        @notice Converts tokens using a token converter
        @dev Does not trust the token converter, validates the return amount
        @param converter Token converter used
        @param from Tokens to sell
        @param to Tokens to buy
        @param amount Amount to sell
        @return bought Bought amount
    */
    function convertSafe(
        TokenConverter converter,
        Token from,
        Token to,
        uint256 amount
    ) internal returns (uint256 bought) {
        require(from.approve(converter, amount), "Error approve convert safe");
        uint256 prevBalance = to.balanceOf(this);
        bought = converter.convert(from, to, amount, 1);
        require(to.balanceOf(this).sub(prevBalance) >= bought, "Bought amount incorrect");
        require(from.approve(converter, 0), "Error remove approve convert safe");
    }

    /**
        @notice Claims the mortgage when the loan status is resolved and transfers the ownership of the parcel to which corresponds.

        @dev Deletes the mortgage ERC721

        @param engine RCN Engine
        @param loanId Loan ID
        
        @return true If the claim succeded
    */
    function claim(address engine, uint256 loanId, bytes) external returns (bool) {
        uint256 mortgageId = loanToLiability[engine][loanId];
        Mortgage storage mortgage = mortgages[mortgageId];

        // Validate that the mortgage wasn't claimed
        require(mortgage.status == Status.Ongoing, "Mortgage not ongoing");
        require(mortgage.loanId == loanId, "Mortgage don't match loan id");

        if (mortgage.engine.getStatus(loanId) == Engine.Status.paid || mortgage.engine.getStatus(loanId) == Engine.Status.destroyed) {
            // The mortgage is paid
            require(_isAuthorized(msg.sender, mortgageId), "Sender not authorized");

            mortgage.status = Status.Paid;
            // Transfer the parcel to the borrower
            land.safeTransferFrom(this, msg.sender, mortgage.landId);
            emit PaidMortgage(msg.sender, mortgageId);
        } else if (isDefaulted(mortgage.engine, loanId)) {
            // The mortgage is defaulted
            require(msg.sender == mortgage.engine.ownerOf(loanId), "Sender not lender");
            
            mortgage.status = Status.Defaulted;
            // Transfer the parcel to the lender
            land.safeTransferFrom(this, msg.sender, mortgage.landId);
            emit DefaultedMortgage(mortgageId);
        } else {
            revert("Mortgage not defaulted/paid");
        }

        // Delete mortgage id registry
        delete mortgageByLandId[mortgage.landId];

        return true;
    }

    /**
        @notice Defines a custom logic that determines if a loan is defaulted or not.

        @param engine RCN Engines
        @param index Index of the loan

        @return true if the loan is considered defaulted
    */
    function isDefaulted(Engine engine, uint256 index) public view returns (bool) {
        return engine.getStatus(index) == Engine.Status.lent &&
            engine.getDueTime(index).add(7 days) <= block.timestamp;
    }

    /**
        @dev An alternative version of the ERC721 callback, required by a bug in the parcels contract
    */
    function onERC721Received(uint256 _tokenId, address, bytes) external returns (bytes4) {
        if (msg.sender == address(land) && flagReceiveLand == _tokenId) {
            flagReceiveLand = 0;
            return bytes4(keccak256("onERC721Received(address,uint256,bytes)"));
        }
    }

    /**
        @notice Callback used to accept the ERC721 parcel tokens

        @dev Only accepts tokens if flag is set to tokenId, resets the flag when called
    */
    function onERC721Received(address, uint256 _tokenId, bytes) external returns (bytes4) {
        if (msg.sender == address(land) && flagReceiveLand == _tokenId) {
            flagReceiveLand = 0;
            return bytes4(keccak256("onERC721Received(address,uint256,bytes)"));
        }
    }

    /**
        @notice Last callback used to accept the ERC721 parcel tokens

        @dev Only accepts tokens if flag is set to tokenId, resets the flag when called
    */
    function onERC721Received(address, address, uint256 _tokenId, bytes) external returns (bytes4) {
        if (msg.sender == address(land) && flagReceiveLand == _tokenId) {
            flagReceiveLand = 0;
            return bytes4(0x150b7a02);
        }
    }

    /**
        @dev Reads data from a bytes array
    */
    function getData(uint256 id) public pure returns (bytes o) {
        assembly {
            o := mload(0x40)
            mstore(0x40, add(o, and(add(add(32, 0x20), 0x1f), not(0x1f))))
            mstore(o, 32)
            mstore(add(o, 32), id)
        }
    }
    
    /**
        @notice Enables the owner of a parcel to update the data field

        @param id Id of the mortgage
        @param data New data

        @return true If data was updated
    */
    function updateLandData(uint256 id, string data) external returns (bool) {
        require(_isAuthorized(msg.sender, id), "Sender not authorized");
        (int256 x, int256 y) = land.decodeTokenId(mortgages[id].landId);
        land.updateLandData(x, y, data);
        emit UpdatedLandData(msg.sender, id, data);
        return true;
    }

    /**
        @dev Replica of the convertRate function of the RCN Engine, used to apply the oracle rate
    */
    function convertRate(Oracle oracle, bytes32 currency, bytes data, uint256 amount) internal returns (uint256) {
        if (oracle == address(0)) {
            return amount;
        } else {
            (uint256 rate, uint256 decimals) = oracle.getRate(currency, data);
            emit ReadedOracle(oracle, currency, decimals, rate);
            require(decimals <= RCN_DECIMALS, "Decimals exceeds max decimals");
            return amount.mult(rate.mult(10**(RCN_DECIMALS-decimals))) / PRECISION;
        }
    }

    //////
    // Override transfer
    //////
    function _doTransferFrom(
        address _from,
        address _to,
        uint256 _assetId,
        bytes _userData,
        bool _doCheck
    )
        internal
    {
        ERC721Base._doTransferFrom(_from, _to, _assetId, _userData, _doCheck);
        land.setUpdateOperator(mortgages[_assetId].landId, _to);
    }
}
