pragma solidity 0.6.0;

import "../Lib/SafeMath.sol";
import "../Lib/AddressPayable.sol";
import "../Lib/SafeERC20.sol";

/**
 * @title 报价合约
 * @dev 报价 +吃单 +nest分配
 */
contract Nest_3_OfferMain {
    using SafeMath for uint256;
    using address_make_payable for address;
    using SafeERC20 for ERC20;
    
    struct Nest_3_OfferPriceData {
        // 唯一标识通过报价单在数组中的位置确定，通过固定的算法（toIndex(), toAddress()）来互相转化
        
        address owner;                                  //  报价单拥有者
        bool deviate;                                   //  是否偏离
        address tokenAddress;                           //  目标报价token的ERC20合约地址
        uint32 delayedBlock;                            //  生效间隔区块
        
        uint256 ethAmount;                              //  报价单中的eth资产账本
        uint256 tokenAmount;                            //  报价单中的token资产账本
        
        uint256 dealEthAmount;                          //  剩余可成交eth数量
        uint256 dealTokenAmount;                        //  剩余可成交token数量
        
        uint256 blockNum;                               //  报价单所在的区块编号
        uint256 serviceCharge;                          //  用于挖矿的手续费
        
        // 通过判断ethAmount、tokenAmount、serviceCharge都为0来确定是否已经领取资产
    }
    
    Nest_3_OfferPriceData [] _prices;                   //  用于保存报价单的数组

    mapping(address => bool) _tokenAllow;               //  可报价挖矿token
    Nest_3_VoteFactory _voteFactory;                    //  投票合约
    Nest_3_OfferPrice _offerPrice;                      //  价格合约
    Nest_3_MiningContract _miningContract;              //  挖矿合约
    Nest_NodeAssignment _NNcontract;                    //  守护者节点合约
    ERC20 _nestToken;                                  //  nestToken
    address _abonusAddress;                             //  分红池
    address _coderAddress;                              //  开发者地址
    uint256 _miningETH = 10;                            //  报价挖矿手续费挖矿比例，千分10
    uint256 _tranEth = 2;                               //  吃单手续费比例，千分2
    uint256 _tranAddition = 2;                          //  交易加成
    uint256 _offerEthLimit = 1000 ether;                //  单次报价上限
    uint256 _coderAmount = 5;                           //  开发者比例
    uint256 _NNAmount = 15;                             //  守护者节点比例
    uint256 _otherAmount = 80;                          //  可分配比例
    uint256 _leastEth = 10 ether;                       //  最少报价eth
    uint256 _offerSpan = 1 ether;                       //  报价eth跨度
    uint256 _deviate = 10;                              //  价格偏差 10%
    uint256 _deviationFromScale = 10;                   //  偏离资产规模
    uint32 _delayed = 100;                              //  延时区块
    uint32 _delayedAgain = 50;                          //  多次偏离延时区块
    uint32 _blockLimit = 25;                            //  区块间隔上限
    mapping(uint256 => uint256) _offerBlockEth;         //  区块报价手续费
    mapping(uint256 => uint256) _offerBlockMining;      //  区块挖矿量用户所得
    
    //  log,报价合约, token地址,eth数量,erc20数量
    event OfferContractAddress(address contractAddress, address tokenAddress, uint256 ethAmount, uint256 erc20Amount);
    //  log交易，交易发起人，交易token地址，交易token数量，买进token地址，买进token数量，被交易报价合约地址，被交易用户地址
    event OfferTran(address tranSender, address tranToken, uint256 tranAmount,address otherToken, uint256 otherAmount, address tradedContract, address tradedOwner);        
    
     /**
    * @dev 初始化方法
    * @param voteFacory 投票合约地址
    */
    constructor (address voteFacory) public {
        _voteFactory = Nest_3_VoteFactory(voteFacory); 
        _offerPrice = Nest_3_OfferPrice(address(_voteFactory.checkAddress("nest.v3.offerPrice")));            
        _miningContract = Nest_3_MiningContract(address(_voteFactory.checkAddress("nest.v3.miningSave")));
        _abonusAddress = _voteFactory.checkAddress("nest.v3.abonus");
        _nestToken = ERC20(_voteFactory.checkAddress("nest"));                                         
        _NNcontract = Nest_NodeAssignment(address(_voteFactory.checkAddress("nodeAssignment")));      
        _coderAddress = _voteFactory.checkAddress("nest.v3.coder");
    }
    
     /**
    * @dev 重置投票合约
    * @param voteFacory 投票合约地址
    */
    function changeMapping(address voteFacory) public onlyOwner {
        _voteFactory = Nest_3_VoteFactory(voteFacory); 
        _offerPrice = Nest_3_OfferPrice(address(_voteFactory.checkAddress("nest.v3.offerPrice")));            
        _miningContract = Nest_3_MiningContract(address(_voteFactory.checkAddress("nest.v3.miningSave")));
        _abonusAddress = _voteFactory.checkAddress("nest.v3.abonus");
        _nestToken = ERC20(_voteFactory.checkAddress("nest"));                                           
        _NNcontract = Nest_NodeAssignment(address(_voteFactory.checkAddress("nodeAssignment")));      
        _coderAddress = _voteFactory.checkAddress("nest.v3.coder");
    }
    
    /**
    * @dev 报价挖矿
    * @param ethAmount 报价 eth数量
    * @param erc20Amount 报价 erc20数量
    * @param erc20Address 报价 erc20地址
    */
    function offer(uint256 ethAmount, uint256 erc20Amount, address erc20Address) public payable {
        require(address(msg.sender) == address(tx.origin), "It can't be a contract");
        require(ethAmount <= _offerEthLimit, "Over offer limit");
        require(_tokenAllow[erc20Address], "Token not allow");
        //  判断价格是否偏离
        uint256 ethMining;
        bool isDeviate = comparativePrice(ethAmount,erc20Amount,erc20Address);
        uint32 delayedBlock;
        if (isDeviate) {
            delayedBlock = _delayed;
            require(ethAmount >= _leastEth.mul(_deviationFromScale), "EthAmount needs to be no less than 10 times of the minimum scale");
            ethMining = _leastEth.mul(_miningETH).div(1000);
        } else {
            delayedBlock = _blockLimit;
            ethMining = ethAmount.mul(_miningETH).div(1000);
        }
        require(msg.value == ethAmount.add(ethMining), "msg.value needs to be equal to the quoted eth quantity plus Mining handling fee");
        //  创建报价单
        createOffer(ethAmount, erc20Amount, erc20Address, ethMining, delayedBlock, isDeviate);
        // 转入报价资产erc20-交易资产到当前合约
        ERC20(erc20Address).safeTransferFrom(address(msg.sender), address(this), erc20Amount);
        //  挖矿
        uint256 miningAmount = _miningContract.oreDrawing.value(ethMining)();
        if (miningAmount > 0) {
            uint256 coder = miningAmount.mul(_coderAmount).div(100);
            uint256 NN = miningAmount.mul(_NNAmount).div(100);
            uint256 other = miningAmount.mul(_otherAmount).div(100);
            _offerBlockMining[block.number] = other;
            require(_nestToken.approve(address(_NNcontract), NN), "Authorization failed");
            _NNcontract.bookKeeping(NN);                                               
            _nestToken.safeTransfer(_coderAddress, coder);
        }
        _offerBlockEth[block.number] = _offerBlockEth[block.number].add(ethMining);
    }
    
    /**
    * @dev 生成报价单
    * @param ethAmount 报价 eth数量
    * @param erc20Amount 报价 erc20数量
    * @param erc20Address 报价 erc20地址
    * @param mining 报价挖矿手续费（吃单为 0）
    * @param delayedBlock 当前报价结束区块 
    * @param isDeviate 当前价格链是否偏离
    */
    function createOffer(uint256 ethAmount, uint256 erc20Amount, address erc20Address, uint256 mining, uint32 delayedBlock, bool isDeviate) private {
        // 检查报价条件
        require(ethAmount >= _leastEth, "Eth scale is smaller than the minimum scale");
        require(ethAmount % _offerSpan == 0, "Non compliant asset span");
        require(erc20Amount % (ethAmount.div(_offerSpan)) == 0, "Asset quantity is not divided");
        // 创建报价合约
        emit OfferContractAddress(toAddress(_prices.length), address(erc20Address), ethAmount, erc20Amount);
        _prices.push(Nest_3_OfferPriceData(
            
            msg.sender,
            isDeviate,
            erc20Address,
            delayedBlock,
            
            ethAmount,
            erc20Amount,
                           
            ethAmount, 
            erc20Amount, 
              
            block.number, 
            mining
            
        )); 
        // 记录价格
        _offerPrice.addPrice(ethAmount, erc20Amount, block.number.add(delayedBlock), erc20Address);
    }
    
    /**
    * @dev 吃单-支出ETH 买入ERC20
    * @param ethAmount 本次报价 eth数量
    * @param tokenAmount 本次报价 erc20数量
    * @param contractAddress 吃单目标地址
    * @param tranEthAmount 吃单交易 eth数量
    * @param tranTokenAmount 吃单交易 erc20数量
    * @param tranTokenAddress 吃单交易 erc20地址
    */
    function sendEthBuyErc(uint256 ethAmount, uint256 tokenAmount, address contractAddress, uint256 tranEthAmount, uint256 tranTokenAmount, address tranTokenAddress) public payable {
        // 获取报价单数据结构
        uint256 index = toIndex(contractAddress);
        Nest_3_OfferPriceData storage offerPriceData = _prices[index]; 
        //  检测价格, 当前报价对比上一个有效价格
        bool thisDeviate = comparativePrice(ethAmount,tokenAmount,tranTokenAddress);
        bool isDeviate;
        uint32 delayedBlock;
        if (offerPriceData.deviate == true) {
            isDeviate = true;
        } else {
            isDeviate = thisDeviate;
        }
        // 限制吃单报价每次只能是吃单规模的两倍，防止大额攻击
        if (offerPriceData.deviate) {
            //  被吃单偏离 x2 50
            require(ethAmount >= tranEthAmount.mul(_tranAddition), "EthAmount needs to be no less than 2 times of transaction scale");
            delayedBlock = _delayedAgain;
        } else {
            if (isDeviate) {
                //  被吃单正常，本次偏离 x10 100
                require(ethAmount >= tranEthAmount.mul(_deviationFromScale), "EthAmount needs to be no less than 10 times of transaction scale");
                delayedBlock = _delayed;
            } else {
                //  被吃单正常，本次正常 x2 25
                require(ethAmount >= tranEthAmount.mul(_tranAddition), "EthAmount needs to be no less than 2 times of transaction scale");
                delayedBlock = _blockLimit;
            }
        }
        
        uint256 serviceCharge = tranEthAmount.mul(_tranEth).div(1000);
        require(msg.value == ethAmount.add(tranEthAmount).add(serviceCharge), "msg.value needs to be equal to the quotation eth quantity plus transaction eth plus transaction handling fee");
        require(tranEthAmount % _offerSpan == 0, "Transaction size does not meet asset span");
        
        // 检查吃单条件是否满足
        require(checkContractState(offerPriceData.delayedBlock,offerPriceData.blockNum) == 0, "Offer status error");
        require(offerPriceData.dealEthAmount >= tranEthAmount, "Insufficient trading eth");
        require(offerPriceData.dealTokenAmount >= tranTokenAmount, "Insufficient trading token");
        require(offerPriceData.tokenAddress == tranTokenAddress, "Wrong token address");
        require(tranTokenAmount == offerPriceData.dealTokenAmount * tranEthAmount / offerPriceData.dealEthAmount, "Wrong token amount");
        
        // 更新报价单信息
        offerPriceData.ethAmount = offerPriceData.ethAmount.add(tranEthAmount);
        offerPriceData.tokenAmount -= tranTokenAmount;
        offerPriceData.dealEthAmount -= tranEthAmount;
        offerPriceData.dealTokenAmount -= tranTokenAmount;
        
        // 创建一个新报价
        createOffer(ethAmount, tokenAmount, tranTokenAddress, 0, delayedBlock, isDeviate);
        // 转入报价资产erc20-交易资产到当前合约
        ERC20(tranTokenAddress).safeTransferFrom(address(msg.sender), address(this), tokenAmount.sub(tranTokenAmount));
        // 修改价格
        _offerPrice.changePrice(tranEthAmount, tranTokenAmount, tranTokenAddress, offerPriceData.blockNum);
        emit OfferTran(address(msg.sender), address(0x0), tranEthAmount, address(tranTokenAddress), tranTokenAmount, contractAddress, offerPriceData.owner);
        // 转手续费
        repayEth(_abonusAddress, serviceCharge);
    }
    
    /**
    * @dev 吃单-支出erc20 买入ETH
    * @param ethAmount 本次报价 eth数量
    * @param tokenAmount 本次报价 erc20数量
    * @param contractAddress 吃单目标地址
    * @param tranEthAmount 吃单交易 eth数量
    * @param tranTokenAmount 吃单交易 erc20数量
    * @param tranTokenAddress 吃单交易 erc20地址
    */
    function sendErcBuyEth(uint256 ethAmount, uint256 tokenAmount, address contractAddress, uint256 tranEthAmount, uint256 tranTokenAmount, address tranTokenAddress) public payable {
        // 获取报价单数据结构
        uint256 index = toIndex(contractAddress);
        Nest_3_OfferPriceData storage offerPriceData = _prices[index]; 
        //  检测价格, 当前报价对比上一个有效价格
        bool thisDeviate = comparativePrice(ethAmount,tokenAmount,tranTokenAddress);
        bool isDeviate;
        uint32 delayedBlock;
        if (offerPriceData.deviate == true) {
            isDeviate = true;
        } else {
            isDeviate = thisDeviate;
        }
        // 限制吃单报价每次只能是吃单规模的两倍，防止大额攻击
        if (offerPriceData.deviate) {
            //  被吃单偏离 x2 50
            require(ethAmount >= tranEthAmount.mul(_tranAddition), "EthAmount needs to be no less than 2 times of transaction scale");
            delayedBlock = _delayedAgain;
        } else {
            if (isDeviate) {
                //  被吃单正常，本次偏离 x10 100
                require(ethAmount >= tranEthAmount.mul(_deviationFromScale), "EthAmount needs to be no less than 10 times of transaction scale");
                delayedBlock = _delayed;
            } else {
                //  被吃单正常，本次正常 x2 25
                require(ethAmount >= tranEthAmount.mul(_tranAddition), "EthAmount needs to be no less than 2 times of transaction scale");
                delayedBlock = _blockLimit;
            }
        }
        uint256 serviceCharge = tranEthAmount.mul(_tranEth).div(1000);
        require(msg.value == ethAmount.sub(tranEthAmount).add(serviceCharge), "msg.value needs to be equal to the quoted eth quantity plus transaction handling fee");
        require(tranEthAmount % _offerSpan == 0, "Transaction size does not meet asset span");
        
        // 检查吃单条件是否满足
        require(checkContractState(offerPriceData.delayedBlock,offerPriceData.blockNum) == 0, "Offer status error");
        require(offerPriceData.dealEthAmount >= tranEthAmount, "Insufficient trading eth");
        require(offerPriceData.dealTokenAmount >= tranTokenAmount, "Insufficient trading token");
        require(offerPriceData.tokenAddress == tranTokenAddress, "Wrong token address");
        require(tranTokenAmount == offerPriceData.dealTokenAmount * tranEthAmount / offerPriceData.dealEthAmount, "Wrong token amount");
        
        // 更新报价单信息
        offerPriceData.ethAmount -= tranEthAmount;
        offerPriceData.tokenAmount = offerPriceData.tokenAmount.add(tranTokenAmount);
        offerPriceData.dealEthAmount -= tranEthAmount;
        offerPriceData.dealTokenAmount -= tranTokenAmount;
        
        // 创建一个新报价
        createOffer(ethAmount, tokenAmount, tranTokenAddress, 0, delayedBlock, isDeviate);
        // 转入买ETH的资产+报价资产到当前合约
        ERC20(tranTokenAddress).safeTransferFrom(address(msg.sender), address(this), tranTokenAmount.add(tokenAmount));
        // 修改价格
        _offerPrice.changePrice(tranEthAmount, tranTokenAmount, tranTokenAddress, offerPriceData.blockNum);
        emit OfferTran(address(msg.sender), address(tranTokenAddress), tranTokenAmount, address(0x0), tranEthAmount, contractAddress, offerPriceData.owner);
        // 转手续费
        repayEth(_abonusAddress,serviceCharge);
    }
    
    /**
    * @dev 取出资产，结算挖矿产出
    * @param contractAddress 取回报价单地址
    */
    function turnOut(address contractAddress) public {
        uint256 index = toIndex(contractAddress);
        Nest_3_OfferPriceData storage offerPriceData = _prices[index]; 
        require(address(msg.sender) == offerPriceData.owner, "Not the bidder");
        require(checkContractState(offerPriceData.delayedBlock,offerPriceData.blockNum) == 1, "Offer status error");
        
        // 取出ETH
        if (offerPriceData.ethAmount > 0) {
            repayEth(offerPriceData.owner, offerPriceData.ethAmount);
            offerPriceData.ethAmount = 0;
        }
        
        // 取出ERC20
        if (offerPriceData.tokenAmount > 0) {
            ERC20(address(offerPriceData.tokenAddress)).safeTransfer(offerPriceData.owner, offerPriceData.tokenAmount);
            offerPriceData.tokenAmount = 0;
        }
        // 挖矿结算
        if (offerPriceData.serviceCharge > 0) {
            uint256 myMiningAmount = offerPriceData.serviceCharge.mul(_offerBlockMining[offerPriceData.blockNum]).div(_offerBlockEth[offerPriceData.blockNum]);
            _nestToken.safeTransfer(address(msg.sender), myMiningAmount);
        }
        //  更新价格
        _offerPrice.updateAndCheckPriceNow(address(offerPriceData.tokenAddress));
        
    }
    
    // 将报价单地址转化为在报价单数组中的索引
    function toIndex(address contractAddress) public pure returns(uint256) {
        return uint256(contractAddress) ^ 999999999999999999;
    }
    
    // 将报价单在报价单数组中的索引转化为报价单地址
    function toAddress(uint256 index) public pure returns(address) {
        return address(index ^ 999999999999999999);
    }
    
    // 查看合约状态
    function checkContractState(uint256 delayedBlock, uint256 createBlock) public view returns (uint256) {
        if (block.number.sub(createBlock) > delayedBlock) {
            return 1;
        }
        return 0;
    }

    //  比较吃单价格
    function comparativePrice(uint256 myEthValue, uint256 myTokenValue, address token) private returns(bool) {
        (uint256 frontEthValue, uint256 frontTokenValue) = _offerPrice.updateAndCheckPriceNow(token);
        if (frontEthValue == 0 || frontTokenValue == 0) {
            return false;
        }
        uint256 myPrice = myEthValue.mul(1 ether).div(myTokenValue);
        uint256 tranPrice = frontEthValue.mul(1 ether).div(frontTokenValue);
        uint256 tranTopPrice = tranPrice.add(tranPrice.mul(_deviate).div(100));
        uint256 tranBottomPrice = tranPrice.sub(tranPrice.mul(_deviate).div(100));
        if (myPrice >= tranBottomPrice && myPrice <= tranTopPrice) {
            return false;
        }
        return true;
    }
    //  转 eth
    function repayEth(address accountAddress, uint256 asset) private {
        address payable addr = accountAddress.make_payable();
        addr.transfer(asset);
    }
    
    // 查看区块间隔上限
    function checkBlockLimit() public view returns(uint32) {
        return _blockLimit;
    }
    
    // 查看报价手续费
    function checkMiningETH() public view returns (uint256) {
        return _miningETH;
    }
    
    // 查看交易手续费
    function checkTranEth() public view returns (uint256) {
        return _tranEth;
    }
    
    // 查看 token 是否允许挖矿 
    function checkTokenAllow(address token) public view returns(bool) {
        return _tokenAllow[token];
    }
    
    // 查看交易加成
    function checkTranAddition() public view returns(uint256) {
        return _tranAddition;
    }
    
    // 查看开发分配比例
    function checkCoderAmount() public view returns(uint256) {
        return _coderAmount;
    }
    
    // 查看守护者节点分配比例
    function checkNNAmount() public view returns(uint256) {
        return _NNAmount;
    }
    
    // 查看用户可分配比例
    function checkOtherAmount() public view returns(uint256) {
        return _otherAmount;
    }
    
    // 查看最少报价eth
    function checkleastEth() public view returns(uint256) {
        return _leastEth;
    }
    
    // 查看报价eth跨度
    function checkOfferSpan() public view returns(uint256) {
        return _offerSpan;
    }
    
    // 查看价格偏差
    function checkDeviate() public view returns(uint256){
        return _deviate;
    }
    
    // 查看价格偏差延时区块
    function checkDelayed() public view returns(uint32) {
        return _delayed;
    }
    
    // 查看偏离资产规模
    function checkDeviationFromScale() public view returns(uint256) {
        return _deviationFromScale;
    }
    
    // 查看区块报价手续费
    function checkOfferBlockEth(uint256 blockNum) public view returns(uint256) {
        return _offerBlockEth[blockNum];
    }
    
    // 查看区块挖矿量用户所得
    function checkOfferBlockMining(uint256 blockNum) public view returns(uint256) {
        return _offerBlockMining[blockNum];
    }
    
    //  查看报价eth上限
    function checkOfferEthLimit() public view returns(uint256) {
        return _offerEthLimit;
    }
    
    //  查看多次偏离延时区块
    function checkDelayedAgain() public view returns(uint32) {
        return _delayedAgain;
    }
    
    // 修改报价挖矿手续费挖矿比例
    function changeMiningETH(uint256 num) public onlyOwner {
        _miningETH = num;
    }
    
    // 修改吃单手续费比例
    function changeTranEth(uint256 num) public onlyOwner {
        _tranEth = num;
    }
    
    // 修改区块间隔上限
    function changeBlockLimit(uint32 num) public onlyOwner {
        _blockLimit = num;
    }
    
    // 修改token 是否允许挖矿
    function changeTokenAllow(address token, bool allow) public onlyOwner {
        _tokenAllow[token] = allow;
    }
    
    // 修改交易加成
    function changeTranAddition(uint256 num) public onlyOwner {
        require(num > 0, "Parameter needs to be greater than 0");
        _tranAddition = num;
    }
    
    // 修改初始分配比例
    function changeInitialRatio(uint256 coderNum, uint256 NNNum, uint256 otherNum) public onlyOwner {
        require(coderNum > 0 && coderNum <= 5, "Developer allocation ratio error");
        require(NNNum > 0 && coderNum <= 15, "Guardian allocation ratio error");
        require(coderNum.add(NNNum).add(otherNum) == 100, "User allocation ratio error");
        _coderAmount = coderNum;
        _NNAmount = NNNum;
        _otherAmount = otherNum;
    }
    
    // 修改最少报价eth
    function changeLeastEth(uint256 num) public onlyOwner {
        require(num > 0);
        _leastEth = num;
    }
    
    // 修改报价eth跨度
    function changeOfferSpan(uint256 num) public onlyOwner {
        require(num > 0);
        _offerSpan = num;
    }
    
    // 修改价格偏差
    function changekDeviate(uint256 num) public onlyOwner {
        _deviate = num;
    }
    
    // 修改价格偏差延时区块
    function changeDelayed(uint32 num) public onlyOwner {
        _delayed = num;
    }
    
    // 修改偏离资产规模
    function changeDeviationFromScale(uint256 num) public onlyOwner {
        _deviationFromScale = num;
    }
    
    //  修改报价eth上限
    function changeOfferEthLimit(uint256 num) public onlyOwner {
        _offerEthLimit = num;
    }
    
    //  修改多次偏离延时区块
    function checkDelayedAgain(uint32 num) public onlyOwner {
        _delayedAgain = num;
    }
    
    /**
     * 获取报价数组中累计存储的报价单数量
     * @return 报价数组中累计存储的报价单数量
     **/
    function getPriceCount() view public returns (uint256) {
        return _prices.length;
    }
    
    /**
     * 根据索引获取报价单信息
     * @param priceIndex 报价单索引
     * @return 报价单信息字符串
     **/
    function getPrice(uint256 priceIndex) view public returns (string memory) {
        // 用于生成结果字符串的缓冲数组
        bytes memory buf = new bytes(500000);
        uint256 index = 0;
        
        index = writeOfferPriceData(priceIndex, _prices[priceIndex], buf, index);
        
        // 生成结果字符串并返回
        bytes memory str = new bytes(index);
        while(index-- > 0) {
            str[index] = buf[index];
        }
        return string(str);
    }
    
    /**
     * 查找目标账户的合约单（倒序）
     * @param start 从给定的合约地址对应的索引向前查询（不包含start对应的记录）
     * @param count 最多返回的记录条数
     * @param maxFindCount 最多查找maxFindCount记录
     * @param owner 目标账户地址
     * @return 用符号分割的合约单记录。合约单之间用|分割，字段之间用,分割：
     * uuid,owner,tokenAddress,ethAmount,tokenAmount,dealEthAmount,dealTokenAmount,blockNum,serviceCharge
     **/
    function find(address start, uint256 count, uint256 maxFindCount, address owner) view public returns (string memory) {
        
        // 用于生成结果字符串的缓冲数组
        bytes memory buf = new bytes(500000);
        uint256 index = 0;
        
        // 计算查找区间i和end
        uint256 i = _prices.length;
        uint256 end = 0;
        if (start != address(0)) {
            i = toIndex(start);
        }
        if (i > maxFindCount) {
            end = i - maxFindCount;
        }
        
        // 循环查找，将符合条件的记录写入缓冲区
        while (count > 0 && i-- > end) {
            Nest_3_OfferPriceData memory price = _prices[i];
            if (price.owner == owner) {
                --count;
                index = writeOfferPriceData(i, price, buf, index);
            }
        }
        
        // 生成结果字符串并返回
        bytes memory str = new bytes(index);
        while(index-- > 0) {
            str[index] = buf[index];
        }
        return string(str);
    }
    
    /**
     * 分页获取报价单列表
     * @param offset 跳过开始的offset条记录
     * @param count 最多返回的记录条数
     * @param order 排序规则。0表示倒序，非0表示正序
     * @return 用符号分割的合约单记录。合约单之间用|分割，字段之间用,分割：
     * uuid,owner,tokenAddress,ethAmount,tokenAmount,dealEthAmount,dealTokenAmount,blockNum,serviceCharge
     **/
    function list(uint256 offset, uint256 count, uint256 order) view public returns (string memory) {
        
        // 用于生成结果字符串的缓冲数组
        bytes memory buf = new bytes(500000);
        uint256 index = 0;
        
        // 找区间i和end
        uint256 i = 0;
        uint256 end = 0;
        
        if (order == 0) {
            // 倒序，默认
            // 计算查找区间i和end
            if (offset < _prices.length) {
                i = _prices.length - offset;
            } 
            if (count < i) {
                end = i - count;
            }
            
            // 将目标区间内的记录写入缓冲区
            while (i-- > end) {
                index = writeOfferPriceData(i, _prices[i], buf, index);
            }
        } else {
            // 升序
            // 计算查找区间i和end
            if (offset < _prices.length) {
                i = offset;
            } else {
                i = _prices.length;
            }
            end = i + count;
            if(end > _prices.length) {
                end = _prices.length;
            }
            
            // 将目标区间内的记录写入缓冲区
            while (i < end) {
                index = writeOfferPriceData(i, _prices[i], buf, index);
                ++i;
            }
        }
        
        // 生成结果字符串并返回
        bytes memory str = new bytes(index);
        while(index-- > 0) {
            str[index] = buf[index];
        }
        return string(str);
    }   
     
    // 将报价单数据结构写入缓冲区，并返回缓冲区索引
    function writeOfferPriceData(uint256 priceIndex, Nest_3_OfferPriceData memory price, bytes memory buf, uint256 index) pure private returns (uint256) {
        index = writeAddress(toAddress(priceIndex), buf, index);
        buf[index++] = byte(uint8(44));
        
        index = writeAddress(price.owner, buf, index);
        buf[index++] = byte(uint8(44));
        
        index = writeAddress(price.tokenAddress, buf, index);
        buf[index++] = byte(uint8(44));
        
        index = writeUInt(price.ethAmount, buf, index);
        buf[index++] = byte(uint8(44));
        
        index = writeUInt(price.tokenAmount, buf, index);
        buf[index++] = byte(uint8(44));
       
        index = writeUInt(price.dealEthAmount, buf, index);
        buf[index++] = byte(uint8(44));
        
        index = writeUInt(price.dealTokenAmount, buf, index);
        buf[index++] = byte(uint8(44));
        
        index = writeUInt(price.blockNum, buf, index);
        buf[index++] = byte(uint8(44));
        
        index = writeUInt(price.serviceCharge, buf, index);
        buf[index++] = byte(uint8(44));
        
        index = writeUInt(price.delayedBlock, buf, index);
        buf[index++] = byte(uint8(124));
        
        return index;
    }
     
    // 将整数转成10进制字符串写入缓冲区，并返回缓冲区索引
    function writeUInt(uint256 iv, bytes memory buf, uint256 index) pure public returns (uint256) {
        uint256 i = index;
        do {
            buf[index++] = byte(uint8(iv % 10 +48));
            iv /= 10;
        } while (iv > 0);
        
        for (uint256 j = index; j > i; ++i) {
            byte t = buf[i];
            buf[i] = buf[--j];
            buf[j] = t;
        }
        
        return index;
    }

    // 将地址转成16进制字符串写入缓冲区，并返回缓冲区索引
    function writeAddress(address addr, bytes memory buf, uint256 index) pure private returns (uint256) {
        
        uint256 iv = uint256(addr);
        uint256 i = index + 40;
        do {
            uint256 w = iv % 16;
            if(w < 10) {
                buf[index++] = byte(uint8(w +48));
            } else {
                buf[index++] = byte(uint8(w +87));
            }
            
            iv /= 16;
        } while (index < i);
        
        i -= 40;
        for (uint256 j = index; j > i; ++i) {
            byte t = buf[i];
            buf[i] = buf[--j];
            buf[j] = t;
        }
        
        return index;
    }
    
    // 仅限投票修改
    modifier onlyOwner(){
        require(_voteFactory.checkOwners(msg.sender) == true, "No authority");
        _;
    }
}

//  守护者节点存储合约
interface Nest_NodeAssignment {
    function bookKeeping(uint256 amount) external;
}

//  矿池逻辑 
interface Nest_3_MiningContract {
    //  报价出矿
    function oreDrawing() external payable returns (uint256);
}

//  投票合约
interface Nest_3_VoteFactory {
    //  查询地址
	function checkAddress(string calldata name) external view returns (address contractAddress);
	//  查看是否管理员
	function checkOwners(address man) external view returns (bool);
}

interface Nest_3_OfferPrice {
    function addPrice(uint256 ethAmount, uint256 tokenAmount, uint256 endBlock, address tokenAddress) external;
    function changePrice(uint256 ethAmount, uint256 tokenAmount, address tokenAddress, uint256 blockNum) external;
    function updateAndCheckPriceNow(address tokenAddress) external payable returns(uint256 ethAmount, uint256 erc20Amount);
}





