# opencode-tailscale-remote

這是一個用來管理多專案 OpenCode 背景服務的 Shell 腳本（`oc-tailnet-ctrl.sh`），讓你可以透過 Tailscale 私人網路從遠端電腦直接接入正在進行中的工作階段。

## 為什麼需要這個工具？

OpenCode 本身支援 Client-Server 架構（`serve` 與 `attach`），這讓遠端連線不需要依賴額外的 SSH 與 `tmux` 就能保持對話狀態。

但在實際同時開發多個專案時，直接把單一 Server 開在所有專案的共同上層目錄，很容易在切換目錄或漏帶參數時載入錯誤專案的 `AGENTS.md` 設定，甚至導致不同專案的上下文汙染。

這個腳本的設計目的，就是把「每個專案綁定獨立資料夾與獨立 Port」這件事標準化：需要遠端工作時按需啟動，並強制隔離各專案的工作目錄與連線密碼，避免背景常駐服務的設定負擔與誤操作風險。

## 核心設計

* **專案目錄與 Port 嚴格一對一綁定**：
	- 不同專案各自啟動獨立的 `opencode serve` 實例，從根本隔絕 `AGENTS.md` 與檔案操作權限；同時防止同一個資料夾被重複啟動在不同 Port 上。
* **預設只綁定 Tailscale IP**：
	- 啟動前確認 Tailscale IPv4 真的存在於本機介面上，預設只監聽該位址，不對 LAN 或公網暴露。
	- 可用 `OPENCODE_BIND_HOST` 明確覆寫（例如 WSL mirrored 且 Tailscale 裝在 Windows 時）。
* **無密碼拒絕啟動**：
	- 腳本內不保留任何預設密碼，啟動前依序檢查「腳本內變數 -> Shell 環境變數 -> `~/.oc-tailnet.env` 設定檔」，確認有設定密碼才允許啟動。
* **精確的 process 辨識**：
	- 透過 `/proc/<pid>/cmdline` 精確比對 `opencode serve --port <port>`，避免 `stop 4096` 誤殺 `--port 40960`。
* **集中且受限的狀態檔**：
	- PID、目錄與日誌存放在 `$XDG_RUNTIME_DIR/opencode-tailnet/`（權限 `700`），不再散落在世界可讀的 `/tmp`。

## 前置需求

在執行服務的開發主機（Linux 桌機、雲端 VM 或 WSL2 環境）上，需要具備以下環境：

1. **OpenCode CLI**：已安裝並加入系統 `PATH`。
2. **Tailscale**：已安裝並完成登入連線（能透過 `tailscale ip -4` 取得 IP）。
3. **網路工具**：需要 `ss`（`iproute2`）或 `netstat`（`net-tools`）其中之一；`ip` 用於檢查 Tailscale IP 是否為本地位址。
4. **Bash 4 以上**（使用 `mapfile`）。

> WSL2 的 Tailscale 安裝位置會影響綁定方式，詳見下方「WSL2 與 Tailscale」章節。

## 安裝與設定

透過 `curl` 下載腳本與範例設定檔，並建立只有本人可讀的密碼檔：

```bash
curl -fsSL https://raw.githubusercontent.com/andrewintw/opencode-tailscale-remote/main/oc-tailnet-ctrl.sh -o oc-tailnet-ctrl.sh
curl -fsSL https://raw.githubusercontent.com/andrewintw/opencode-tailscale-remote/main/.oc-tailnet.env.example -o .oc-tailnet.env.example
chmod +x oc-tailnet-ctrl.sh

cp .oc-tailnet.env.example ~/.oc-tailnet.env
chmod 600 ~/.oc-tailnet.env
# 編輯 ~/.oc-tailnet.env，將 OPENCODE_SERVER_PASSWORD 改成你自己的安全密碼
```

`~/.oc-tailnet.env` 內容範例：

```bash
OPENCODE_SERVER_PASSWORD="設定你的安全密碼"
# 特殊環境才需要，例如 Tailscale 裝在 Windows、OpenCode 在 WSL：
# OPENCODE_BIND_HOST="0.0.0.0"
```

> 不要把 `~/.oc-tailnet.env` 或真實密碼 commit 進版本庫；repo 的 `.gitignore` 已忽略 `.oc-tailnet.env`。

## 使用範例

需要從其他裝置遠端工作時，分別針對不同專案指定獨立的 Port 啟動背景服務：

```bash
# 啟動 Project A（綁定 Port 4096）
./oc-tailnet-ctrl.sh start ~/projects/project-a 4096
```

```bash
# 啟動 Project B（綁定 Port 4097）
./oc-tailnet-ctrl.sh start ~/projects/project-b 4097
```

啟動後會印出監聽位址與遠端連線方式（不會印出密碼）：

```
[DEBUG] Executing: cd /home/user/projects/project-a && nohup env OPENCODE_SERVER_PASSWORD=*** opencode serve --hostname 100.x.y.z --port 4096
[INFO] OpenCode server started in background (/home/user/projects/project-a)
[INFO] Listening on: 100.x.y.z:4096
[INFO] Remote attach command (password from /home/user/.oc-tailnet.env):

  opencode attach http://100.x.y.z:4096
```

查看狀態與關閉服務：

```bash
# 查看目前運行中的所有專案服務（含舊版腳本啟動的 server）
./oc-tailnet-ctrl.sh status

# 停止 Project A（Port 4096）的服務，Project B 不受影響
./oc-tailnet-ctrl.sh stop 4096

# 顯示說明
./oc-tailnet-ctrl.sh help
```

## 從其他裝置連線

確保連線端裝置已加入同一個 Tailscale 網路，然後在終端機輸入密碼並接入：

```bash
# 避免密碼留在 shell history
read -rsp 'OpenCode password: ' OPENCODE_SERVER_PASSWORD && export OPENCODE_SERVER_PASSWORD
opencode attach http://100.x.y.z:4096
```

OpenCode 預設使用者名稱是 `opencode`；若你有自訂，可加上 `-u <username>`。

## 安全性

* **預設只綁 Tailscale IP**：只有 tailnet 內裝置能建立連線；若 Tailscale IP 不是本地位址，腳本會拒絕啟動，而不是默默改成 `0.0.0.0`。
* **`OPENCODE_BIND_HOST=0.0.0.0`**：會監聽所有介面（含 LAN）。使用時務必搭配 Windows Firewall、主機防火牆或 Tailscale ACL 限制來源。
* **密碼檔權限**：`~/.oc-tailnet.env` 應為 `600`；腳本偵測到群組/其他人可讀時會警告。
* **不在終端輸出明文密碼**：避免密碼進入 scrollback、螢幕分享或 CI log。
* **狀態檔權限**：runtime 目錄為 `700`，PID/dir/log 為 `600`。
* **不建議使用 `HARDCODED_PASSWORD`**：雖然支援，但容易誤 commit 或留在 shell 腳本中。

## WSL2 與 Tailscale

WSL2 的 `networkingMode=mirrored` 會讓 WSL 看到 Windows 的網路介面，但 Tailscale 的行為取決於它裝在哪裡：

### 建議：Tailscale 裝在 WSL 內

```bash
# WSL 內
sudo tailscale up
tailscale ip -4        # 100.x.y.z
ip -4 addr show        # 應該看到 tailscale0 持有 100.x.y.z
```

此時預設綁定即可運作，也是網路隔離最乾淨的做法。若使用 systemd（`/etc/wsl.conf` 的 `[boot] systemd=true`），可啟用 `tailscaled` 服務。

### Tailscale 裝在 Windows、OpenCode 在 WSL

100.x 通常不是 WSL 內的本地位址，預設綁定會失敗並提示。此時有兩個選擇：

1. 改在 WSL 內安裝 Tailscale（建議）。
2. 在 `~/.oc-tailnet.env` 設定：
   ```bash
   OPENCODE_BIND_HOST="0.0.0.0"
   ```
   並用 Windows Firewall / Tailscale ACL 限制只有 tailnet 能連到該 Port。

## 狀態檔位置

* 優先：`$XDG_RUNTIME_DIR/opencode-tailnet/<port>.{pid,dir,log}`
* 沒有 `XDG_RUNTIME_DIR` 時：`/tmp/opencode-tailnet-<uid>/`
* 舊版相容：`/tmp/opencode-<port>.dir` 只會被讀取，停止或清理時一併移除。

## 疑難排解

**啟動失敗並顯示 log tail**
- 日誌路徑會印在錯誤訊息中；常見原因是 Port 被佔用或 bind 位址不存在。

**`Tailscale IP ... is not assigned to a local interface`**
- 代表 Tailscale 不在目前的網路命名空間（常見於 Windows-side Tailscale + WSL）。
- 依「WSL2 與 Tailscale」章節處理。

**`bind: cannot assign requested address`**
- 指定的 `OPENCODE_BIND_HOST` 不存在，或 Tailscale 尚未 `up`。

**密碼明明正確卻驗證失敗**
- 檢查 `~/.oc-tailnet.env` 是否含 Windows CRLF：`file ~/.oc-tailnet.env` 或 `sed -n l ~/.oc-tailnet.env`。
- 確認沒有同時設定多個來源（shell 環境變數優先於檔案）。

**Port 被佔用**
- `ss -ltnp "sport = :4096"` 找出佔用者，改用其他 Port 或先停止該服務。

**重開機後服務消失**
- 這是刻意的：本腳本不註冊 systemd 服務，需重新 `start`。

## 替代方案：`tailscale serve`

若不想自行管理密碼與監聽位址，可考慮用 `tailscale serve` 將本機 Port 以 tailnet TLS 方式分享（會帶入 tailnet 身分驗證）。實際語法依 Tailscale 版本而異，例如：

```bash
opencode serve --hostname 127.0.0.1 --port 4096
tailscale serve --bg 4096
```

詳見 Tailscale 官方文件。此模式與本腳本的多專案管理可並存，但兩者的認證模型不同，請擇一使用。
