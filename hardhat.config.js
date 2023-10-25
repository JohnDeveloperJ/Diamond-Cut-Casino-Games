/* global ethers task */
require('@nomiclabs/hardhat-waffle');
require("@nomiclabs/hardhat-etherscan");
// This is a sample Hardhat task. To learn how to create your own, go to
// https://hardhat.org/guides/create-task.html
task('accounts', 'Prints the list of accounts', async () => {
  const accounts = await ethers.getSigners();

  for (const account of accounts) {
    console.log(account.address);
  }
});

// You need to export an object to set up your config
// Go to https://hardhat.org/config/ to learn more

/**
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
  solidity: '0.8.20',
  settings: {

    optimizer: {
      enabled: true,
      runs: 200,
    },
  },
  networks: {
    goerli: {
      url: "https://eth-sepolia.g.alchemy.com/v2/C4XwFUQlcB__danHlr7jYL6YZ0MI88Pr",
      accounts: ["2bdce7ffa432c70fddf17704520418fdc3e610867e45d906ab8f5277cbbb8e67"],
    },
  },
  etherscan: {
    apiKey: "R89CFA9UVDNRKBJEHX97NYB79CB7I4XVZH", // Your API key for Etherscan
    // Obtain one at https://etherscan.io/
  },
};
