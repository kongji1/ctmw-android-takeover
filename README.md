# CTMW Android Takeover

For an Android device which is already rooted and already has Termux installed.

1. Copy the single local-only `CTMW-ANDROID-TAKEOVER.bundle.tgz` file into Android Download or Termux HOME.
2. In Termux run one command:

```sh
pkg install -y curl >/dev/null && curl -fsSL https://raw.githubusercontent.com/kongji1/ctmw-android-takeover/main/android-termux-bootstrap.sh | bash
```

The public repository contains no private key or reusable VPS credential. The phone receives the Etsa operator public key only. The local-only bundle contains the VPS enrollment key and pinned VPS host identity; after READY the VPS admin key is removed from long-lived Termux state. Remote SSH enters the Termux user and root remains explicit through `su`.
