pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { ERC4626 } from "../src/periphery/ERC4626.sol";
import { AddressSet, LibAddressSet } from "../src/utils/AddressSet.sol";

contract ERC4626Handler is TestBase, StdCheats, StdUtils {
  using LibAddressSet for AddressSet;

  AddressSet internal actors;
  ERC4626 public vault;

  uint256 public ghost_depositSum;
  uint256 public ghost_gainSum;
  uint256 public ghost_withdrawSum;
  uint256 public ghost_zeroDeposit;
  uint256 public ghost_zeroWithdraw;
  mapping(bytes32 => uint256) public calls;

  address internal currentActor;

  modifier countCall(bytes32 key) {
    calls[key]++;
    _;
  }

  modifier createActor() {
    currentActor = msg.sender;
    actors.add(msg.sender);
    deal(vault.asset(), currentActor, 10 ** 18);

    vm.startPrank(currentActor);
    IERC20(vault.asset()).approve(address(vault), type(uint256).max);
    IERC20(vault).approve(address(vault), type(uint256).max);
    _;
    vm.stopPrank();
  }

  modifier useActor(uint256 actorIndexSeed) {
    currentActor = actors.rand(actorIndexSeed);
    vm.startPrank(currentActor);
    _;
    vm.stopPrank();
  }

  constructor(ERC4626 _vault) {
    vault = _vault;
  }

  // helper methods for actors

  function callSummary() external view {
    console.log("Total summary:");
    console.log("-------------------");
    console.log("total actors", actors.count());
    console.log("total deposit", ghost_depositSum);
    console.log("total withdraw", ghost_withdrawSum);
    console.log("total gain", ghost_gainSum);
    console.log("zero deposit", ghost_zeroDeposit);
    console.log("zero withdraw", ghost_zeroWithdraw);
    console.log("\nCall summary:");
    console.log("-------------------");
    console.log("deposit", calls["deposit"]);
    console.log("mint", calls["mint"]);
    console.log("redeem", calls["redeem"]);
    console.log("withdraw", calls["withdraw"]);
    console.log("transfer", calls["transfer"]);
    console.log("transferFrom", calls["transferFrom"]);
    console.log("approve", calls["approve"]);
  }

  function forEachActor(function(address) external func) public {
    return actors.forEach(func);
  }

  function reduceActors(
    uint256 acc,
    function(uint256,address) external returns (uint256) func
  ) public returns (uint256) {
    return actors.reduce(acc, func);
  }

  // Core ERC4262 methods

  function deposit(uint256 amount) public createActor countCall("deposit") {
    amount = bound(amount, 0, IERC20(vault.asset()).balanceOf(currentActor));
    if (amount == 0) {
      ghost_zeroDeposit += 1;
    }
    vault.deposit(amount, currentActor);
    ghost_depositSum += amount;
  }

  function mint(uint256 amount) public createActor countCall("mint") {
    amount = bound(amount, 0, IERC20(vault.asset()).balanceOf(currentActor));
    if (amount == 0) {
      ghost_zeroDeposit += 1;
    }
    uint256 shares = vault.convertToShares(amount);

    vault.mint(shares, currentActor);
    ghost_depositSum += amount;
  }

  function withdraw(uint256 actorSeed, uint256 amount)
    public
    useActor(actorSeed)
    countCall("withdraw")
  {
    // TODO: add invariant: all shares is withdrawble
    amount = bound(amount, 0, vault.maxWithdraw(currentActor));
    if (amount == 0) {
      ghost_zeroWithdraw += 1;
    }
    uint256 shares = vault.convertToShares(amount);
    vault.withdraw(shares, currentActor, currentActor);
    ghost_withdrawSum += amount;
  }

  function redeem(uint256 actorSeed, uint256 amount)
    public
    useActor(actorSeed)
    countCall("redeem")
  {
    // TODO: add invariant: all shares is withdrawble
    amount = bound(amount, 0, vault.maxWithdraw(currentActor));
    if (amount == 0) {
      ghost_zeroWithdraw += 1;
    }
    vault.redeem(amount, currentActor, currentActor);
    ghost_withdrawSum += amount;
  }

  // ERC20-related methods (ERC04626 is also ERC20)

  function approve(uint256 actorSeed, uint256 spenderSeed, uint256 amount)
    public
    useActor(actorSeed)
    countCall("approve")
  {
    address spender = actors.rand(spenderSeed);

    vault.approve(spender, amount);
  }

  function transfer(uint256 actorSeed, uint256 toSeed, uint256 amount)
    public
    useActor(actorSeed)
    countCall("transfer")
  {
    address to = actors.rand(toSeed);

    amount = bound(amount, 0, vault.balanceOf(currentActor));

    vault.transfer(to, amount);
  }

  function transferFrom(
    uint256 actorSeed,
    uint256 fromSeed,
    uint256 toSeed,
    uint256 amount
  ) public useActor(actorSeed) countCall("transferFrom") {
    address from = actors.rand(fromSeed);
    address to = actors.rand(toSeed);

    amount = bound(amount, 0, vault.balanceOf(from));
    amount = bound(amount, 0, vault.allowance(currentActor, from));

    vault.transferFrom(from, to, amount);
  }
}

abstract contract ERC4626Invariants is Test {
  ERC4626 public _vault;
  ERC4626Handler public handler;

  function setVault(ERC4626 vault_) public {
    _vault = vault_;
    handler = new ERC4626Handler(_vault);
    bytes4[] memory selectors = new bytes4[](7);

    selectors[0] = ERC4626Handler.deposit.selector;
    selectors[1] = ERC4626Handler.withdraw.selector;
    selectors[2] = ERC4626Handler.mint.selector;
    selectors[3] = ERC4626Handler.redeem.selector;
    selectors[4] = ERC4626Handler.approve.selector;
    selectors[5] = ERC4626Handler.transfer.selector;
    selectors[6] = ERC4626Handler.transferFrom.selector;

    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    excludeContract(address(_vault));
    // TODO: FIXME
    excludeContract(address(0));
    excludeSender(address(0));
  }

  function accumulateAssetBalance(uint256 balance, address caller)
    external
    view
    returns (uint256)
  {
    return balance + _vault.convertToAssets(_vault.balanceOf(caller));
  }

  function accumulateShareBalance(uint256 balance, address caller)
    external
    view
    returns (uint256)
  {
    return balance + _vault.balanceOf(caller);
  }

  function invariant_callSummary() public view {
    handler.callSummary();
  }

  function invariant_totalAssetsSolvency() public {
    bool isSolvent =
      handler.ghost_depositSum() + handler.ghost_gainSum() >= handler.ghost_withdrawSum();
    assertTrue(isSolvent);

    uint256 totalAssets_ =
      handler.ghost_depositSum() + handler.ghost_gainSum() - handler.ghost_withdrawSum();
    assertEq(_vault.totalAssets(), totalAssets_);
  }

  function invariant_sharesZeroOverflow() public {
    uint256 sumOfShares = handler.reduceActors(0, this.accumulateShareBalance);
    assertEq(_vault.totalSupply(), sumOfShares);
  }

  function invariant_sharesIsSolvent() public {
    uint256 sumOfAssets = handler.reduceActors(0, this.accumulateAssetBalance);
    assertEq(_vault.totalAssets(), sumOfAssets);
  }

  function invariant_totalAssetsShareRelation() public {
    assertGe(_vault.totalAssets(), _vault.totalSupply());
  }
}
