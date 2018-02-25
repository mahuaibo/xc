pragma solidity ^0.4.19;

library Data {

    enum Errcode {
        Success,
        NotOwner,
        PlatformTypeInvalid,
        PlatformNameNotNull,
        CatNotOwenerPlatformName,
        NotCredible,
        InsufficientBalance,
        TransferFailed,
        PublickeyNotExist,
        VoterNotChange,
        WeightNotSatisfied
    }

    struct Admin {
        bytes32 name;
        address account;
    }

    struct Platform {
        uint8 typ; // 平台类型：1:公有链 2:联盟链
        bytes32 name; // 跨链合约部署平台名称
        uint totalOf; // 对外总开放数量；默认为0；（当前合约总锁死数量）
        uint weight; // 用于各平台验证权重数
        address[] publickeys; // 各平台公信公钥
        mapping(bytes32 => address[]) proposals;// 投票提案
    }
}

contract INK {

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function transferFrom(address _from, address _to, uint256 value) public returns (bool success);
    function transfer(address _to, uint256 value) public returns (bool success);
}

contract XCPlugin {

    function existPlatfrom(bytes32 name) external constant returns (bool);
    function verify(bytes32 name, bytes32 txid) external constant returns (Data.Errcode);
    function deleteProposal(bytes32 platformName, bytes32 txid) external constant returns (Data.Errcode);
}


interface XCInterface {

    function setAdmin(bytes32 name,address account) external;
    function getAdmin() external constant returns (bytes32,address);

    function setINK(address account) external;
    function getINK() external constant returns (address);

    function setXCPlugin(address account) external;
    function getXCPlugin() external constant returns (address);

    function lock(bytes32 toPlatform, address toAccount, uint amount) external payable returns (Data.Errcode);
    function unlock(bytes32 fromPlatform,address fromAccount, address toAccount, uint amount, bytes32 txid) external payable returns (Data.Errcode);

    function withdrawal(address account,uint amount) external payable returns (Data.Errcode);

    function lockAdmin(bytes32 toPlatform, address toAccount, uint amount) external payable returns (Data.Errcode);
    function unlockAdmin(bytes32 fromPlatform,address fromAccount, address toAccount, uint amount, bytes32 txid) external payable returns (Data.Errcode);
}

contract XC is XCInterface {

    Data.Admin private admin;
    mapping(bytes32 => uint) public balanceOf;

    INK private inkToken;
    XCPlugin private xcPlugin;

    event lockEvent(bytes32 toPlatform, address toAccount, string amount);
    event unlockEvent(bytes32 txid,bytes32 fromPlatform,address fromAccount ,string amount);

    function XC(bytes32 name) public payable {
        admin = Data.Admin(name, msg.sender);
    }

    function setAdmin(bytes32 name, address account) external {
        if (admin.account == msg.sender) {
            admin.name = name;
            admin.account = account;
        }
    }

    function getAdmin() external constant returns (bytes32,address) {
        return (admin.name,admin.account);
    }

    function setINK(address account) external {
        inkToken = INK(account);
    }

    function getINK() external constant returns (address) {
        return inkToken;
    }

    function setXCPlugin(address account) external {
        xcPlugin = XCPlugin(account);
    }

    function getXCPlugin() external constant returns (address) {
        return xcPlugin;
    }

    function lock(bytes32 toPlatform, address toAccount, uint amount) external payable returns (Data.Errcode) {
        // 1.是否信任平台
        if (!xcPlugin.existPlatfrom(toPlatform)) {
            return Data.Errcode.NotCredible;
        }
        // 2.获取信任余额;验证转入ink数是否小于授权ink数
        uint allowance = inkToken.allowance(msg.sender, this);
        if (allowance < amount) {
            return Data.Errcode.InsufficientBalance;
        }
        // 3.执行转入，锁定额度
        bool success = inkToken.transferFrom(msg.sender, this, amount);
        if (!success) {
            return Data.Errcode.TransferFailed;
        }
        // 4.更新总对外发放额度
        balanceOf[admin.name] += amount;
        // 5.更新记录向某个Platform总发放量
        balanceOf[toPlatform] += amount;
        // 6.数值转换,用于记录日志
        string memory value = uintAppendToString(amount);
        // 7.发送转入事件记录日志
        lockEvent(toPlatform, toAccount, value);
        return Data.Errcode.Success;
    }

    function unlock(bytes32 fromPlatform,address fromAccount, address toAccount, uint amount, bytes32 txid) external payable returns (Data.Errcode) {
        // 1.是否信任平台
        if (!xcPlugin.existPlatfrom(fromPlatform)) {
            return Data.Errcode.NotCredible;
        }
        // 2.验证有效性
        Data.Errcode errcode = xcPlugin.verify(fromPlatform, txid);
        if (errcode == Data.Errcode.Success) {
            return errcode;
        }
        // 3.获取合约持有ink数;
        uint balanceOfContract = inkToken.balanceOf(this);
        if (balanceOfContract < amount) {
            return Data.Errcode.InsufficientBalance;
        }
        // 4.执行转出
        bool success = inkToken.transfer(toAccount, amount);
        if (!success) {
            return Data.Errcode.TransferFailed;
        }
        // 5.移除提案
        errcode = xcPlugin.deleteProposal(fromPlatform, txid);
        if (errcode == Data.Errcode.Success) {
            return errcode;
        }
        // 6.更新总对外发放额度
        balanceOf[admin.name] -= amount;
        // 7.更新记录向某个Platform总发放量
        balanceOf[fromPlatform] -= amount;
        // 8.数值转换,用于记录日志
        string memory value = uintAppendToString(amount);
        // 9.发送转入事件记录日志
        unlockEvent(txid, fromPlatform, fromAccount, value);
        return Data.Errcode.Success;
    }

    function withdrawal(address account,uint amount) external payable returns (Data.Errcode) {
        if (admin.account != msg.sender) {
            return Data.Errcode.NotOwner;
        }
        // 1.获取合约持有ink数;
        uint balanceOfContract = inkToken.balanceOf(this);
        uint balance = balanceOf[admin.name];
        if (balanceOfContract - balance < amount) {
            return Data.Errcode.InsufficientBalance;
        }
        // 2.执行转出
        bool success = inkToken.transfer(account, amount);
        if (!success) {
            return Data.Errcode.TransferFailed;
        }
        return Data.Errcode.Success;
    }

    function lockAdmin(bytes32 toPlatform, address toAccount, uint amount) external payable returns (Data.Errcode) {
        // 0.admin
        if (admin.account != msg.sender) {
            return Data.Errcode.NotOwner;
        }
        // 1.是否信任平台
        if (!xcPlugin.existPlatfrom(toPlatform)) {
            return Data.Errcode.NotCredible;
        }
        // 2.获取信任余额;验证转入ink数是否小于授权ink数
        uint allowance = inkToken.allowance(msg.sender, this);
        if (allowance < amount) {
            return Data.Errcode.InsufficientBalance;
        }
        // 3.执行转入，锁定额度
        bool success = inkToken.transferFrom(msg.sender, this, amount);
        if (!success) {
            return Data.Errcode.TransferFailed;
        }
        // 4.更新总对外发放额度
        balanceOf[admin.name] += amount;
        // 5.更新记录向某个Platform总发放量
        balanceOf[toPlatform] += amount;
        // 6.数值转换,用于记录日志
        string memory value = uintAppendToString(amount);
        // 7.发送转入事件记录日志
        lockEvent(toPlatform, toAccount, value);
        return Data.Errcode.Success;
    }

    function unlockAdmin(bytes32 fromPlatform,address fromAccount, address toAccount, uint amount, bytes32 txid) external payable returns (Data.Errcode) {
        // 0.admin
        if (admin.account != msg.sender) {
            return Data.Errcode.NotOwner;
        }
        // 1.是否信任平台
        if (!xcPlugin.existPlatfrom(fromPlatform)) {
            return Data.Errcode.NotCredible;
        }
        // 2.验证有效性
        // Data.Errcode errcode = xcPlugin.verify(fromPlatform, txid);
        // if (errcode == Data.Errcode.Success) {
        //     return errcode;
        // }
        // 3.获取合约持有ink数;
        uint balanceOfContract = inkToken.balanceOf(this);
        if (balanceOfContract < amount) {
            return Data.Errcode.InsufficientBalance;
        }
        // 4.执行转出
        bool success = inkToken.transfer(toAccount, amount);
        if (!success) {
            return Data.Errcode.TransferFailed;
        }
        // 5.移除提案
        // errcode = xcPlugin.deleteProposal(fromPlatform, txid);
        // if (errcode == Data.Errcode.Success) {
        //     return errcode;
        // }
        // 6.更新总对外发放额度
        balanceOf[admin.name] -= amount;
        // 7.更新记录向某个Platform总发放量
        balanceOf[fromPlatform] -= amount;
        // 8.数值转换,用于记录日志
        string memory value = uintAppendToString(amount);
        // 9.发送转入事件记录日志
        unlockEvent(txid, fromPlatform, fromAccount, value);
        return Data.Errcode.Success;
    }


    /**
     *   ######################
     *  #  private function  #
     * ######################
     */
    //将10进制转成16进制，并在前头补0位，组成64位字符串与系统日志保持一致
    function uintAppendToString(uint v) pure internal returns (string){
        uint maxlength = 100;
        bytes memory reversed = new bytes(maxlength);
        bytes32 sixTeenStr = "0123456789abcdef";
        //用于转换成16进制
        uint i = 0;
        while (v != 0) {//计算十六进制具体查看十进制转十六进制算法
            uint remainder = v % 16;
            v = v / 16;
            reversed[i++] = byte(sixTeenStr[remainder]);
            //将对应的十六进制码转为byte
        }
        string memory bytesList = "0000000000000000000000000000000000000000000000000000000000000000";
        bytes memory strb = bytes(bytesList);
        //将64位空串0000...000转成bytes
        for (uint j = 0; j < i; j++) {//将计算得到的十六进制数值的byte存入strb，从末尾开始替换
            strb[strb.length - j - 1] = reversed[i - j - 1];
        }
        return string(strb);
    }
}