// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";

contract CanvasPickAsset is ERC1155, Ownable, ERC2981 {
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 private _nextArtId = 1;

    // 작품당 고정된 총 조각 수 (10,000조각 = 0.01% 단위)
    uint256 public constant TOTAL_SHARES = 10000;
    
    // 작품별 조각당 가격 (wei 단위)
    mapping(uint256 => uint256) public sharePrice;

    // 작품 ID별 고유 URI 저장소 (개별 작품 메타데이터용)
    mapping(uint256 => string) private _tokenURIs;

    // 데이터 분석용 저장소
    mapping(uint256 => EnumerableSet.AddressSet) private _artHolders; // 작품별 홀더 명단
    mapping(address => uint256[]) private _userOwnedIds;
    mapping(address => mapping(uint256 => bool)) private _isAdded;
    mapping(address => bool) public whitelisted; // 화이트 리스트
    
    // 컬렉션 전체 정보 URI (마켓플레이스용)
    string private _contractURI;

    // --- 이벤트 선언부 ---
    event ArtMinted(uint256[] ids, uint256[] prices, string[] uris);
    event ArtBought(address indexed buyer, uint256 indexed id, uint256 amount, uint256 totalCost);
    event PriceChanged(uint256 indexed id, uint256 oldPrice, uint256 newPrice);
    event Withdrawal(address indexed owner, uint256 amount);
    event RoyaltyUpdated(uint256 indexed id, address indexed receiver, uint96 feeNumerator);


    constructor(string memory _initialBaseURI) ERC1155(_initialBaseURI) Ownable(msg.sender) {}

    /**
    * @dev 예술 작품 등록 (단일 및 일괄 통합)
    * @param pricePerShares 각 작품의 1조각(0.01%)당 가격 배열 (wei 단위)
    * @param data 추가 메타데이터
    * @param royaltyReceiver 로열티를 받을 사람 (원작자 지갑 주소)
    * @param feeNumerator 로열티 비율 (10000 기준, 500 = 5%)
    */
    function mintArt(
        uint256[] calldata pricePerShares, 
        bytes calldata data,
        string[] calldata uris,
        address royaltyReceiver,
        uint96 feeNumerator
    ) external onlyOwner {
        uint256 len = pricePerShares.length;
        require(len > 0, "Empty arrays");
        require(len == pricePerShares.length, "Array length mismatch");

        uint256[] memory ids = new uint256[](len);
        uint256[] memory amounts = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            uint256 currentId = _nextArtId++;
            require(sharePrice[currentId] == 0, "Art ID already exists"); // 중복 등록 방지
            
            sharePrice[currentId] = pricePerShares[i];
            _tokenURIs[currentId] = uris[i];
            _setTokenRoyalty(currentId, royaltyReceiver, feeNumerator);
            emit RoyaltyUpdated(currentId, royaltyReceiver, feeNumerator);

            ids[i] = currentId;
            amounts[i] = TOTAL_SHARES; // 모든 작품은 10,000조각으로 발행
        }

        // 내부 표준 함수 호출 (1개일 때도 배열로 처리됨)
        _mintBatch(msg.sender, ids, amounts, data);

        emit ArtMinted(ids, pricePerShares, uris);
    }

    /**
    * @dev 장바구니 구매: 여러 작품의 조각을 한 번에 구매 (Gas 효율적)
    * @param ids 구매할 작품 ID 배열
    * @param amounts 각 ID별 구매할 조각 수 배열
    */
    function buyArtworks(uint256[] calldata ids, uint256[] calldata amounts) external payable {
        uint256 len = ids.length;
        require(len == amounts.length, "Array length mismatch");

        uint256 totalCost = 0;
        
        // 1. 비용 계산 및 소유 목록 업데이트
        for (uint256 i = 0; i < len; i++) {
            uint256 id = ids[i];
            uint256 amount = amounts[i];
            
            uint256 cost = sharePrice[id] * amount;
            require(cost > 0, "Art not registered");
            require(balanceOf(owner(), id) >= amount, "Not enough shares available");
            
            totalCost += cost;

            if (!_isAdded[msg.sender][id]) {
                _userOwnedIds[msg.sender].push(id);
                _isAdded[msg.sender][id] = true;
            }

            emit ArtBought(msg.sender, id, amount, sharePrice[id] * amount);
        }

        // 2. 금액 확인
        require(msg.value >= totalCost, "Insufficient ETH sent");

        // 3. 내부 전송 로직 호출 (인자 4개: from, to, ids, amounts)
        _update(owner(), msg.sender, ids, amounts);

        // 4. 초적 금액 환불 (transfer 대신 call 사용)
        if (msg.value > totalCost) {
            uint256 refundAmount = msg.value - totalCost;
            (bool success, ) = payable(msg.sender).call{value: refundAmount}("");
            require(success, "Refund failed"); // 환불 실패 시 전체 트랜잭션 취소
        }
    }

    /**
     * 토큰 이동이 일어날 때마다 자동으로 실행되는 감시 함수
     * 구매, 선물 등 모든 이동 시 '홀더 명단'을 실시간으로 업데이트합니다.
     */
    function _update(
        address from, 
        address to, 
        uint256[] memory ids, 
        uint256[] memory values
    ) internal override {
        // 민팅(from == 0)이 아니고 소각(to == 0)이 아닌 '일반 거래'일 때만 체크
        if (from != address(0) && to != address(0)) {
            require(whitelisted[from], "Sender not whitelisted");
            require(whitelisted[to], "Recipient not whitelisted");
        }

        super._update(from, to, ids, values);
        
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            
            if (to != address(0)) {
                _artHolders[id].add(to); // 잔액 상관없이 일단 add (이미 있으면 무시됨)
            }
            
            // 보낸 사람 처리
            if (from != address(0) && balanceOf(from, id) == 0) {
                _artHolders[id].remove(from);
            }
        }
    }


    /**
    * @dev 특정 작품의 모든 홀더 명단과 잔액을 반환합니다.
    * 정렬이나 개수 제한 없이 전체 데이터를 보내며, 가공은 프론트엔드(React)에서 수행합니다.
    */
    function getAllHolders(uint256 id) public view returns (address[] memory holders, uint256[] memory balances) {
        EnumerableSet.AddressSet storage holdersSet = _artHolders[id];
        uint256 totalCount = holdersSet.length();
        
        // 먼저 실제 유저(Owner 제외)가 몇 명인지 카운트
        uint256 userCount = 0;
        for (uint256 i = 0; i < totalCount; i++) {
            if (holdersSet.at(i) != owner()) {
                userCount++;
            }
        }
        
        address[] memory _holders = new address[](userCount);
        uint256[] memory _balances = new uint256[](userCount);
        
        uint256 currentIndex = 0;
        for (uint256 i = 0; i < totalCount; i++) {
            address holder = holdersSet.at(i);
            // [수정] 관리자가 아닐 때만 결과 배열에 추가
            if (holder != owner()) {
                _holders[currentIndex] = holder;
                _balances[currentIndex] = balanceOf(holder, id);
                currentIndex++;
            }
        }
        
        return (_holders, _balances);
    }

    // 관리자 기능: URI 수정 및 수익 인출
    function setTokenURI(uint256 id, string memory newuri) public onlyOwner { _tokenURIs[id] = newuri; }
    function setContractURI(string memory newContractURI) public onlyOwner { _contractURI = newContractURI; }
    function contractURI() public view returns (string memory) { return _contractURI; }
    function uri(uint256 id) public view override returns (string memory) {
        return _tokenURIs[id];
    }
    function setWhitelist(address user, bool status) external onlyOwner {
        whitelisted[user] = status;
    }

    /**
    * @dev 등록된 작품의 조각당 가격을 수정합니다. (단일/일괄 모두 지원)
    * @param ids 가격을 수정할 작품 ID 배열
    * @param newPrices 새로운 조각당 가격 배열 (wei 단위)
    */
    function setPrice(uint256[] calldata ids, uint256[] calldata newPrices) external onlyOwner {
        uint256 len = ids.length;
        require(len > 0 && len == newPrices.length, "Array mismatch");

        for (uint256 i = 0; i < len; i++) {
            uint256 id = ids[i];
            require(sharePrice[id] > 0, "Art not registered"); // 등록되지 않은 작품은 수정 불가
            
            uint256 oldPrice = sharePrice[id];
            sharePrice[id] = newPrices[i];
            
            // 가격 변경 이벤트를 발생시켜 앱/마켓플레이스에 알림
            emit PriceChanged(id, oldPrice, newPrices[i]);
        }
    }

    /**
     * @dev 수익금 인출
     */
    function withdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No funds to withdraw");
        
        (bool success, ) = payable(owner()).call{value: balance}("");
        require(success, "Withdrawal failed");

        emit Withdrawal(owner(), balance);
    }
    
    // 사용자가 소유한 모든 작품 ID와 잔액을 한 번에 가져오는 함수
    function getUserPortfolio(address user) external view returns (uint256[] memory ids, uint256[] memory balances) {
        uint256[] memory ownedIds = _userOwnedIds[user];
        uint256[] memory currentBalances = new uint256[](ownedIds.length);
        
        for (uint256 i = 0; i < ownedIds.length; i++) {
            currentBalances[i] = balanceOf(user, ownedIds[i]);
        }
        
        return (ownedIds, currentBalances);
    }

    // ERC2981과 ERC1155가 충돌하는 인터페이스 지원 함수 (필수)
    function supportsInterface(bytes4 interfaceId) public view override(ERC1155, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
