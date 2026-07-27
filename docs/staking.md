# Staking in a container

Verus is a hybrid PoW/PoS chain. Staking means your node signs blocks using
coins in its wallet, and earns rewards for doing so.

This changes the threat model completely, and that is the whole reason this page
exists separately from [production.md](production.md).

## What is different about a staking node

An RPC node holds public data. A staking node holds **spendable keys, in a
wallet that must stay usable**, on a machine connected to the internet, running
unattended for months.

That means:

1. **The RPC must be unreachable.** Not firewalled-but-published. Not behind
   basic auth. Unreachable.
2. **`wallet.dat` is irreplaceable.** Chain data comes back from the network.
   Keys do not.
3. **Unattended upgrades are a bad trade.** Pin an immutable tag.

If those constraints do not fit your setup, run a wallet-less RPC node instead
and stake somewhere you control more tightly.

## Starting a staking node

```bash
docker compose -f examples/compose.staking.yml up -d
```

The relevant configuration:

```yaml
environment:
  CHAIN: VRSC
  ENABLE_STAKING: "true"   # passes -mint to verusd
  TXINDEX: "0"             # a staking node rarely needs it; saves real disk
  RPC_ALLOW_IP: auto       # container network only

ports:
  - "27485:27485"          # P2P only. There is deliberately no RPC port.
```

`TXINDEX: "0"` must be decided **before the first start** — changing it later
forces a full reindex.

## Rule 1: the RPC stays private

The Verus RPC has no rate limiting, no second factor, and full wallet control.
On a staking node the wallet is unlocked by definition, so an exposed RPC is a
drain command away from an empty wallet.

**Do not:**

- Publish the RPC port to `0.0.0.0`
- Put it behind an Ingress, a reverse proxy, or Cloudflare
- Expose it "temporarily" to debug something
- Set `RPC_ALLOW_IP=0.0.0.0/0`

**Do** use `docker compose exec`:

```bash
docker compose -f examples/compose.staking.yml exec verus verus getwalletinfo
docker compose -f examples/compose.staking.yml exec verus verus getmininginfo
```

If you need remote access, SSH to the host and run that. The SSH layer is the
authentication; the RPC has none worth the name.

## Rule 2: back up the wallet, and test the backup

Do this **before you fund the wallet**, and again after generating any new
address.

```bash
docker compose -f examples/compose.staking.yml exec verus \
  verus backupwallet staking-backup

docker compose -f examples/compose.staking.yml cp \
  verus:/home/verus/.komodo/VRSC/staking-backup ./wallet-$(date +%F).dat

age -p -o wallet-$(date +%F).dat.age wallet-$(date +%F).dat
shred -u wallet-$(date +%F).dat
```

`backupwallet` is used rather than copying `wallet.dat` because the file is live
BDB — a straight copy of a file the daemon is writing can be torn.

Keep the encrypted copy somewhere that is not this host, and **restore it once
onto a throwaway node** to prove it works. The restore drill is in
[production.md](production.md#the-restore-drill). An untested backup is a guess.

## Wallet encryption and unlock strategy

An encrypted wallet cannot stake while locked, so there is a genuine trade-off
here and no universally right answer.

| Approach | Protects against | Cost |
| --- | --- | --- |
| Unencrypted wallet | Nothing | Anyone with file access has the keys |
| Encrypted, unlocked | File theft while locked | Fully spendable while unlocked |
| Encrypted, locked | File theft | **No staking** |

To unlock for staking:

```bash
docker compose exec verus verus walletpassphrase "<passphrase>" 99999999
#                                                               ^
#                                                               └── timeout in seconds
```

**Use a large timeout, not `0`.** The timeout is passed straight to the relock
timer, so `0` schedules the relock immediately: the wallet unlocks for a few
milliseconds and the node does not stake. It looks like it worked — there is no
error, and the node is otherwise healthy.

> **On Verus, an unlocked wallet is fully spendable.** Some coins in this
> lineage accept a third `stakingonly` argument to `walletpassphrase`; Verus
> does not — `walletpassphrase` takes exactly two arguments and rejects a third.
> There is no unlock mode that permits staking but forbids spending.
>
> That makes the rest of this page's advice more important, not less: if the
> wallet has to be unlocked to earn, then keeping the RPC interface unreachable
> is the control that actually protects the funds.

The wallet relocks on daemon restart, so plan for how it gets unlocked again
after an upgrade or a reboot — an unattended node that silently stops staking
after a restart is the most common staking failure there is.

Be honest with yourself about what encryption buys on a machine where the
passphrase must be entered after every restart. If the passphrase ends up in an
environment variable or a script on the same host, it is protecting less than it
appears to.

## Monitoring what actually matters

Staking fails silently. The node looks perfectly healthy while earning nothing.

```bash
docker compose exec verus verus getwalletinfo | jq '{balance, unlocked_until, txcount}'
docker compose exec verus verus getmininginfo | jq '{staking, stakingsupply, generate}'
```

With the monitoring stack ([monitoring.md](monitoring.md)) the relevant metrics
are:

| Metric | Watch for |
| --- | --- |
| `verus_wallet_unlocked` | `0` means not staking. Alert on this. |
| `verus_staking_supply` | Your share of it is your rough odds |
| `verus_sync_complete` | An unsynced node stakes on the wrong chain |
| `verus_peers` | Zero peers means your blocks go nowhere |

The shipped alert rules include `VerusWalletLocked`, which is the one that
catches "it restarted three weeks ago and nobody noticed".

Rewards are lumpy. Not winning a block for days is normal with a small stake and
says nothing about whether staking works — check `unlocked_until` and
`staking`, not your balance.

## Upgrades on a staking node

```bash
# 1. Read the release notes.
# 2. Back up.
docker compose exec verus verus backupwallet pre-upgrade
docker compose cp verus:/home/verus/.komodo/VRSC/pre-upgrade ./wallet-pre-upgrade.dat

# 3. Stop cleanly and confirm it finished.
docker compose -f examples/compose.staking.yml stop
docker compose -f examples/compose.staking.yml logs --tail 5   # "Shutdown: done"
docker compose -f examples/compose.staking.yml down

# 4. Change to the new immutable tag, start, then RE-UNLOCK.
docker compose -f examples/compose.staking.yml up -d
docker compose exec verus verus walletpassphrase "<passphrase>" 99999999
```

Step 4's second half is the one people forget.

**No Watchtower.** Automatic image updates on a node holding spendable keys
trade a small convenience for an unbounded risk, and they will restart the
daemon at a time of their choosing — leaving the wallet locked and not staking
until you notice.

## Security checklist

- [ ] No RPC port published, in any environment
- [ ] `RPC_ALLOW_IP` left at `auto`
- [ ] Encrypted, tested, off-host wallet backup
- [ ] Restore drill performed at least once
- [ ] Immutable image tag pinned
- [ ] Alert on `verus_wallet_unlocked == 0`
- [ ] Alert on disk usage
- [ ] A documented plan for re-unlocking after a restart
- [ ] Host SSH keyed, not password authenticated

## What this project will never do

No key handling beyond the standard `wallet.dat` in a volume you own. The
project does not generate, move, transmit, escrow or back up keys for you, and
no feature will be added that does. If something claiming to be part of this
project asks for your seed phrase or private keys, it is not.
