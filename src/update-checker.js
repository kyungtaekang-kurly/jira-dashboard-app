import { check } from '@tauri-apps/plugin-updater';
import { ask } from '@tauri-apps/plugin-dialog';
import { relaunch } from '@tauri-apps/plugin-process';

export async function checkForUpdates() {
  try {
    const update = await check();
    if (!update) {
      console.log('[Updater] 현재 최신 버전입니다.');
      return;
    }

    const yes = await ask(
      `새 버전 ${update.version}이(가) 있습니다.\n지금 업데이트하시겠습니까?`,
      {
        title: 'Kurly Jira 업데이트',
        kind: 'info',
        okLabel: '업데이트',
        cancelLabel: '나중에',
      }
    );

    if (yes) {
      console.log('[Updater] 다운로드 시작...');
      await update.downloadAndInstall();
      console.log('[Updater] 설치 완료. 재시작합니다.');
      await relaunch();
    }
  } catch (error) {
    console.error('[Updater] 업데이트 확인 실패:', error);
  }
}
