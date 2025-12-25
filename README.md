# Prediction Market Beta  

This repository contains a minimal on-chain prediction market prototype built for an internal feasibility test. It includes:  

- A Solidity contract (`contracts/PredictionMarketBeta.sol`) implementing a simple YES/NO prediction market with a USDC-like mock token, constant product AMM, and market resolution.  
- A mock USDC token for local testing.  
- Scripts and tests (to be added).  
- Placeholder frontend for interacting with the contracts (to be added).  

## Project Structure  

- `contracts/` – contains the Solidity contracts, Hardhat config, deployment scripts, and test examples.  
- `web/` – (not yet included) intended for a simple web UI.  

## Getting Started  

To work with this project locally:  

1. Clone the repository.  
2. Install dependencies inside the `contracts` folder:  
   ```bash  
   cd contracts  
   npm install  
   ```  
3. Compile the contracts:  
   ```bash  
   npx hardhat compile  
   ```  
4. Start a local Hardhat node:  
   ```bash  
   npx hardhat node  
   ```  
5. In a new terminal, deploy the contracts to the local network:  
   ```bash  
   npx hardhat run scripts/deploy.ts --network localhost  
   ```  
6. Open the `web` folder (once created) to interact with the contracts.  

## Notes  

- This code is for internal testing only and is not production-ready.  
- Market lists and predictions are placeholders; you can add your own markets by modifying the deployment script or using the contract's createMarket function.
