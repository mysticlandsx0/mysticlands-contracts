// Loja de NFTs em POL (preco em dolar, Mother Tree so pela semente) e Marketplace em POL.
const {expect} = require('chai')
const {ethers} = require('hardhat')
const {loadFixture, time} = require('@nomicfoundation/hardhat-toolbox/network-helpers')

const POL = (n) => ethers.parseEther(String(n))
const USD = (n) => BigInt(Math.round(n * 1e8))

async function deploy() {
  const [owner, treasury, alice, bob, server, mallory] = await ethers.getSigners()
  const plants = await ethers.deployContract('MysticPlant', [owner.address, 1_000_000, ''])
  const lands = await ethers.deployContract('MysticLand', [owner.address, 10_000, ''])
  const coordinator = await ethers.deployContract('VRFCoordinatorMock')
  const feed = await ethers.deployContract('PriceFeedMock', [USD(0.1)]) // POL = US$ 0,10
  const pool = await ethers.deployContract('MysticRewardPool', [owner.address, treasury.address, server.address, 100, POL(100)])
  const splitter = await ethers.deployContract('MysticRevenueSplitter', [owner.address, treasury.address, await pool.getAddress(), 4000])
  const vrf = {subscriptionId: 1n, keyHash: ethers.ZeroHash, callbackGasLimit: 2_000_000, requestConfirmations: 3, nativePayment: true}
  const shop = await ethers.deployContract('MysticNftShop', [
    await coordinator.getAddress(), await plants.getAddress(), await lands.getAddress(), await splitter.getAddress(), await feed.getAddress(), vrf
  ])
  const MINTER = await plants.MINTER_ROLE()
  await plants.grantRole(MINTER, await shop.getAddress())
  await lands.grantRole(MINTER, await shop.getAddress())
  const market = await ethers.deployContract('MysticMarketPol', [owner.address, await splitter.getAddress(), 500])
  await market.setCollection(await plants.getAddress(), true)
  await market.setCollection(await lands.getAddress(), true)

  return {owner, treasury, alice, bob, server, mallory, plants, lands, coordinator, feed, pool, splitter, shop, market}
}

const requestIdOf = async (shop, tx) => {
  const receipt = await tx.wait()
  for (const log of receipt.logs) {
    try {
      const parsed = shop.interface.parseLog(log)
      if (parsed && (parsed.name === 'Purchased' || parsed.name === 'SeedVoucherRedeemed')) return parsed.args.requestId
    } catch {}
  }
  throw new Error('requestId not found')
}

// compra, entrega o sorteio e cria todos os NFTs
const buyAndClaim = async ({shop, coordinator}, buyer, productId, quantity, word) => {
  const price = await shop.priceInPol(productId)
  const id = await requestIdOf(shop, await shop.connect(buyer).buy(productId, quantity, {value: price * BigInt(quantity)}))
  await coordinator.fulfill(id, word)
  for (let i = 0; i < 20 && (await shop.orders(id)).buyer !== ethers.ZeroAddress; i++) await shop.claim(id, 50)

  return id
}

describe('Loja de NFTs em POL', () => {
  it('precos em dolar: semente US$ 3, kit US$ 13, terreno US$ 100, Efficient US$ 150, Landlord US$ 500', async () => {
    const {shop} = await loadFixture(deploy)
    // POL a US$ 0,10 => preco em POL = dolar x 10
    expect(await shop.priceInPol(1)).to.equal(POL(30))
    expect(await shop.priceInPol(2)).to.equal(POL(130))
    expect(await shop.priceInPol(3)).to.equal(POL(1000))
    expect(await shop.priceInPol(4)).to.equal(POL(1500))
    expect(await shop.priceInPol(5)).to.equal(POL(5000))
    const kit = await shop.products(2)
    expect([kit.plants, kit.lands]).to.deep.equal([6n, 0n])
    const landlord = await shop.products(5)
    expect([landlord.plants, landlord.lands]).to.deep.equal([90n, 3n])
  })

  it('o POL vai 60% tesouraria / 40% pool, e o troco volta ao comprador', async () => {
    const {shop, alice, treasury, pool} = await loadFixture(deploy)
    const tx = await shop.connect(alice).buy(2, 1, {value: POL(150)}) // kit custa 130; manda 150
    await expect(tx).to.changeEtherBalances([alice, treasury, pool, shop], [-POL(130), POL(78), POL(52), 0])
  })

  it('pagando menos que o preco, recusa; produto inexistente ou quantidade absurda, recusa', async () => {
    const {shop, alice} = await loadFixture(deploy)
    await expect(shop.connect(alice).buy(1, 1, {value: POL(29)})).to.be.revertedWithCustomError(shop, 'Underpaid')
    await expect(shop.connect(alice).buy(9, 1, {value: POL(30)})).to.be.revertedWithCustomError(shop, 'InvalidProduct')
    await expect(shop.connect(alice).buy(5, 4, {value: 0})).to.be.revertedWithCustomError(shop, 'InvalidQuantity')
    await expect(shop.connect(alice).buy(1, 0, {value: 0})).to.be.revertedWithCustomError(shop, 'InvalidQuantity')
  })

  it('cotacao velha ou invalida trava a venda (ninguem compra a preco errado)', async () => {
    const {shop, feed, alice} = await loadFixture(deploy)
    await feed.set(USD(0.1), (await time.latest()) - 2 * 86400)
    await expect(shop.connect(alice).buy(1, 1, {value: POL(30)})).to.be.revertedWithCustomError(shop, 'StalePrice')
    await feed.set(0, await time.latest())
    await expect(shop.priceInPol(1)).to.be.revertedWithCustomError(shop, 'InvalidPrice')
  })

  it('Landlord entrega 90 plantas + 3 terrenos a quem comprou', async () => {
    const f = await loadFixture(deploy)
    await buyAndClaim(f, f.alice, 5, 1, 12345n)
    expect(await f.plants.balanceOf(f.alice.address)).to.equal(90)
    expect(await f.lands.balanceOf(f.alice.address)).to.equal(3)
  })

  it('Mother Tree nunca e vendida direto: sai so da semente, perto de 2% delas', async () => {
    const f = await loadFixture(deploy)
    await f.feed.set(USD(10), await time.latest()) // POL caro no teste para caber no saldo
    for (let i = 0; i < 5; i++) await buyAndClaim(f, f.alice, 5, 2, 1000n + BigInt(i)) // 900 sementes
    const ids = await f.plants.tokensOfOwner(f.alice.address)
    const traits = await f.plants.traitsBatch([...ids])
    const mothers = traits.filter((t) => Number(t.species) >= 90).length
    const species = new Set(traits.filter((t) => Number(t.species) >= 90).map((t) => Number(t.species)))
    expect(ids.length).to.equal(900)
    expect(mothers).to.be.within(6, 36) // ~18 esperadas (2%)
    expect([...species].every((s) => s >= 90 && s <= 93)).to.equal(true)
    // sem nenhum produto de Mother Tree
    for (let id = 1; id <= 5; id++) expect((await f.shop.products(id)).plants + (await f.shop.products(id)).lands).to.be.greaterThan(0)
  })

  it('so o dono muda precos e a chance de Mother Tree (no maximo 10%)', async () => {
    const {shop, mallory} = await loadFixture(deploy)
    await expect(shop.connect(mallory).setProduct(1, USD(0.01), 1, 0, true)).to.be.revertedWith('Only callable by owner')
    await expect(shop.setMotherChance(1001)).to.be.revertedWithCustomError(shop, 'TooHigh')
    await shop.setMotherChance(300)
    expect(await shop.motherBps()).to.equal(300)
    await shop.setProduct(3, USD(120), 0, 1, true)
    expect(await shop.priceInPol(3)).to.equal(POL(1200))
  })

  it('voucher de sementes do jogo: assinado pelo servidor, uma vez so', async () => {
    const {shop, server, alice, mallory, coordinator, plants} = await loadFixture(deploy)
    await shop.setSeedSigner(server.address, 500)
    const deadline = (await time.latest()) + 3600
    const {chainId} = await ethers.provider.getNetwork()
    const sig = await server.signTypedData(
      {name: 'MysticLands Seeds', version: '1', chainId, verifyingContract: await shop.getAddress()},
      {SeedVoucher: [{name: 'player', type: 'address'}, {name: 'quantity', type: 'uint16'}, {name: 'nonce', type: 'uint256'}, {name: 'deadline', type: 'uint256'}]},
      {player: alice.address, quantity: 3, nonce: 5, deadline}
    )
    await expect(shop.connect(mallory).redeemSeedVoucher(3, 5, deadline, sig)).to.be.revertedWithCustomError(shop, 'InvalidVoucher')
    const id = await requestIdOf(shop, await shop.connect(alice).redeemSeedVoucher(3, 5, deadline, sig))
    await expect(shop.connect(alice).redeemSeedVoucher(3, 5, deadline, sig)).to.be.revertedWithCustomError(shop, 'VoucherUsed')
    await coordinator.fulfill(id, 77n)
    await shop.claim(id, 10)
    expect(await plants.balanceOf(alice.address)).to.equal(3)
  })

  it('pausa bloqueia compras', async () => {
    const {shop, alice} = await loadFixture(deploy)
    await shop.pause()
    await expect(shop.connect(alice).buy(1, 1, {value: POL(30)})).to.be.revertedWithCustomError(shop, 'EnforcedPause')
  })
})

describe('Marketplace em POL', () => {
  const setup = async () => {
    const f = await loadFixture(deploy)
    await buyAndClaim(f, f.alice, 2, 1, 4242n) // alice ganha 6 plantas
    const [first, second] = await f.plants.tokensOfOwner(f.alice.address)
    await f.plants.connect(f.alice).setApprovalForAll(await f.market.getAddress(), true)

    return {...f, first, second, plant: await f.plants.getAddress()}
  }

  it('venda: 95% para o vendedor, 5% de taxa dividida 60/40, NFT para o comprador', async () => {
    const {market, plants, plant, first, alice, bob, treasury, pool} = await setup()
    await market.connect(alice).list(plant, first, POL(100))
    const tx = await market.connect(bob).buy(plant, first, {value: POL(100)})
    await expect(tx).to.changeEtherBalances([bob, alice, treasury, pool, market], [-POL(100), POL(95), POL(3), POL(2), 0])
    expect(await plants.ownerOf(first)).to.equal(bob.address)
    expect(await market.activeCount()).to.equal(0)
  })

  it('valor diferente do preco anunciado e recusado (protege contra troca de preco)', async () => {
    const {market, plant, first, alice, bob} = await setup()
    await market.connect(alice).list(plant, first, POL(100))
    await expect(market.connect(bob).buy(plant, first, {value: POL(99)})).to.be.revertedWithCustomError(market, 'WrongPayment')
    await expect(market.connect(bob).buy(plant, first, {value: POL(101)})).to.be.revertedWithCustomError(market, 'WrongPayment')
  })

  it('anuncio de NFT que o vendedor ja passou adiante nao pode ser comprado', async () => {
    const {market, plants, plant, first, alice, bob, mallory} = await setup()
    await market.connect(alice).list(plant, first, POL(100))
    await plants.connect(alice).transferFrom(alice.address, mallory.address, first)
    await expect(market.connect(bob).buy(plant, first, {value: POL(100)})).to.be.revertedWithCustomError(market, 'StaleListing')
  })

  it('vendedor que recusa POL nao trava a compra: o valor fica guardado para ele sacar', async () => {
    const {market, plants, plant, first, alice, bob} = await setup()
    const seller = await ethers.deployContract('RejectingSeller')
    await plants.connect(alice).transferFrom(alice.address, await seller.getAddress(), first)
    await seller.listOn(await market.getAddress(), plant, first, POL(50))
    await market.connect(bob).buy(plant, first, {value: POL(50)})
    expect(await plants.ownerOf(first)).to.equal(bob.address)
    expect(await market.pendingWithdrawals(await seller.getAddress())).to.equal(POL(47.5))
  })

  it('comprador que tenta comprar de novo dentro da compra (reentrada) e barrado', async () => {
    const {market, plant, first, second, alice} = await setup()
    await market.connect(alice).list(plant, first, POL(10))
    await market.connect(alice).list(plant, second, POL(10))
    const attacker = await ethers.deployContract('ReentrantPolBuyer')
    await expect(attacker.attack(await market.getAddress(), plant, first, second, POL(10), POL(10), {value: POL(20)})).to.be.reverted
  })

  it('taxa travada no anuncio, teto de 10%, e so colecoes autorizadas', async () => {
    const {market, plant, first, alice, bob, mallory} = await setup()
    await market.connect(alice).list(plant, first, POL(100))
    await market.setFee(1000)
    await expect(market.setFee(1001)).to.be.revertedWithCustomError(market, 'FeeTooHigh')
    await expect(market.connect(bob).buy(plant, first, {value: POL(100)})).to.changeEtherBalance(alice, POL(95)) // 5% do anuncio
    await expect(market.connect(mallory).list(mallory.address, 1, POL(1))).to.be.revertedWithCustomError(market, 'CollectionNotAllowed')
  })
})
