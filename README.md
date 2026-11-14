# opencode-tailscale-remote

這是一個用來管理多專案 OpenCode 背景服務的 Shell 腳本（`oc-tailnet-ctrl.sh`），讓你可以透過 Tailscale 私人網路從遠端電腦直接接入正在進行中的工作階段。

## 為什麼需要這個工具？

OpenCode 本身支援 Client-Server 架構（`serve` 與 `attach`），這讓遠端連線不需要依賴額外的 SSH 與 `tmux` 就能保持對話狀態。

但在實際同時開發多個專案時，直接把單一 Server 開在所有專案的共同上層目錄，很容易在切換目錄或漏帶參數時載入錯誤專案的 `AGENTS.md` 設定，甚至導致不同專案的上下文汙染。

這個腳本的設計目的，就是把「每個專案綁定獨立資料夾與獨立 Port」這件事標準化：需要遠端工作時按需啟動，並強制隔離各專案的工作目錄與連線密碼，避免背景常駐服務的設定負擔與誤操作風險。

## 核心設計

* **專案目錄與 Port 嚴格一對一綁定**：
	- 不同專案各自啟動獨立的 `opencode serve` 實例，從根本隔絕 `AGENTS.md` 與檔案操作權限；同時防止同一個資料夾被重複啟動在不同 Port 上。
* **無密碼拒絕啟動**：
	- 腳本內不保留任何預設密碼，啟動前依序檢查「腳本內變數 -> Shell 環境變數 -> `~/.oc-tailnet.env` 設定檔」，確認有設定密碼才允許對外監聽。

## 前置需求

在執行服務的開發主機（Linux 桌機、雲端 VM 或 WSL2 環境）上，需要具備以下環境：

1. **OpenCode CLI**：已安裝並加入系統 `PATH`。
2. **Tailscale**：已安裝並完成登入連線（能透過 `tailscale ip -4` 取得 IP）。
   * *WSL2 注意事項*：若 Tailscale 裝在 Windows 端，請確保 Windows 11 的 `.wslconfig` 已開啟 `networkingMode=mirrored`（鏡像網路），或直接在 WSL2 內部安裝 Tailscale。
3. **Port 檢查工具**：系統需有 `ss`（`iproute2`）或 `netstat`（`net-tools`）其中之一。

## 安裝與使用範例

### 1. 在主力開發機（Host）下載與設定

透過 `curl` 直接下載腳本並建立存放連線密碼的設定檔（建議將權限設為僅限本人讀取）：

```bash
curl -fsSL https://raw.githubusercontent.com/andrewintw/opencode-tailscale-remote/main/oc-tailnet-ctrl.sh -o oc-tailnet-ctrl.sh
curl -fsSL https://raw.githubusercontent.com/andrewintw/opencode-tailscale-remote/main/.oc-tailnet.env.example -o .oc-tailnet.env.example
chmod +x oc-tailnet-ctrl.sh

cp .oc-tailnet.env.example ~/.oc-tailnet.env
chmod 600 ~/.oc-tailnet.env
# 編輯 ~/.oc-tailnet.env，將 OPENCODE_SERVER_PASSWORD 改成你自己的安全密碼
```

需要從其他裝置遠端工作時，分別針對不同專案指定獨立的 Port 啟動背景服務：

```bash
# 啟動 Project A（綁定 Port 4096）
./oc-tailnet-ctrl.sh start ~/projects/project-a 4096
```

```bash
# 啟動 Project B（綁定 Port 4097）
./oc-tailnet-ctrl.sh start ~/projects/project-b 4097
```

啟動後，終端機畫面會分別印出對應的遠端連線指令，例如：

```
[INFO] OpenCode server started in background (/home/user/projects/project-a)
[INFO] Remote attach command:

  OPENCODE_SERVER_PASSWORD=設定你的安全密碼 opencode attach http://100.x.y.z:4096
```

```
[INFO] OpenCode server started in background (/home/user/projects/project-b)
[INFO] Remote attach command:

  OPENCODE_SERVER_PASSWORD=設定你的安全密碼 opencode attach http://100.x.y.z:4097
```

### 2. 在隨身筆電（Client）接入工作階段

確保連線端裝置已加入同一個 Tailscale 網路，在終端機開啟不同分頁或視窗，貼上對應的指令即可各自接手 project-a 與 project-b 的工作環境：

```bash
# 視窗 1：接入 Project A
OPENCODE_SERVER_PASSWORD=設定你的安全密碼 opencode attach http://100.x.y.z:4096

# 視窗 2：接入 Project B
OPENCODE_SERVER_PASSWORD=設定你的安全密碼 opencode attach http://100.x.y.z:4097
```

### 3. 查看狀態與關閉服務

隨時在主力開發機（或透過 SSH 連入開發機後）查看目前開了哪些專案與 Port，或針對單一專案關閉背景服務：

```
# 查看目前運行中的所有專案服務
./oc-tailnet-ctrl.sh status

# 停止 Project A（Port 4096）的服務，Project B 不受影響
./oc-tailnet-ctrl.sh stop 4096
```

