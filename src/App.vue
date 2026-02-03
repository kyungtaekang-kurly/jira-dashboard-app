<script setup lang="ts">
import { ref, computed, onMounted } from 'vue';
import { fetch } from '@tauri-apps/plugin-http'; // Tauri 전용 fetch

// --- 1. 상태 및 데이터 관리 ---
const currentTab = ref<'epic' | 'idea'>('epic');
const tickets = ref<any[]>([]);
const epicInfo = ref<any>(null);
const isLoading = ref(false);

// --- 2. 설정 정보 ---
const JIRA_DOMAIN = 'kurly0521.atlassian.net';
const EMAIL = 'kyungtae.kang@kurlycorp.com';
const API_TOKEN = 'ATATT3xFfGF0uau1DjgfL7syTIzmBWZ_TnyMHRHG_MUw1qaEPLTOqL_1Wl7tWCngv4JrP2-Nsa6WpK2YRS3gZAXqFamzC_jqS-CqG1WordzHRg85zBz7zb0sPXy5JTbcwFNO87bCSmkHeq2mEX25cCHSaYTvEyYYa1r2scBe7DXJ13E04lCSDTE=8D988A7E';
const EPIC_KEY = 'FPP-72';
const authHeader = btoa(`${EMAIL}:${API_TOKEN}`);

// --- 3. 데이터 로드 로직 (성공한 GET 방식 적용) ---
const loadData = async () => {
  isLoading.value = true;
  tickets.value = [];

  try {
    let jqlString = "";
    let fields = "summary,status,issuetype,assignee,priority";

    if (currentTab.value === 'epic') {
      jqlString = `parent=${EPIC_KEY} ORDER BY status ASC, created DESC`;

      // 에픽 상세 정보 (GET)
      const epicRes = await fetch(`https://${JIRA_DOMAIN}/rest/api/3/issue/${EPIC_KEY}`, {
        method: 'GET',
        headers: { 'Authorization': `Basic ${authHeader}`, 'Accept': 'application/json' }
      });
      epicInfo.value = await epicRes.json();
    } else {
      // [성공한 curl과 동일한 쿼리]
      jqlString = "project = FPP ORDER BY created DESC";
      epicInfo.value = { fields: { summary: 'Jira Idea Explorer' } };
    }

    // [핵심] curl --url "URL?jql=...&fields=..." 구조 생성
    const queryParams = new URLSearchParams({
      jql: jqlString,
      fields: fields,
      maxResults: '100'
    });

    const fullUrl = `https://${JIRA_DOMAIN}/rest/api/3/search/jql?${queryParams.toString()}`;
    console.log("요청 URL:", fullUrl);

    const response = await fetch(fullUrl, {
      method: 'GET', // POST에서 GET으로 변경
      headers: {
        'Authorization': `Basic ${authHeader}`,
        'Accept': 'application/json'
        // GET 방식이므로 Content-Type은 필요하지 않습니다.
      }
    });

    if (!response.ok) {
      const errorMsg = await response.text();
      throw new Error(`API 오류: ${response.status} - ${errorMsg}`);
    }

    const data: any = await response.json();
    // GET 방식도 issues 배열에 결과가 담깁니다.
    tickets.value = data.issues || [];

  } catch (error: any) {
    console.error('데이터 로드 실패:', error);
    alert(error.message);
  } finally {
    isLoading.value = false;
  }
};

const switchTab = (tab: 'epic' | 'idea') => {
  currentTab.value = tab;
  loadData();
};

const getStatusClass = (statusName: string) => {
  const name = (statusName || '').toLowerCase();
  if (name.includes('할 일') || name.includes('todo')) return 'status-todo';
  if (name.includes('진행') || name.includes('progress')) return 'status-inprogress';
  if (name.includes('완료') || name.includes('done')) return 'status-done';
  return 'status-todo';
};

const stats = computed(() => {
  const total = tickets.value.length;
  if (total === 0) return { total: 0, done: 0, percent: 0 };
  const doneCount = tickets.value.filter(t =>
      ['완료', 'done', 'shipped'].some(s => (t.fields?.status?.name || '').toLowerCase().includes(s))
  ).length;
  return { total, done: doneCount, percent: Math.round((doneCount / total) * 100) };
});

onMounted(() => loadData());
</script>

<template>
  <div class="app-layout">
    <aside class="sidebar">
      <div class="sidebar-brand">Atmos</div>
      <nav class="nav-menu">
        <div class="nav-item" :class="{ active: currentTab === 'epic' }" @click="switchTab('epic')">📋 Epic Explorer</div>
        <div class="nav-item" :class="{ active: currentTab === 'idea' }" @click="switchTab('idea')">💡 Idea Explorer</div>
      </nav>
    </aside>

    <main class="main-container">
      <header class="main-header">
        <div class="header-left">
          <span v-if="epicInfo" class="type-badge">{{ currentTab }}</span>
          <h2 class="title-text">{{ epicInfo?.fields?.summary || 'Atmos Jira Dashboard' }}</h2>
        </div>
        <button @click="loadData" :disabled="isLoading" class="btn-refresh">
          {{ isLoading ? '동기화 중...' : '🔄 데이터 업데이트' }}
        </button>
      </header>

      <div class="summary-bar" v-if="tickets.length > 0">
        <div class="summary-info">Total <strong>{{ stats.total }}</strong> | Done <strong>{{ stats.done }}</strong></div>
        <div class="progress-track"><div class="progress-fill" :style="{ width: stats.percent + '%' }"></div></div>
        <div class="percent-tag">{{ stats.percent }}%</div>
      </div>

      <section class="content-body">
        <table v-if="tickets.length > 0" class="jira-table">
          <thead>
          <tr><th>KEY</th><th>SUMMARY</th><th>STATUS</th><th>ASSIGNEE</th></tr>
          </thead>
          <tbody>
          <tr v-for="ticket in tickets" :key="ticket.id">
            <td class="td-key">{{ ticket.key }}</td>
            <td class="td-summary">{{ ticket.fields?.summary }}</td>
            <td><span :class="['badge', getStatusClass(ticket.fields?.status?.name)]">{{ ticket.fields?.status?.name || 'Unknown' }}</span></td>
            <td class="td-user"><div class="user-pill">{{ ticket.fields?.assignee?.displayName || '-' }}</div></td>
          </tr>
          </tbody>
        </table>
        <div v-else-if="!isLoading" class="empty-state">조회된 티켓이 없습니다.</div>
      </section>
    </main>
  </div>
</template>

<style>
/* (기존 스타일 레이아웃 유지) */
:root { --sidebar-width: 220px; --primary: #0052cc; }
body { margin: 0; font-family: -apple-system, sans-serif; overflow: hidden; background: white; }
.app-layout { display: flex; width: 100vw; height: 100vh; }
.sidebar { width: var(--sidebar-width); background: #0747a6; color: white; display: flex; flex-direction: column; flex-shrink: 0; }
.sidebar-brand { padding: 24px; font-size: 1.5rem; font-weight: 800; }
.nav-item { padding: 12px 16px; margin: 2px 10px; border-radius: 6px; cursor: pointer; font-size: 0.9rem; }
.nav-item.active { background: rgba(255,255,255,0.2); font-weight: bold; }
.main-container { flex-grow: 1; display: flex; flex-direction: column; overflow: hidden; background: white; }
.main-header { padding: 20px 32px; border-bottom: 1px solid #dfe1e6; display: flex; align-items: center; justify-content: space-between; }
.type-badge { background: #4c9aff; color: white; padding: 2px 6px; border-radius: 4px; font-size: 0.65rem; font-weight: bold; text-transform: uppercase; margin-right: 12px; }
.title-text { margin: 0; font-size: 1.2rem; color: #172b4d; flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.summary-bar { padding: 12px 32px; background: #fafbfc; display: flex; align-items: center; gap: 16px; border-bottom: 1px solid #dfe1e6; }
.progress-track { flex: 1; height: 8px; background: #ebecf0; border-radius: 4px; overflow: hidden; }
.progress-fill { height: 100%; background: #36b37e; transition: width 0.5s ease; }
.jira-table { width: 100%; border-collapse: collapse; }
.jira-table th { text-align: left; font-size: 0.75rem; color: #6b778c; padding: 12px; border-bottom: 2px solid #dfe1e6; }
.jira-table td { padding: 12px; border-bottom: 1px solid #f4f5f7; font-size: 0.9rem; }
.badge { padding: 4px 8px; border-radius: 3px; font-size: 0.75rem; font-weight: bold; }
.status-todo { background: #dfe1e6; color: #42526e; }
.status-inprogress { background: #deebff; color: #0052cc; }
.status-done { background: #e3fcef; color: #006644; }
.btn-refresh { background: var(--primary); color: white; border: none; padding: 8px 16px; border-radius: 4px; cursor: pointer; font-weight: 600; }
</style>