# openwrt-sd-auto-upload

## Hardware

* GL.iNetGL-XE300 (Puli)

## Preparations

Have a rsync server ready to receive the files.

```bash
adduser sd-auto-upload1 --disabled-password

cd /home/sd-auto-upload1
root@/home/sd-auto-upload1# ssh-keygen -f uploadkey_ed25519

root@GL-XE300:~/openwrt-sd-auto-upload# vi uploadkey_ed25519
root@GL-XE300:~/openwrt-sd-auto-upload# chmod 600 uploadkey_ed25519 
```

## Packages

```bash
opkg install openssh-client rsync
```

