# uni-v4-hook-practice

Practice of Custom Hook for Uniswap V4

## Self-Defined Requirements

- Hook must support pools with only USDT and USDC
- When traders swap via the pool, hook takes 0.1% of input token as a fee
  e.g., If trader swaps 1000 USDT to USDC, 1 USDT should go to the hook.
- The hook developer will get the half of the fee as a reward.
- Traders will get a portion of the other half as a reward according to their trading volume.
  i.e., Traders will get USDT according to their sold amount of USDT and they will get USDC according to the amount of USDC that they sold.
- Hook developer and traders can withdraw the reward anytime
- Once hook takes the fee from swaps, it deposits the tokens into Aave.
  So the hook will have aUSDT and aUSDC on it.
  And when hook developer or traders try to withdraw rewards, hook will withdraw USDT or USDC from Aave, then send it to them.
- Since the amount of aUSDT and aUSDC increase over time, the withdrawable amount will increase.

## Test Cases

- Hook deployment
- Check if the hook get fee from swap and deposit into Aave
- Check if the hook developer and trader can withdraw rewards
- Check if the rewards are distributed according to their volume
