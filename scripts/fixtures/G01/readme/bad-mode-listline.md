# The Monolith

A live CD with a modern Linux userland. Not tested on Hyper-V.

## Testing

Boot modes (`make test-boot MODE=<mode>`): @MODES@.
`bios`, `bogus`.

```sh
make test-boot MODE=bios
busybox slattach -p slip @SLIPDEV@ &
pppd @PPPDEV@ 115200 noauth local connect "chat -t 60 '' AT OK ATD5551212 CONNECT"
```

Dropbear SSH is available: start it with `dropbear`. `/etc/init.d/S20keygen` generates an @HOSTKEY@ host key on first boot if none exists.
