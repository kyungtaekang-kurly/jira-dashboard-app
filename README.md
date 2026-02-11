# Kurly Jira

Jira 프로젝트 대시보드 앱 (macOS)

## 설치 (원클릭)

터미널에서 아래 명령어 한 줄을 실행하면 자동으로 다운로드 → 설치 완료됩니다:

```bash
curl -sL https://raw.githubusercontent.com/kyungtaekang-kurly/jira-dashboard-app/main/install.sh | bash
```

## 수동 다운로드

| Apple Silicon (M1/M2/M3/M4) | Intel Mac |
|:---:|:---:|
| [Download DMG (aarch64)](https://github.com/kyungtaekang-kurly/jira-dashboard-app/releases/latest/download/Kurly.Jira_0.1.0_aarch64.dmg) | [Download DMG (x64)](https://github.com/kyungtaekang-kurly/jira-dashboard-app/releases/latest/download/Kurly.Jira_0.1.0_x64.dmg) |

> 수동 설치 시 "손상된 파일" 경고가 나오면: `xattr -cr /Applications/Kurly\ Jira.app`

> 모든 릴리스 목록은 [Releases](https://github.com/kyungtaekang-kurly/jira-dashboard-app/releases) 페이지에서 확인할 수 있습니다.

## 자동 업데이트

앱 실행 시 새 버전이 있으면 업데이트 다이얼로그가 자동으로 표시됩니다.

## 개발 환경

- [Node.js](https://nodejs.org/) (LTS)
- [Rust](https://www.rust-lang.org/)
- [VS Code](https://code.visualstudio.com/) + [Vue - Official](https://marketplace.visualstudio.com/items?itemName=Vue.volar) + [Tauri](https://marketplace.visualstudio.com/items?itemName=tauri-apps.tauri-vscode) + [rust-analyzer](https://marketplace.visualstudio.com/items?itemName=rust-lang.rust-analyzer)

```bash
npm install
npm run tauri dev
```
