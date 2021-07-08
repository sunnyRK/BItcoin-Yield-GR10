pragma solidity ^0.8.0;

interface AaveLendingPoolProviderV2 {
  function getLendingPool() external view returns (address);
}
