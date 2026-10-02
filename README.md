# 个人自用脚本合集

## 1. nat_speed_monitor.sh

#### 这个为了解决阿里云轻量限速极低时体验不佳的脚本，检测到被限速就自动停止一些服务，解除限速自动恢复。本来是只控制 nat.service 的，所以名字里大模型给了 nat，懒得改了
## 2. gen_reject_handshake.sh

#### 这个是给暂时不方便 / 懒得升级 1Panel 到 V2 用的（V2 已经自带这个功能了），自动扫描 1Panel OpenResty 网站配置中所有 `listen ... ssl` 的端口，为每个端口生成一份 `ssl_reject_handshake` 兜底配置，并热重载 OpenResty，隐藏直接用 IP 访问时泄露的真实证书。
## 3. cake_qos.sh

#### CAKE 双模式 QoS 脚本：基于 tc/HTB + cake 的共享总额或独立限速方案，支持 eth0 与 tailscale0 隧道双向重定向限速，可配合 cgroup mark 做单服务限速。

## 4. cold_read_check.py | cold_tiny_check.py
#### cold_read_check.py：只读诊断 SSD 冷数据掉速 —— FILE_FLAG_NO_BUFFERING 直读绕页缓存 + 参考文件归一化 + 同体积档基准，全程零写入目标盘。（参考了 https://github.com/infrost/ColDataRefresh 感谢）
#### cold_tiny_check.py 小文件专用 —— 用 4KB 随机读延迟分布（而非吞吐）对比冷/暖组，绕开"读取量被文件大小锁死"的死结
