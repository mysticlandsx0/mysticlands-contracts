// Loja de NFTs em POL (preco em dolar, seed germina 24h antes do sorteio, Mother Tree so pela seed) e Marketplace em POL.
const {expect} = require('chai')
const {ethers} = require('hardhat')
const {loadFixture, time} = require('@nomicfoundation/hardhat-toolbox/network-helpers')

const POL = (n) => ethers.parseEther(String(n))
const USD = (n) => BigInt(Math.round(n * 1e8))
const DAY = 86400

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

const orderIdOf = async (shop, tx) => {
  const receipt = await tx.wait()
  for (const log of receipt.logs) {
    try {
      const parsed = shop.interface.parseLog(log)
      if (parsed && (parsed.name === 'Purchased' || parsed.name === 'SeedVoucherRedeemed')) return parsed.args.orderId
    } catch {}
  }
  throw new Error('orderId not found')
}

// germina (seeds: depois de 24h), entrega o sorteio da Chainlink e cria todos os NFTs
const growAndClaim = async ({shop, coordinator}, id, word) => {
  if (Number((await shop.orders(id)).plants) > 0) await time.increase(DAY)
  await shop.germinate(id)
  await coordinator.fulfill((await shop.orders(id)).vrfRequestId, word)
  for (let i = 0; i < 20 && (await shop.orders(id)).buyer !== ethers.ZeroAddress; i++) await shop.claim(id, 50)
}

// compra, germina, sorteia e cria todos os NFTs
const buyAndClaim = async (f, buyer, productId, quantity, word) => {
  const price = await f.shop.priceInPol(productId)
  const id = await orderIdOf(f.shop, await f.shop.connect(buyer).buy(productId, quantity, {value: price * BigInt(quantity)}))
  await growAndClaim(f, id, word)

  return id
}

describe('Loja de NFTs em POL', () => {
  it('precos em dolar: seed US$ 10, kit US$ 17, terreno US$ 100, Efficient US$ 150, Landlord US$ 500', async () => {
    const {shop} = await loadFixture(deploy)
    // POL a US$ 0,10 => preco em POL = dolar x 10
    expect(await shop.priceInPol(1)).to.equal(POL(100))
    expect(await shop.priceInPol(2)).to.equal(POL(170))
    expect(await shop.priceInPol(3)).to.equal(POL(1000))
    expect(await shop.priceInPol(4)).to.equal(POL(1500))
    expect(await shop.priceInPol(5)).to.equal(POL(5000))
    const kit = await shop.products(2)
    expect([kit.plants, kit.lands]).to.deep.equal([2n, 0n])
    const landlord = await shop.products(5)
    expect([landlord.plants, landlord.lands]).to.deep.equal([25n, 3n])
    expect(await shop.motherBps()).to.equal(100)
  })

  it('o POL vai 60% tesouraria / 40% pool, e o troco volta ao comprador', async () => {
    const {shop, alice, treasury, pool} = await loadFixture(deploy)
    const tx = await shop.connect(alice).buy(2, 1, {value: POL(190)}) // kit custa 170; manda 190
    await expect(tx).to.changeEtherBalances([alice, treasury, pool, shop], [-POL(170), POL(102), POL(68), 0])
  })

  it('a seed germina 24h antes do sorteio: ninguem sabe o resultado antes disso', async () => {
    const {shop, alice, coordinator, plants} = await loadFixture(deploy)
    const id = await orderIdOf(shop, await shop.connect(alice).buy(1, 1, {value: POL(100)}))
    const o = await shop.orders(id)
    expect(o.requestedAt).to.equal(0) // nenhum pedido de aleatoriedade ainda
    expect(o.vrfRequestId).to.equal(0)
    expect(await shop.openOrdersOf(alice.address)).to.deep.equal([id])
    await expect(shop.germinate(id)).to.be.revertedWithCustomError(shop, 'StillGerminating')
    await time.increase(DAY - 10)
    await expect(shop.germinate(id)).to.be.revertedWithCustomError(shop, 'StillGerminating')
    await expect(shop.claim(id, 5)).to.be.revertedWithCustomError(shop, 'NotReady')
    await time.increase(10)
    await expect(shop.connect(alice).germinate(id)).to.emit(shop, 'Germinated')
    await expect(shop.germinate(id)).to.be.revertedWithCustomError(shop, 'AlreadyGerminated')
    await coordinator.fulfill((await shop.orders(id)).vrfRequestId, 31337n)
    await shop.claim(id, 5)
    expect(await plants.balanceOf(alice.address)).to.equal(1)
    expect(await shop.openOrdersOf(alice.address)).to.deep.equal([])
  })

  it('terreno avulso nao germina: pode sortear na hora', async () => {
    const f = await loadFixture(deploy)
    await f.feed.set(USD(10), await time.latest())
    const id = await orderIdOf(f.shop, await f.shop.connect(f.alice).buy(3, 1, {value: POL(10)}))
    await f.shop.germinate(id)
    await f.coordinator.fulfill((await f.shop.orders(id)).vrfRequestId, 5n)
    await f.shop.claim(id, 5)
    expect(await f.lands.balanceOf(f.alice.address)).to.equal(1)
  })

  it('Chainlink sem resposta: 1 dia depois da germinacao qualquer um pede de novo e a resposta antiga e ignorada', async () => {
    const {shop, alice, coordinator, plants} = await loadFixture(deploy)
    const id = await orderIdOf(shop, await shop.connect(alice).buy(1, 1, {value: POL(100)}))
    await expect(shop.retryRandomness(id)).to.be.revertedWithCustomError(shop, 'NotGerminated')
    await time.increase(DAY)
    await shop.germinate(id)
    const first = (await shop.orders(id)).vrfRequestId
    await expect(shop.retryRandomness(id)).to.be.revertedWithCustomError(shop, 'TooEarly')
    await time.increase(DAY)
    await shop.retryRandomness(id)
    const second = (await shop.orders(id)).vrfRequestId
    expect(second).to.not.equal(first)
    await coordinator.fulfill(first, 1n) // resposta atrasada do pedido antigo: ignorada
    expect((await shop.orders(id)).ready).to.equal(false)
    await coordinator.fulfill(second, 2n)
    await shop.claim(id, 5)
    expect(await plants.balanceOf(alice.address)).to.equal(1)
  })

  it('pagando menos que o preco, recusa; produto inexistente ou quantidade absurda, recusa', async () => {
    const {shop, alice} = await loadFixture(deploy)
    await expect(shop.connect(alice).buy(1, 1, {value: POL(99)})).to.be.revertedWithCustomError(shop, 'Underpaid')
    await expect(shop.connect(alice).buy(9, 1, {value: POL(100)})).to.be.revertedWithCustomError(shop, 'InvalidProduct')
    await expect(shop.connect(alice).buy(5, 11, {value: 0})).to.be.revertedWithCustomError(shop, 'InvalidQuantity')
    await expect(shop.connect(alice).buy(1, 0, {value: 0})).to.be.revertedWithCustomError(shop, 'InvalidQuantity')
  })

  it('cotacao velha ou invalida trava a venda (ninguem compra a preco errado)', async () => {
    const {shop, feed, alice} = await loadFixture(deploy)
    await feed.set(USD(0.1), (await time.latest()) - 2 * DAY)
    await expect(shop.connect(alice).buy(1, 1, {value: POL(100)})).to.be.revertedWithCustomError(shop, 'StalePrice')
    await feed.set(0, await time.latest())
    await expect(shop.priceInPol(1)).to.be.revertedWithCustomError(shop, 'InvalidPrice')
  })

  it('Landlord entrega 25 plantas + 3 terrenos a quem comprou', async () => {
    const f = await loadFixture(deploy)
    await f.feed.set(USD(10), await time.latest())
    await buyAndClaim(f, f.alice, 5, 1, 12345n)
    expect(await f.plants.balanceOf(f.alice.address)).to.equal(25)
    expect(await f.lands.balanceOf(f.alice.address)).to.equal(3)
  })

  it('Mother Tree nunca e vendida direto: sai so da seed, perto de 1% delas', async () => {
    const f = await loadFixture(deploy)
    await f.shop.setProduct(6, USD(1), 200, 0, true) // pacote de teste com 200 seeds
    await f.shop.setPricing(await f.feed.getAddress(), 30 * DAY) // o teste avanca varios dias
    await f.feed.set(USD(10), await time.latest()) // POL caro no teste para caber no saldo
    for (let i = 0; i < 5; i++) await buyAndClaim(f, f.alice, 6, 1, 1000n + BigInt(i)) // 1.000 seeds
    const ids = await f.plants.tokensOfOwner(f.alice.address)
    const traits = await f.plants.traitsBatch([...ids])
    const mothers = traits.filter((t) => Number(t.species) >= 90).length
    const species = new Set(traits.filter((t) => Number(t.species) >= 90).map((t) => Number(t.species)))
    expect(ids.length).to.equal(1000)
    expect(mothers).to.be.within(2, 24) // ~10 esperadas (1%)
    expect([...species].every((s) => s >= 90 && s <= 93)).to.equal(true)
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

  it('voucher de seeds do jogo: assinado pelo servidor, uma vez so, e tambem germina 24h', async () => {
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
    const id = await orderIdOf(shop, await shop.connect(alice).redeemSeedVoucher(3, 5, deadline, sig))
    await expect(shop.connect(alice).redeemSeedVoucher(3, 5, deadline, sig)).to.be.revertedWithCustomError(shop, 'VoucherUsed')
    await expect(shop.germinate(id)).to.be.revertedWithCustomError(shop, 'StillGerminating')
    await growAndClaim({shop, coordinator}, id, 77n)
    expect(await plants.balanceOf(alice.address)).to.equal(3)
  })

  it('pausa bloqueia compras e a germinacao', async () => {
    const {shop, alice} = await loadFixture(deploy)
    const id = await orderIdOf(shop, await shop.connect(alice).buy(1, 1, {value: POL(100)}))
    await shop.pause()
    await expect(shop.connect(alice).buy(1, 1, {value: POL(100)})).to.be.revertedWithCustomError(shop, 'EnforcedPause')
    await time.increase(DAY)
    await expect(shop.germinate(id)).to.be.revertedWithCustomError(shop, 'EnforcedPause')
  })
})

describe('Marketplace em POL', () => {
  const setup = async () => {
    const f = await loadFixture(deploy)
    await buyAndClaim(f, f.alice, 2, 1, 4242n) // alice ganha 2 plantas
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
