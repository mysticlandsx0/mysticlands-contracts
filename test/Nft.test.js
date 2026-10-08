// NFTs do jogo: Plantas / Mother Trees (MysticPlant) e Terrenos (MysticLand).
const {expect} = require('chai')
const {ethers} = require('hardhat')
const {loadFixture} = require('@nomicfoundation/hardhat-toolbox/network-helpers')

async function deploy() {
  const [owner, alice, bob, mallory] = await ethers.getSigners()
  const plants = await ethers.deployContract('MysticPlant', [owner.address, 100_000, 'https://mysticlands.online/api/nft/plant/'])
  const lands = await ethers.deployContract('MysticLand', [owner.address, 10_000, 'https://mysticlands.online/api/nft/land/'])
  const MINTER = await plants.MINTER_ROLE()

  return {owner, alice, bob, mallory, plants, lands, MINTER}
}

describe('MysticPlant / MysticLand', () => {
  it('only minters can mint and traits are validated', async () => {
    const {plants, owner, alice, MINTER} = await loadFixture(deploy)
    await expect(plants.connect(alice).mint(alice.address, 1, 0, 0, 1)).to.be.revertedWithCustomError(plants, 'AccessControlUnauthorizedAccount')
    await plants.grantRole(MINTER, owner.address)
    await expect(plants.mint(alice.address, 40, 0, 0, 1)).to.be.revertedWithCustomError(plants, 'InvalidTraits')
    await expect(plants.mint(alice.address, 94, 0, 0, 1)).to.be.revertedWithCustomError(plants, 'InvalidTraits')
    await expect(plants.mint(alice.address, 1, 3, 0, 1)).to.be.revertedWithCustomError(plants, 'InvalidTraits')
    await expect(plants.mint(alice.address, 1, 0, 4, 1)).to.be.revertedWithCustomError(plants, 'InvalidTraits')
    await plants.mint(alice.address, 92, 2, 3, 77)
    const t = await plants.traitsOf(1)
    expect([t.species, t.variant, t.rarity, t.kind, t.dna]).to.deep.equal([92n, 2n, 3n, 1n, 77n])
  })

  it('enforces the max supply', async () => {
    const [admin, user] = await ethers.getSigners()
    const small = await ethers.deployContract('MysticPlant', [admin.address, 2, ''])
    await small.grantRole(await small.MINTER_ROLE(), admin.address)
    await small.mint(user.address, 0, 0, 0, 0)
    await small.mint(user.address, 0, 0, 0, 0)
    await expect(small.mint(user.address, 0, 0, 0, 0)).to.be.revertedWithCustomError(small, 'MaxSupplyReached')
  })

  it('freezeMinters blocks new minters forever', async () => {
    const {plants, mallory, MINTER} = await loadFixture(deploy)
    await plants.freezeMinters()
    await expect(plants.grantRole(MINTER, mallory.address)).to.be.revertedWithCustomError(plants, 'MintersAreFrozen')
  })

  it('owners can burn and supply is tracked', async () => {
    const {plants, owner, alice, bob, MINTER} = await loadFixture(deploy)
    await plants.grantRole(MINTER, owner.address)
    await plants.mint(alice.address, 5, 0, 0, 0)
    await expect(plants.connect(bob).burn(1)).to.be.revertedWithCustomError(plants, 'ERC721InsufficientApproval')
    await plants.connect(alice).burn(1)
    expect(await plants.totalSupply()).to.equal(0)
    expect(await plants.totalMinted()).to.equal(1)
  })

  it('lands get unique coordinates inside the map', async () => {
    const {lands, owner, alice, MINTER} = await loadFixture(deploy)
    await lands.grantRole(MINTER, owner.address)
    // mesma seed 3x: a celula ocupada faz a proxima ir para a celula seguinte
    for (let i = 0; i < 3; i++) await lands.mint(alice.address, 0, 12345)
    const seen = new Set()
    for (let id = 1; id <= 3; id++) {
      const l = await lands.landOf(id)
      expect(l.x).to.be.within(-100, 100)
      expect(l.y).to.be.within(-100, 100)
      seen.add(`${l.x},${l.y}`)
    }
    expect(seen.size).to.equal(3)
  })
})
