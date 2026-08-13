# CTMW Android Takeover

For an Android device which is already rooted and already has Termux installed.

1. Copy one fresh, local-only `CTMW-ANDROID-TAKEOVER.bundle.tgz` into Android Download or Termux HOME. The bundle is single-use on the phone.
2. In Termux run one command:

```sh
pkg install -y curl >/dev/null && curl -fsSL https://raw.githubusercontent.com/kongji1/ctmw-android-takeover/main/android-termux-bootstrap.sh | bash
```

The bootstrap auto-allocates `android-nodeN` across N=2..3652, starts a localhost-only Termux sshd plus a restricted VPS loopback reverse tunnel, and never places the Etsa operator private key on the phone. Remote SSH enters the Termux user; root remains explicit through `su`.

After both the local SSH endpoint and VPS reverse tunnel are READY, the imported VPS administrator key and the source `.tgz` are consumed from the phone. A reinstall or repair therefore requires a newly built single-use bundle.

If rooted `/data/adb/service.d` is writable, READY reports reboot-persistent startup. Otherwise READY explicitly reports session-only persistence.
