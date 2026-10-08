require('@nomicfoundation/hardhat-toolbox')

// Chaves ficam SO em variaveis de ambiente locais (nunca no repositorio).
const {AMOY_RPC_URL, DEPLOYER_PRIVATE_KEY, POLYGONSCAN_API_KEY} = process.env

module.exports = {
  solidity: {
    version: '0.8.28',
    settings: {optimizer: {enabled: true, runs: 200}, evmVersion: 'cancun'}
  },
  paths: {sources: './src'},
  networks: {
    hardhat: process.env.FORK_URL ? {forking: {url: process.env.FORK_URL}} : {},
    amoy: {
      url: AMOY_RPC_URL || 'https://polygon-amoy-bor-rpc.publicnode.com',
      chainId: 80002,
      accounts: DEPLOYER_PRIVATE_KEY ? [DEPLOYER_PRIVATE_KEY] : []
    },
    polygon: {
      url: process.env.POLYGON_RPC_URL || 'https://polygon-bor-rpc.publicnode.com',
      chainId: 137,
      accounts: DEPLOYER_PRIVATE_KEY ? [DEPLOYER_PRIVATE_KEY] : []
    }
  },
  etherscan: {apiKey: POLYGONSCAN_API_KEY || ''},
  gasReporter: {enabled: Boolean(process.env.REPORT_GAS)}
}
