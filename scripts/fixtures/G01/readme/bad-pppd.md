# The Monolith

A live CD with a modern Linux userland. Not tested on Hyper-V.

## Testing

Boot modes (`make test-boot MODE=<mode>`): @MODES@.

```sh
make test-boot MODE=bios
busybox slattach -p slip @SLIPDEV@ &
pppd /dev/ttyS0 115200 noauth
```

Dropbear SSH is available: start it with `dropbear`. `/etc/init.d/S20keygen` generates an @HOSTKEY@ host key on first boot if none exists.
