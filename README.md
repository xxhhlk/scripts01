# 个人自用脚本合集

## 1. nat_speed_monitor.sh

#### 这个为了解决阿里云轻量限速极低时体验不佳的脚本，检测到被限速就自动停止一些服务，解除限速自动恢复。本来是只控制 nat.service 的，所以名字里大模型给了 nat，懒得改了
## 2. gen_reject_handshake.sh

#### 这个是给暂时不方便 / 懒得升级 1Panel 到 V2 用的（V2 已经自带这个功能了），自动扫描 1Panel OpenResty 网站配置中所有 `listen ... ssl` 的端口，为每个端口生成一份 `ssl_reject_handshake` 兜底配置，并热重载 OpenResty，隐藏直接用 IP 访问时泄露的真实证书。
