const { ethers } = require("hardhat");  

async function main() {  
  const [deployer] = await ethers.getSigners();  
  console.log("Deploying contracts with account:", deployer.address);  

  const MockUSDC = await ethers.getContractFactory("MockUSDC");  
  const usdc = await MockUSDC.deploy();  
  await usdc.deployed();  

  const PredictionMarketBeta = await ethers.getContractFactory("PredictionMarketBeta");  
  const pm = await PredictionMarketBeta.deploy(usdc.address, deployer.address);  
  await pm.deployed();  

  console.log("USDC deployed to:", usdc.address);  
  console.log("PredictionMarketBeta deployed to:", pm.address);  

  // Optionally seed markets here  
}  

main().catch((error) => {  
  console.error(error);  
  process.exitCode = 1;  
});
