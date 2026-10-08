// Economia em POL: divisor 60/40, loja de LE e pool de recompensas que nunca quebra.
const {expect} = require('chai')
const {ethers} = require('hardhat')
const {loadFixture, time} = require('@nomicfoundation/hardhat-toolbox/network-helpers')

const POL = (n) => ethers.parseEther(String(n))
const USD = (n) => BigInt(Math.round(n * 1e8))

async function deploy() {
  const [owner, treasury, alice, bob, server, mallory] = await ethers.getSigners()
  const pool = await ethers.deployContract('MysticRewardPool', [owner.address, treasury.address, server.address, 100, POL(100)]) // 1%/dia, 100 POL por carteira
  const splitter = await ethers.deployContract('MysticRevenueSplitter', [owner.address, treasury.address, await pool.getAddress(), 4000])
  const feed = await ethers.deployContract('PriceFeedMock', [USD(0.1)]) // POL = US$ 0,10
  const leShop = await ethers.deployContract('MysticLEShop', [owner.address, await splitter.getAddress(), await feed.getAddress(), USD(1), 0]) // 10.000 LE = US$ 1

  return {owner, treasury, alice, bob, server, mallory, pool, splitter, feed, leShop}
}

const signClaim = async (signer, pool, player, amount, nonce, deadline) => {
  const {chainId} = await ethers.provider.getNetwork()
  return signer.signTypedData(
    {name: 'MysticLands Reward Pool', version: '1', chainId, verifyingContract: await pool.getAddress()},
    {PolClaim: [{name: 'player', type: 'address'}, {name: 'amount', type: 'uint256'}, {name: 'nonce', type: 'uint256'}, {name: 'deadline', type: 'uint256'}]},
    {player, amount, nonce, deadline}
  )
}

const fundPool = async (pool, from, amount) => from.sendTransaction({to: await pool.getAddress(), value: amount})

describe('Divisor de receita 60/40', () => {
  it('cada POL que entra vai 60% para a tesouraria e 40% para o pool', async () => {
    const {splitter, pool, treasury, alice} = await loadFixture(deploy)
    const tx = await alice.sendTransaction({to: await splitter.getAddress(), value: POL(100)})
    await expect(tx).to.changeEtherBalances([treasury, pool], [POL(60), POL(40)])
    expect(await ethers.provider.getBalance(await splitter.getAddress())).to.equal(0)
  })

  it('a parte do pool fica entre 20% e 60%, e so o dono muda', async () => {
    const {splitter, treasury, pool, mallory} = await loadFixture(deploy)
    await expect(splitter.setConfig(treasury.address, await pool.getAddress(), 1000)).to.be.revertedWithCustomError(splitter, 'InvalidShare')
    await expect(splitter.setConfig(treasury.address, await pool.getAddress(), 7000)).to.be.revertedWithCustomError(splitter, 'InvalidShare')
    await expect(splitter.connect(mallory).setConfig(mallory.address, mallory.address, 4000)).to.be.revertedWithCustomError(splitter, 'OwnableUnauthorizedAccount')
  })

  it('token ERC-20 enviado ao divisor nao fica preso: qualquer um empurra, mas so vai para a tesouraria', async () => {
    const {splitter, treasury, mallory} = await loadFixture(deploy)
    const token = await ethers.deployContract('TokenMock', [POL(1000)])
    await token.transfer(await splitter.getAddress(), POL(500))
    const tx = await splitter.connect(mallory).flushToken(await token.getAddress())
    await expect(tx).to.changeTokenBalances(token, [treasury, mallory, splitter], [POL(500), 0, -POL(500)])
    await expect(tx).to.emit(splitter, 'TokenForwarded').withArgs(await token.getAddress(), POL(500))
  })
})

describe('Loja de LE em POL', () => {
  it('10.000 LE = US$ 1: com POL a US$ 0,10, 10 POL compram 10.000 LE', async () => {
    const {leShop} = await loadFixture(deploy)
    expect(await leShop.packPriceInPol()).to.equal(POL(10))
    expect(await leShop.quote(POL(10))).to.equal(10000n)
  })

  it('compra emite o evento para o servidor creditar e divide o POL 60/40', async () => {
    const {leShop, pool, treasury, alice} = await loadFixture(deploy)
    const tx = await leShop.connect(alice).buy(5000, {value: POL(5)})
    await expect(tx).to.emit(leShop, 'LeBought').withArgs(alice.address, 1, POL(5), 5000)
    await expect(tx).to.changeEtherBalances([alice, treasury, pool], [-POL(5), POL(3), POL(2)])
  })

  it('protege contra mudanca de preco e respeita o maximo por compra', async () => {
    const {leShop, feed, alice} = await loadFixture(deploy)
    await feed.set(USD(0.05), await time.latest()) // POL caiu: LE fica mais caro em POL
    await expect(leShop.connect(alice).buy(10000, {value: POL(10)})).to.be.revertedWithCustomError(leShop, 'BelowMinimum')
    await leShop.setMaxLePerPurchase(1000)
    await expect(leShop.connect(alice).buy(0, {value: POL(10)})).to.be.revertedWithCustomError(leShop, 'AboveMaximum')
  })
})

describe('Pool de recompensas', () => {
  it('paga a troca assinada pelo servidor, uma vez so', async () => {
    const {pool, owner, alice, server} = await loadFixture(deploy)
    await fundPool(pool, owner, POL(1000))
    const deadline = (await time.latest()) + 600
    const sig = await signClaim(server, pool, alice.address, POL(5), 1n, deadline)
    await expect(pool.connect(alice).claim(POL(5), 1n, deadline, sig)).to.changeEtherBalance(alice, POL(5))
    await expect(pool.connect(alice).claim(POL(5), 1n, deadline, sig)).to.be.revertedWithCustomError(pool, 'NonceUsed')
  })

  it('nunca paga mais que 1% do pool por dia (todas as carteiras juntas)', async () => {
    const {pool, owner, alice, bob, server} = await loadFixture(deploy)
    await fundPool(pool, owner, POL(1000)) // teto do dia = 10 POL
    const deadline = (await time.latest()) + 600
    await pool.connect(alice).claim(POL(6), 2n, deadline, await signClaim(server, pool, alice.address, POL(6), 2n, deadline))
    const over = await signClaim(server, pool, bob.address, POL(5), 3n, deadline)
    await expect(pool.connect(bob).claim(POL(5), 3n, deadline, over)).to.be.revertedWithCustomError(pool, 'DailyBudgetReached')
    expect(await pool.remainingToday()).to.equal(POL(4))
  })

  it('respeita o limite diario por carteira', async () => {
    const {pool, owner, alice, server} = await loadFixture(deploy)
    await fundPool(pool, owner, POL(5_000))
    await pool.setLimits(100, POL(3))
    const deadline = (await time.latest()) + 600
    await pool.connect(alice).claim(POL(2), 4n, deadline, await signClaim(server, pool, alice.address, POL(2), 4n, deadline))
    const sig = await signClaim(server, pool, alice.address, POL(2), 5n, deadline)
    await expect(pool.connect(alice).claim(POL(2), 5n, deadline, sig)).to.be.revertedWithCustomError(pool, 'WalletLimitReached')
  })

  it('recusa assinatura falsa, de outro jogador ou vencida', async () => {
    const {pool, owner, alice, mallory, server} = await loadFixture(deploy)
    await fundPool(pool, owner, POL(1000))
    const deadline = (await time.latest()) + 60
    const fake = await signClaim(mallory, pool, mallory.address, POL(1), 6n, deadline)
    await expect(pool.connect(mallory).claim(POL(1), 6n, deadline, fake)).to.be.revertedWithCustomError(pool, 'InvalidSignature')
    const forAlice = await signClaim(server, pool, alice.address, POL(1), 7n, deadline)
    await expect(pool.connect(mallory).claim(POL(1), 7n, deadline, forAlice)).to.be.revertedWithCustomError(pool, 'InvalidSignature')
    await time.increase(120)
    await expect(pool.connect(alice).claim(POL(1), 7n, deadline, forAlice)).to.be.revertedWithCustomError(pool, 'Expired')
  })

  it('migrar para outro contrato exige 7 dias de aviso', async () => {
    const {pool, owner, mallory} = await loadFixture(deploy)
    await fundPool(pool, owner, POL(500))
    expect(pool.interface.getFunction('withdraw', [])).to.equal(null)
    await expect(pool.connect(mallory).proposeMigration(mallory.address)).to.be.revertedWithCustomError(pool, 'OwnableUnauthorizedAccount')
    const newPool = await ethers.deployContract('MysticRewardPool', [owner.address, owner.address, owner.address, 100, POL(100)])
    await pool.proposeMigration(await newPool.getAddress())
    await expect(pool.executeMigration()).to.be.revertedWithCustomError(pool, 'TooEarly')
    await time.increase(7 * 86400)
    await expect(pool.executeMigration()).to.changeEtherBalances([pool, newPool], [-POL(500), POL(500)])
  })

  it('saque de emergencia: na hora, tudo para a tesouraria fixa, e as trocas param', async () => {
    const {pool, owner, treasury, alice, server, mallory} = await loadFixture(deploy)
    await fundPool(pool, owner, POL(500))
    const deadline = (await time.latest()) + 3600
    const sig = await signClaim(server, pool, alice.address, POL(1), 77, deadline)
    await expect(pool.connect(mallory).emergencyWithdraw()).to.be.revertedWithCustomError(pool, 'OwnableUnauthorizedAccount')
    const tx = await pool.emergencyWithdraw()
    await expect(tx).to.changeEtherBalances([pool, treasury, owner], [-POL(500), POL(500), 0])
    await expect(tx).to.emit(pool, 'EmergencyWithdrawn').withArgs(treasury.address, POL(500))
    expect(await pool.paused()).to.equal(true)
    await expect(pool.connect(alice).claim(POL(1), 77, deadline, sig)).to.be.revertedWithCustomError(pool, 'EnforcedPause')
  })

  it('chave do dono roubada: o ladrao so consegue mandar o POL para a tesouraria', async () => {
    const {pool, owner, treasury, mallory} = await loadFixture(deploy)
    await fundPool(pool, owner, POL(300))
    await pool.transferOwnership(mallory.address)
    await pool.connect(mallory).acceptOwnership()
    expect(pool.interface.getFunction('setTreasury', [], true)).to.equal(null)
    await expect(pool.connect(mallory).emergencyWithdraw()).to.changeEtherBalances([treasury, mallory], [POL(300), 0])
  })

  it('teto diario nunca passa de 5% e pausa bloqueia trocas', async () => {
    const {pool, owner, alice, server} = await loadFixture(deploy)
    await expect(pool.setLimits(501, POL(1))).to.be.revertedWithCustomError(pool, 'TooHigh')
    await fundPool(pool, owner, POL(100))
    await pool.pause()
    const deadline = (await time.latest()) + 600
    const sig = await signClaim(server, pool, alice.address, POL(1), 8n, deadline)
    await expect(pool.connect(alice).claim(POL(1), 8n, deadline, sig)).to.be.revertedWithCustomError(pool, 'EnforcedPause')
  })

  it('simulacao: sem nenhuma entrada por 70 dias, sacando o maximo todo dia, o pool nunca zera', async () => {
    const {pool, owner, server} = await loadFixture(deploy)
    const players = (await ethers.getSigners()).slice(6, 16)
    await pool.setLimits(100, POL(1_000_000))
    await fundPool(pool, owner, POL(5_000))
    let nonce = 1000n
    for (let day = 0; day < 70; day++) {
      const p = players[day % players.length]
      const take = await pool.remainingToday()
      const deadline = (await time.latest()) + 3600
      await pool.connect(p).claim(take, nonce, deadline, await signClaim(server, pool, p.address, take, nonce, deadline))
      nonce++
      await time.increase(86400)
    }
    const left = await ethers.provider.getBalance(await pool.getAddress())
    // 0,99^70 = ~49,5% do pool continua la
    expect(left).to.be.greaterThan(POL(2450))
    expect(await pool.totalPaid()).to.be.lessThan(POL(2550))
  })
})
