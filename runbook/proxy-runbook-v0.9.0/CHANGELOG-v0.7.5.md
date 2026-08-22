# v0.7.5

- 修复 Win32-OpenSSH 9.2 系列 `ssh-keyscan.exe` 在 Linux OpenSSH 8.9+ 服务器上错误选择 `sntrup761x25519-sha512@openssh.com` 后立即退出的问题。
- `ssh-keyscan` 全部失败后，使用同套件中不受该缺陷影响的 `ssh.exe` 做一次隔离、无凭据 Host Key 握手。
- 回退握手禁用密码、公钥、键盘交互和提示，只把公开 Host Key 写入一次性临时 `known_hosts`；显示指纹并由用户确认后才写入节点专用长期文件。
- 本机存在多套完整 OpenSSH 时，解析版本并优先使用较新且能实际启动的一套，不再无条件优先旧的 System32 组件。
- 保留 v0.7.4 的远端备份整理、双登录模式、失败关闭和隐私保护；远端脚本没有写入任何真实节点资料。
