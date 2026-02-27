<script setup lang="ts">
import { ref, computed, onMounted } from 'vue';
import { fetch } from '@tauri-apps/plugin-http';
import { open } from '@tauri-apps/plugin-shell';
import { checkForUpdates } from './update-checker.js';

// --- 0. 앱 로그 ---
const appLog = ref<string[]>([]);
const log = (msg: string) => {
  const ts = new Date().toLocaleTimeString();
  appLog.value.push(`[${ts}] ${msg}`);
  console.log(msg);
};
const clearLog = () => { appLog.value = []; };
const logText = computed(() => appLog.value.join('\n'));
const commentSearchQuery = ref('');

// --- 1. 상태 관리 ---
const currentTab = ref<'jira' | 'setting' | 'log'>('jira');
const tickets = ref<any[]>([]);
const epicInfo = ref<any>(null);
const isLoading = ref(false);

// 필터 상태
const selectedStatuses = ref<string[]>([]);
const isStatusDropdownOpen = ref(false);

const toggleStatusSelection = (status: string) => {
  const idx = selectedStatuses.value.indexOf(status);
  if (idx === -1) {
    selectedStatuses.value.push(status);
  } else {
    selectedStatuses.value.splice(idx, 1);
  }
};

const selectAllStatuses = () => {
  selectedStatuses.value = [];
};

const statusFilterLabel = computed(() => {
  if (selectedStatuses.value.length === 0) return `모든 상태 (${tickets.value.length})`;
  if (selectedStatuses.value.length === 1) return selectedStatuses.value[0];
  return `${selectedStatuses.value.length}개 상태 선택됨`;
});
const selectedTeam = ref<string>('전체 조직');
const subjectSearchQuery = ref('');

// 모달 상태
const isCommentModalOpen = ref(false);
const allComments = ref<any[]>([]);
const isCommentsLoading = ref(false);
const selectedTicketKey = ref('');

// --- 2. 설정 정보 ---
const JIRA_DOMAIN = 'kurly0521.atlassian.net';
const userEmail = ref(localStorage.getItem('jira_email') || '');
const userApiToken = ref(localStorage.getItem('jira_api_token') || '');
const authHeader = computed(() => btoa(`${userEmail.value}:${userApiToken.value}`));
const isSetupOpen = ref(false);
const setupEmail = ref('');
const setupApiToken = ref('');

const isConfigured = computed(() => userEmail.value !== '' && userApiToken.value !== '');

const saveSetup = () => {
  if (!setupEmail.value.trim() || !setupApiToken.value.trim()) return;
  userEmail.value = setupEmail.value.trim();
  userApiToken.value = setupApiToken.value.trim();
  localStorage.setItem('jira_email', userEmail.value);
  localStorage.setItem('jira_api_token', userApiToken.value);
  isSetupOpen.value = false;
  log(`[설정] 인증 정보 저장 완료: ${userEmail.value}`);
  loadData();
};

const resetCredentials = () => {
  userEmail.value = '';
  userApiToken.value = '';
  localStorage.removeItem('jira_email');
  localStorage.removeItem('jira_api_token');
  setupEmail.value = '';
  setupApiToken.value = '';
  isSetupOpen.value = true;
  log('[설정] 인증 정보 초기화됨');
};

const EPIC_KEY = 'FPP-72';
const ORG_FIELD = 'customfield_20061'; // 수행조직 필드 ID
const ASSIGNEE_FIELD = 'customfield_18564'; // 담당자용 커스텀 필드 ID 정의

// --- 3. 필터링 로직 (Computed) ---

// 1. 상태값 목록 추출
const availableStatuses = computed(() => {
  const statuses = tickets.value.map(t => t.fields?.status?.name).filter(Boolean);
  return ['all', ...new Set(statuses)];
});

// 2. 조직 목록 추출
const availableTeams = computed(() => {
  const teams = tickets.value.map(t => {
    const val = t.fields?.[ORG_FIELD];
    if (Array.isArray(val)) return val[0]?.value;
    return val?.value || val;
  }).filter(Boolean);
  return ['전체 조직', ...new Set(teams)];
});

// 3. 통합 필터링 결과
const filteredTickets = computed(() => {
  return tickets.value.filter(t => {
    // 상태 매칭
    const statusMatch = selectedStatuses.value.length === 0 || selectedStatuses.value.includes(t.fields?.status?.name);
    // 조직 매칭
    const orgVal = t.fields?.[ORG_FIELD];
    const teamName = Array.isArray(orgVal) ? orgVal[0]?.value : (orgVal?.value || orgVal);
    const teamMatch = selectedTeam.value === '전체 조직' || teamName === selectedTeam.value;
    // Subject 검색 매칭
    const query = subjectSearchQuery.value.trim().toLowerCase();
    const subjectMatch = !query || (t.fields?.summary || '').toLowerCase().includes(query);

    return statusMatch && teamMatch && subjectMatch;
  });
});

// --- 4. 데이터 로드 로직 ---
const loadData = async () => {
  isLoading.value = true;
  tickets.value = [];

  try {
    // 진단: 현재 사용자 정보 확인
    const meRes = await fetch(`https://${JIRA_DOMAIN}/rest/api/3/myself`, {
      method: 'GET',
      headers: { 'Authorization': `Basic ${authHeader.value}`, 'Accept': 'application/json' }
    });
    if (meRes.ok) {
      const me: any = await meRes.json();
      log(`[진단] 로그인 사용자: ${me.displayName} (${me.emailAddress})`);
    } else if (meRes.status === 401) {
      log(`[인증 실패] API 토큰이 만료되었거나 잘못되었습니다. Setting 탭에서 인증 정보를 다시 설정해주세요.`);
      log(`[안내] API 토큰 재발급: https://id.atlassian.com/manage-profile/security/api-tokens`);
      isLoading.value = false;
      return;
    } else {
      log(`[진단] 사용자 확인 실패: ${meRes.status} ${meRes.statusText}`);
    }

    // 진단: FPP 프로젝트 접근 확인
    const projRes = await fetch(`https://${JIRA_DOMAIN}/rest/api/3/project/FPP`, {
      method: 'GET',
      headers: { 'Authorization': `Basic ${authHeader.value}`, 'Accept': 'application/json' }
    });
    if (projRes.ok) {
      const proj: any = await projRes.json();
      log(`[진단] FPP 프로젝트 접근 OK: ${proj.name}`);
    } else {
      log(`[진단] FPP 프로젝트 접근 실패: ${projRes.status} - 프로젝트가 삭제/이름변경/권한제한 되었을 수 있음`);
    }

    const targetTeams = ["재고", "입고", "발주", "상품"];
    let allIssues: any[] = [];
    const fields = `summary,status,issuetype,assignee,priority,${ORG_FIELD},${ASSIGNEE_FIELD}`;

    for (const teamName of targetTeams) {
      try {
        const teamJql = `project = FPP AND customfield_20061 = "${teamName}" ORDER BY created DESC`;

        const queryParams = new URLSearchParams({
          jql: teamJql,
          fields: fields,
          maxResults: "100"
        });

        const fullUrl = `https://${JIRA_DOMAIN}/rest/api/3/search/jql?${queryParams.toString()}`;

        const response = await fetch(fullUrl, {
          method: 'GET',
          headers: {
            'Authorization': `Basic ${authHeader.value}`,
            'Accept': 'application/json',
            'X-Atlassian-Token': 'no-check'
          }
        });

        log(`[HTTP] ${teamName} 요청 → 상태: ${response.status} ${response.statusText}`);
        log(`[JQL] ${teamJql}`);
        if (response.ok) {
          const data: any = await response.json();
          const issues = data.issues || [];
          log(`[확인] ${teamName} 조직 결과: ${issues.length}건 (total: ${data.total || 0})`);
          allIssues = [...allIssues, ...issues];
        } else {
          const body = await response.text();
          if (response.status === 401) {
            log(`[인증 실패] API 토큰이 유효하지 않습니다. 토큰을 재발급하세요. (https://id.atlassian.com/manage-profile/security/api-tokens)`);
          }
          log(`[에러] ${teamName} 응답 상태: ${response.status} / 본문: ${body.substring(0, 300)}`);
        }
      } catch (e) {
        log(`[경고] ${teamName} 요청 실패 (건너뜀): ${e}`);
      }
    }

    // 만약 조직별 데이터가 하나도 없다면, 안전장치로 전체 프로젝트 100개 로드
    if (allIssues.length === 0) {
      log("[경고] 조직별 데이터를 찾지 못해 전체 데이터를 로드합니다.");
      const fallbackUrl = `https://${JIRA_DOMAIN}/rest/api/3/search/jql?jql=project=FPP ORDER BY created DESC&maxResults=300&fields=${fields}`;
      const res = await fetch(fallbackUrl, {
        method: 'GET',
        headers: { 'Authorization': `Basic ${authHeader.value}` }
      });
      log(`[HTTP] 전체 데이터 폴백 → 상태: ${res.status} ${res.statusText}`);
      log(`[URL] ${fallbackUrl}`);
      if (res.ok) {
        const data: any = await res.json();
        allIssues = data.issues || [];
        log(`[확인] 폴백 결과: ${allIssues.length}건 (total: ${data.total || 0})`);
      } else {
        const body = await res.text();
        if (res.status === 401) {
          log(`[인증 실패] API 토큰이 유효하지 않습니다. 토큰을 재발급하세요. (https://id.atlassian.com/manage-profile/security/api-tokens)`);
        }
        log(`[에러] 폴백 응답 상태: ${res.status} / 본문: ${body.substring(0, 300)}`);
      }
    }

    // 중복 제거 후 할당
    tickets.value = Array.from(
        new Map(allIssues.map(issue => [issue.key, issue])).values()
    );

    epicInfo.value = { fields: { summary: 'Kurly Jira Dashboard' } };

  } catch (error) {
    log(`[치명적 오류] 데이터 로드 실패: ${error}`);
  } finally {
    isLoading.value = false;
  }
};

const openJiraIssue = async (key: string) => {
  const url = `https://${JIRA_DOMAIN}/browse/${key}`;
  await open(url);
};

const switchTab = (tab: 'jira' | 'setting' | 'log') => {
  currentTab.value = tab;
  if (tab === 'jira') loadData();
};

const getStatusClass = (statusName: string) => {
  const name = (statusName || '').toLowerCase();
  if (name.includes('할 일') || name.includes('todo')) return 'status-todo';
  if (name.includes('진행') || name.includes('progress')) return 'status-inprogress';
  if (name.includes('완료') || name.includes('done')) return 'status-done';
  return 'status-todo';
};

const stats = computed(() => {
  const total = filteredTickets.value.length;
  if (total === 0) return { total: 0, done: 0, percent: 0 };
  const doneCount = filteredTickets.value.filter(t =>
      ['완료', 'done'].some(s => (t.fields?.status?.name || '').toLowerCase().includes(s))
  ).length;
  return { total, done: doneCount, percent: Math.round((doneCount / total) * 100) };
});

const loadAllSubTaskComments = async (ticket: any) => {
  if (!ticket || !ticket.key) return;

  selectedTicketKey.value = ticket.key;
  isCommentModalOpen.value = true;
  isCommentsLoading.value = true;
  allComments.value = [];

  try {
    // 1. 하위 이슈 검색 (인코딩 강화 및 쿼리 단순화)
    const subTaskJql = `parent = "${ticket.key}"`;
    const searchUrl = `https://${JIRA_DOMAIN}/rest/api/3/search?jql=${encodeURIComponent(subTaskJql)}&fields=key`;

    let issueKeys = [ticket.key]; // 기본적으로 자기 자신은 포함

    try {
      const searchRes = await fetch(searchUrl, {
        method: 'GET',
        headers: { 'Authorization': `Basic ${authHeader.value}`, 'Accept': 'application/json' }
      });

      if (searchRes.ok) {
        const searchData: any = await searchRes.json();
        const subKeys = (searchData.issues || []).map((i: any) => i.key);
        issueKeys = [...issueKeys, ...subKeys];
      }
    } catch (e) {
      log(`[경고] 하위 태스크 검색 실패 (무시하고 진행): ${e}`);
    }

    // 2. 댓글 병렬 로드
    const commentPromises = issueKeys.map(async (key) => {
      try {
        const res = await fetch(`https://${JIRA_DOMAIN}/rest/api/3/issue/${key}/comment`, {
          method: 'GET',
          headers: { 'Authorization': `Basic ${authHeader.value}` }
        });
        return res.ok ? await res.json() : { comments: [] };
      } catch (e) {
        return { comments: [] };
      }
    });

    const results = await Promise.all(commentPromises);

    // 3. 댓글 통합 및 정렬
    const merged = results.flatMap((r, index) =>
        (r.comments || []).map((c: any) => ({
          ...c,
          issueKey: issueKeys[index]
        }))
    );

    allComments.value = merged.sort((a, b) =>
        new Date(b.created).getTime() - new Date(a.created).getTime()
    );

  } catch (error) {
    log(`[치명적 오류] 댓글 로드 실패: ${error}`);
  } finally {
    isCommentsLoading.value = false;
  }
};


// --- ADF(Jira 댓글 형식)를 안전하게 텍스트로 변환하는 함수 ---
const parseADF = (node: any): string => {
  if (!node) return '';
  if (node.text) return node.text;
  if (node.content && Array.isArray(node.content)) {
    return node.content.map(parseADF).join('');
  }
  return '';
};


// --- 추가된 재귀 및 링크 탐색 로직 ---

/**
 * 1. 특정 티켓에 연결된(Issue Links) 모든 이슈 키를 가져오는 함수
 */
const getLinkedIssueKeys = async (ticketKey: string): Promise<string[]> => {
  try {
    const res = await fetch(`https://${JIRA_DOMAIN}/rest/api/3/issue/${ticketKey}?fields=issuelinks`, {
      method: 'GET',
      headers: { 'Authorization': `Basic ${authHeader.value}` }
    });
    if (!res.ok) return [];
    const data: any = await res.json();

    // inwardIssue 또는 outwardIssue에서 키 추출
    const links = data.fields?.issuelinks || [];
    const keys = links.map((link: any) =>
        link.outwardIssue?.key || link.inwardIssue?.key
    ).filter(Boolean);

    return keys;
  } catch (e) {
    log(`[에러] 이슈 링크 로드 실패: ${e}`);
    return [];
  }
};

/**
 * 2. 통합 댓글 로드 함수 (제공된 에픽 + 하위 태스크 전체)
 */
const loadLinkedEpicComments = async (ticket: any) => {
  if (!ticket || !ticket.key) return;

  selectedTicketKey.value = ticket.key;
  isCommentModalOpen.value = true;
  isCommentsLoading.value = true;
  allComments.value = [];

  try {
    // 1. 모든 관련 티켓 키를 담을 Set (FPP-72 포함)
    const allRelatedKeys = new Set<string>();
    allRelatedKeys.add(ticket.key);

    // 2. 직접 연결된 링크(제공 에픽 등) 가져오기
    const linkedKeys = await getLinkedIssueKeys(ticket.key);
    linkedKeys.forEach(k => allRelatedKeys.add(k));

    // 3. [핵심 수정] 연결된 에픽(COOP-4331 등)의 '모든' 하위 티켓을 JQL로 한 번에 조회
    // "parentEpic" 또는 "issue in epic" 문법을 사용하여 계층에 상관없이 에픽 내부 이슈를 다 가져옵니다.
    const keysArray = Array.from(allRelatedKeys);

    // COOP-4331 하위의 COOP-4712와 같은 모든 태스크를 포함하는 쿼리
    const expandedJql = `key IN ("${keysArray.join('","')}") OR parent IN ("${keysArray.join('","')}") OR "Epic Link" IN ("${keysArray.join('","')}") OR parentEpic IN ("${keysArray.join('","')}")`;

    const queryParams = new URLSearchParams({
      jql: expandedJql,
      fields: "key",
      maxResults: "200" // 검색 범위를 충분히 확보
    });

    const searchUrl = `https://${JIRA_DOMAIN}/rest/api/3/search/jql?${queryParams.toString()}`;
    const searchRes = await fetch(searchUrl, {
      method: 'GET',
      headers: { 'Authorization': `Basic ${authHeader.value}`, 'Accept': 'application/json' }
    });

    if (searchRes.ok) {
      const searchData: any = await searchRes.json();
      // COOP-4712를 포함한 모든 하위 티켓 키 수집
      (searchData.issues || []).forEach((i: any) => allRelatedKeys.add(i.key));
    }

    // 4. 수집된 모든 티켓(FPP-72, COOP-4331, COOP-4712 등)의 댓글 병렬 로드
    const finalKeys = Array.from(allRelatedKeys);
    log(`[정보] 댓글 수집 대상: ${finalKeys.join(', ')}`);

    const results = await Promise.all(finalKeys.map(async (key) => {
      const res = await fetch(`https://${JIRA_DOMAIN}/rest/api/3/issue/${key}/comment`, {
        method: 'GET',
        headers: { 'Authorization': `Basic ${authHeader.value}` }
      });
      return res.ok ? { key, data: await res.json() } : { key, data: { comments: [] } };
    }));

    // 5. 댓글 병합 및 날짜순 정렬
    const merged = results.flatMap(result =>
        (result.data.comments || []).map((c: any) => ({
          ...c,
          issueKey: result.key
        }))
    );

    allComments.value = merged.sort((a, b) =>
        new Date(b.created).getTime() - new Date(a.created).getTime()
    );

  } catch (error) {
    log(`[에러] 하위 댓글 통합 로드 실패: ${error}`);
  } finally {
    isCommentsLoading.value = false;
  }
};

// --- 상태 관리 추가 ---
const treeData = ref<any[]>([]);
const isTreeModalOpen = ref(false);
const isTreeLoading = ref(false);

/**
 * 티켓과 그 하위 이슈들을 트리 구조로 변환하여 로드합니다.
 */

// script setup 내 loadTicketTree 메소드 수정
// --- 추가 상태 관리 ---
const showOnlyInProgress = ref(false); // 상태 필터링용
const collapsedGroups = ref<Set<string>>(new Set()); // 접기/펴기용

const toggleGroup = (key: string) => {
  if (collapsedGroups.value.has(key)) {
    collapsedGroups.value.delete(key);
  } else {
    collapsedGroups.value.add(key);
  }
};

const loadTicketTree = async (rootTicket: any) => {
  log(`[정보] 트리 로드 시작: ${rootTicket.key}`);
  selectedTicketKey.value = rootTicket.key;
  isTreeModalOpen.value = true;
  isTreeLoading.value = true;
  treeData.value = [];
  collapsedGroups.value.clear(); // 모달 열 때 초기화

  try {
    const linkedKeys = await getLinkedIssueKeys(rootTicket.key);
    const topLevelKeys = [rootTicket.key, ...linkedKeys];

    const jql = `key IN ("${topLevelKeys.join('","')}") OR parent IN ("${topLevelKeys.join('","')}") OR "Epic Link" IN ("${topLevelKeys.join('","')}")`;

    // fields에 comment, created 추가
    const queryParams = new URLSearchParams({
      jql: jql,
      fields: "summary,status,issuetype,parent,customfield_10008,assignee,comment,created",
      maxResults: "150"
    });

    const searchUrl = `https://${JIRA_DOMAIN}/rest/api/3/search/jql?${queryParams.toString()}`;
    const res = await fetch(searchUrl, {
      method: 'GET',
      headers: { 'Authorization': `Basic ${authHeader.value}`, 'Accept': 'application/json' }
    });

    if (res.ok) {
      const data: any = await res.json();
      const allIssues = data.issues || [];

      const roots = allIssues.filter((issue: any) => topLevelKeys.includes(issue.key));

      treeData.value = roots.map((root: any) => {
        return {
          ...root,
          children: allIssues.filter((child: any) =>
              (child.fields?.parent?.key === root.key ||
                  child.fields?.customfield_10008 === root.key) &&
              child.key !== root.key
          )
        };
      });
    }
  } catch (error) {
    log(`[에러] 트리 로드 실패: ${error}`);
  } finally {
    isTreeLoading.value = false;
  }
};

// --- 필터링된 트리 데이터 (Computed) ---
const filteredTreeData = computed(() => {
  if (!showOnlyInProgress.value) return treeData.value;

  return treeData.value.map(parent => ({
    ...parent,
    children: parent.children.filter((child: any) => {
      const name = (child.fields?.status?.name || '').toLowerCase();
      return !['완료', 'done', 'closed', 'resolved'].some(s => name.includes(s));
    })
  }));
});

/**
 * 댓글 본문에서 검색어와 일치하는 부분을 <mark> 태그로 강조합니다.
 * @param text 원본 댓글 텍스트
 * @param query 사용자가 입력한 검색어
 */
const highlightText = (text: string, query: string) => {
  if (!query || !query.trim()) return text; // 검색어가 없으면 원본 반환

  // 대소문자 구분 없이 검색어를 찾기 위한 정규식 (gi: global, ignore case)
  const regex = new RegExp(`(${query})`, 'gi');
  // 검색어 부분을 <mark> 태그로 감싸서 반환
  return text.replace(regex, '<mark class="highlight">$1</mark>');
};

onMounted(() => {
  if (!isConfigured.value) {
    isSetupOpen.value = true;
  } else {
    loadData();
  }
  checkForUpdates();
  document.addEventListener('click', () => { isStatusDropdownOpen.value = false; });
});
</script>

<template>
  <div class="app-layout">
    <aside class="sidebar">
      <div class="sidebar-brand">컬리지라(Kurly Jira)</div>
      <nav class="nav-menu">
        <div class="nav-item" :class="{ active: currentTab === 'jira' }" @click="switchTab('jira')">📋 Jira</div>
        <div class="nav-item" :class="{ active: currentTab === 'setting' }" @click="switchTab('setting')">⚙️ Setting</div>
        <div class="nav-item" :class="{ active: currentTab === 'log' }" @click="switchTab('log')">📝 Log</div>
      </nav>
    </aside>

    <main class="main-container" v-if="currentTab === 'jira'">
      <header class="main-header">
        <div class="header-left">
          <h2 class="title-text">{{ epicInfo?.fields?.summary || 'Loading...' }}</h2>
        </div>
        <div class="header-actions">
          <input v-model="subjectSearchQuery" type="text" placeholder="Subject 검색..." class="subject-search-input" />
          <select v-model="selectedTeam" class="status-filter">
            <option v-for="team in availableTeams" :key="team" :value="team">{{ team }}</option>
          </select>
          <div class="multi-select-wrapper" @click.stop>
            <button class="multi-select-trigger" @click="isStatusDropdownOpen = !isStatusDropdownOpen">
              <span>{{ statusFilterLabel }}</span>
              <span class="multi-select-arrow" :class="{ open: isStatusDropdownOpen }">▾</span>
            </button>
            <div v-if="isStatusDropdownOpen" class="multi-select-dropdown">
              <label class="multi-select-option" @click="selectAllStatuses()">
                <input type="checkbox" :checked="selectedStatuses.length === 0" readonly />
                <span>모든 상태 ({{ tickets.length }})</span>
              </label>
              <label v-for="status in availableStatuses.filter(s => s !== 'all')" :key="status" class="multi-select-option" @click.prevent="toggleStatusSelection(status)">
                <input type="checkbox" :checked="selectedStatuses.includes(status)" />
                <span>{{ status }}</span>
              </label>
            </div>
          </div>
          <button @click="loadData" :disabled="isLoading" class="btn-refresh">🔄 업데이트</button>
        </div>
      </header>

      <div class="summary-bar" v-if="filteredTickets.length > 0">
        <div class="summary-info">Filtered <strong>{{ stats.total }}</strong> | Done <strong>{{ stats.done }}</strong></div>
        <div class="progress-track"><div class="progress-fill" :style="{ width: stats.percent + '%' }"></div></div>
        <div class="percent-tag">{{ stats.percent }}%</div>
      </div>

      <section class="content-body">
        <table v-if="filteredTickets.length > 0" class="jira-table">
          <thead>
          <tr>
            <th style="width: 100px;">KEY</th>
            <th style="width: 140px;">수행조직</th> <th>Subject</th>
            <th style="width: 120px;">STATUS</th>
            <th style="width: 120px;">JPD댓글보기</th>
            <th style="width: 120px;">하위Ticket</th>
            <th style="width: 120px;">하위Task댓글보기</th>
            <th style="width: 140px;">담당자</th>
          </tr>
          </thead>
          <tbody>
          <tr v-for="ticket in filteredTickets" :key="ticket.id" @click="openJiraIssue(ticket.key)" class="ticket-row clickable-row">
            <td class="td-key">{{ ticket.key }}</td>
            <td class="td-team">
                <span class="team-tag">
                  {{ Array.isArray(ticket.fields?.[ORG_FIELD]) ? ticket.fields?.[ORG_FIELD][0]?.value : (ticket.fields?.[ORG_FIELD]?.value || '-') }}
                </span>
            </td>
            <td class="td-summary" v-html="highlightText(ticket.fields?.summary || '', subjectSearchQuery)"></td>
            <td><span :class="['badge', getStatusClass(ticket.fields?.status?.name)]">{{ ticket.fields?.status?.name }}</span></td>
            <td class="td-actions">
              <button @click.stop="loadAllSubTaskComments(ticket)" class="btn-comment">
                에픽 댓글 보기
              </button>
            </td>
            <td class="td-actions">
              <div class="btn-group">
                <button @click.stop="loadTicketTree(ticket)" class="btn-tree">하위 트리</button>
              </div>
            </td>
            <td class="td-actions">
              <button @click.stop="loadLinkedEpicComments(ticket)" class="btn-comment">
                하위 댓글 보기
              </button>
            </td>
            <td class="td-user">
              <div class="user-pill">
                {{ ticket.fields?.[ASSIGNEE_FIELD]?.[0]?.displayName || '미지정' }}
              </div>
            </td>
          </tr>
          </tbody>
        </table>
      </section>
    </main>

    <main class="main-container" v-if="currentTab === 'setting'">
      <header class="main-header">
        <div class="header-left">
          <h2 class="title-text">Setting</h2>
        </div>
      </header>
      <div class="setting-body">
        <div class="setting-card">
          <h3 class="setting-section-title">Jira 연결 설정</h3>
          <div class="setting-row">
            <label class="setting-label">Domain</label>
            <div class="setting-value">{{ JIRA_DOMAIN }}</div>
          </div>
          <div class="setting-row">
            <label class="setting-label">Email</label>
            <div class="setting-value">{{ userEmail || '(미설정)' }}</div>
          </div>
          <div class="setting-row">
            <label class="setting-label">API Token</label>
            <div class="setting-value setting-token">{{ userApiToken ? userApiToken.substring(0, 20) + '...' + userApiToken.substring(userApiToken.length - 8) : '(미설정)' }}</div>
          </div>
          <div class="setting-row">
            <label class="setting-label">Project</label>
            <div class="setting-value">FPP</div>
          </div>
          <div class="setting-actions">
            <button @click="resetCredentials" class="btn-reset">인증 정보 초기화</button>
          </div>
        </div>
        <div class="setting-card">
          <h3 class="setting-section-title">앱 정보</h3>
          <div class="setting-row">
            <label class="setting-label">버전</label>
            <div class="setting-value">0.5.1</div>
          </div>
          <div class="setting-row">
            <label class="setting-label">빌드</label>
            <div class="setting-value">Tauri v2 + Vue 3</div>
          </div>
        </div>
      </div>
    </main>

    <main class="main-container log-container" v-if="currentTab === 'log'">
      <header class="main-header">
        <div class="header-left">
          <h2 class="title-text">App Log</h2>
        </div>
        <div class="header-actions">
          <button @click="clearLog" class="btn-refresh">초기화</button>
        </div>
      </header>
      <div class="log-body">
        <textarea class="log-textarea" readonly :value="logText"></textarea>
      </div>
    </main>
  </div>

  <div v-if="isCommentModalOpen" class="modal-overlay" @click="isCommentModalOpen = false">
    <div class="modal-content" @click.stop>
      <header class="modal-header">
        <h3>최신 댓글 통합 보기</h3>
        <button @click="isCommentModalOpen = false" class="close-btn">&times;</button>
      </header>
      <div class="modal-search">
        <input v-model="commentSearchQuery" type="text" placeholder="댓글 내용 검색..." class="search-input" />
      </div>
      <div class="modal-body">
        <div v-if="isCommentsLoading" class="loading-spinner">댓글을 불러오는 중...</div>
        <div v-else-if="allComments.length === 0">댓글이 없습니다.</div>
        <div v-else v-for="comment in allComments" :key="comment.id" class="comment-item">
          <div class="comment-meta">
            <span class="comment-author">{{ comment.author.displayName }}</span>

            <span
                class="comment-issue clickable-ticket"
                @click="openJiraIssue(comment.issueKey)"
                title="Jira에서 보기"
            >
      {{ comment.issueKey }}
    </span>

            <span class="comment-date">{{ new Date(comment.created).toLocaleString() }}</span>
          </div>
          <div
              class="comment-text"
              v-html="highlightText(parseADF(comment.body), commentSearchQuery)"
          ></div>
        </div>
      </div>
    </div>
  </div>

  <div v-if="isTreeModalOpen" class="modal-overlay tree-modal-overlay" @click="isTreeModalOpen = false">
    <div class="modal-content" style="width: 1000px;" @click.stop>
      <header class="modal-header">
        <div class="header-title-group">
          <h3>이슈 계층 트리 ({{ selectedTicketKey }})</h3>
          <label class="filter-toggle">
            <input type="checkbox" v-model="showOnlyInProgress"> 완료 항목 숨기기
          </label>
        </div>
        <button @click="isTreeModalOpen = false" class="close-btn">&times;</button>
      </header>

      <div class="modal-body" style="background: white;">
        <div v-if="isTreeLoading" class="loading-spinner">데이터 분석 중...</div>

        <div v-else class="tree-container">
          <div v-for="parent in filteredTreeData" :key="parent.key" class="tree-group">
            <div class="tree-node parent-node" @click="toggleGroup(parent.key)">
              <span class="fold-icon">{{ collapsedGroups.has(parent.key) ? '▶' : '▼' }}</span>
              <span class="node-key">{{ parent.key }}</span>
              <span class="node-summary">{{ parent.fields?.summary }}</span>

              <div class="node-meta">
                <span class="meta-item created-date">📅 {{ new Date(parent.fields?.created).toLocaleDateString() }}</span>
                <span class="meta-item comment-count">💬 {{ parent.fields?.comment?.total || 0 }}</span>
                <span :class="['badge', getStatusClass(parent.fields?.status?.name)]">{{ parent.fields?.status?.name }}</span>
              </div>
            </div>

            <div v-if="!collapsedGroups.has(parent.key)" class="tree-branch">
              <div v-for="child in parent.children" :key="child.key" class="tree-node child-node" @click="openJiraIssue(child.key)">
                <div class="connector-line"></div>
                <span class="node-key-sub">{{ child.key }}</span>
                <span class="node-summary-sub">{{ child.fields?.summary }}</span>

                <div class="node-meta">
                  <span v-if="child.fields?.assignee" class="assignee-tag">👤 {{ child.fields.assignee.displayName }}</span>
                  <span class="meta-item created-date">{{ new Date(child.fields?.created).toLocaleDateString() }}</span>
                  <span class="meta-item comment-count">💬 {{ child.fields?.comment?.total || 0 }}</span>
                  <span :class="['badge-small', getStatusClass(child.fields?.status?.name)]">{{ child.fields?.status?.name }}</span>
                </div>
              </div>
              <div v-if="parent.children.length === 0" class="empty-child">하위 이슈가 없습니다.</div>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>

  <div v-if="isSetupOpen" class="modal-overlay setup-overlay">
    <div class="setup-modal" @click.stop>
      <header class="modal-header">
        <h3>Jira 인증 설정</h3>
      </header>
      <div class="setup-body">
        <p class="setup-desc">Jira API 연동을 위해 이메일과 API Token을 입력하세요.</p>
        <div class="setup-field">
          <label>Atlassian Email</label>
          <input v-model="setupEmail" type="email" placeholder="name@company.com" class="setup-input" />
        </div>
        <div class="setup-field">
          <label>API Token</label>
          <input v-model="setupApiToken" type="password" placeholder="API Token을 붙여넣으세요" class="setup-input" />
        </div>
        <div class="setup-guide">
          <p>API Token 발급 방법:</p>
          <ol>
            <li><a href="#" @click.prevent="open('https://id.atlassian.com/manage-profile/security/api-tokens')">Atlassian API Token 관리 페이지</a>에 접속</li>
            <li><strong>Create API token</strong> 클릭</li>
            <li>Label 입력 후 <strong>Create</strong> 클릭</li>
            <li>생성된 토큰을 복사하여 위 입력란에 붙여넣기</li>
          </ol>
        </div>
        <button @click="saveSetup" :disabled="!setupEmail.trim() || !setupApiToken.trim()" class="btn-setup-save">저장 후 시작</button>
      </div>
    </div>
  </div>

</template>

<style>
/* ========================================
   Kurly Jira Dashboard - Unified Design
   ======================================== */

:root {
  --sidebar-width: 220px;

  /* Kurly Brand Colors */
  --kurly-purple: #5f0080;
  --kurly-purple-light: #7b1fa2;
  --kurly-purple-pale: #f3e5f5;
  --kurly-purple-bg: #faf5fc;

  /* Neutral Colors */
  --gray-50: #fafafa;
  --gray-100: #f5f5f5;
  --gray-200: #eeeeee;
  --gray-300: #e0e0e0;
  --gray-400: #bdbdbd;
  --gray-500: #9e9e9e;
  --gray-600: #757575;
  --gray-700: #616161;
  --gray-800: #424242;
  --gray-900: #212121;

  /* Semantic Colors */
  --blue-50: #e3f2fd;
  --blue-600: #1e88e5;
  --green-50: #e8f5e9;
  --green-700: #388e3c;
  --red-500: #ef5350;
  --red-600: #e53935;
  --amber-50: #fff8e1;
  --amber-700: #f57f17;

  /* Spacing */
  --space-xs: 4px;
  --space-sm: 8px;
  --space-md: 12px;
  --space-lg: 16px;
  --space-xl: 24px;
  --space-2xl: 32px;

  /* Radius */
  --radius-sm: 4px;
  --radius-md: 8px;
  --radius-lg: 12px;
  --radius-xl: 16px;

  /* Shadows */
  --shadow-sm: 0 1px 3px rgba(0,0,0,0.08);
  --shadow-md: 0 4px 12px rgba(0,0,0,0.08);
  --shadow-lg: 0 8px 24px rgba(0,0,0,0.12);
  --shadow-xl: 0 12px 40px rgba(0,0,0,0.2);
}

/* ---- Reset & Base ---- */
* { box-sizing: border-box; }
body {
  margin: 0;
  font-family: 'Pretendard', -apple-system, BlinkMacSystemFont, system-ui, Roboto, 'Helvetica Neue', sans-serif;
  overflow: hidden;
  background: #fff;
  color: var(--gray-900);
  -webkit-font-smoothing: antialiased;
}

/* ---- Layout ---- */
.app-layout {
  display: flex;
  width: 100vw;
  height: 100vh;
}

/* ---- Sidebar ---- */
.sidebar {
  width: var(--sidebar-width);
  background: linear-gradient(180deg, var(--kurly-purple) 0%, #4a0066 100%);
  color: #fff;
  display: flex;
  flex-direction: column;
  flex-shrink: 0;
}

.sidebar-brand {
  padding: var(--space-xl);
  font-size: 1.1rem;
  font-weight: 700;
  letter-spacing: -0.3px;
  border-bottom: 1px solid rgba(255,255,255,0.12);
}

.nav-menu {
  padding: var(--space-md) 0;
  flex: 1;
}

.nav-item {
  padding: var(--space-md) var(--space-xl);
  margin: var(--space-xs) var(--space-md);
  border-radius: var(--radius-md);
  cursor: pointer;
  font-size: 0.9rem;
  font-weight: 500;
  transition: all 0.15s ease;
  display: flex;
  align-items: center;
  gap: var(--space-sm);
  color: rgba(255,255,255,0.8);
}

.nav-item:hover {
  background: rgba(255,255,255,0.12);
  color: #fff;
}

.nav-item.active {
  background: #fff;
  color: var(--kurly-purple);
  font-weight: 700;
  box-shadow: var(--shadow-sm);
}

/* ---- Main Container ---- */
.main-container {
  flex: 1;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  background: var(--kurly-purple-bg);
}

/* ---- Header ---- */
.main-header {
  padding: var(--space-lg) var(--space-2xl);
  background: #fff;
  display: flex;
  align-items: center;
  justify-content: space-between;
  border-bottom: 1px solid var(--gray-200);
  gap: var(--space-lg);
  flex-shrink: 0;
}

.header-left {
  display: flex;
  align-items: center;
  gap: var(--space-md);
}

.title-text {
  margin: 0;
  font-size: 1.25rem;
  font-weight: 700;
  color: var(--kurly-purple);
}

.header-actions {
  display: flex;
  align-items: center;
  gap: var(--space-sm);
}

/* ---- Buttons (shared) ---- */
.btn-refresh {
  background: var(--kurly-purple);
  color: #fff;
  border: none;
  padding: var(--space-sm) var(--space-lg);
  border-radius: var(--radius-md);
  cursor: pointer;
  font-size: 0.85rem;
  font-weight: 600;
  transition: all 0.15s ease;
  white-space: nowrap;
}
.btn-refresh:hover { background: var(--kurly-purple-light); }
.btn-refresh:disabled { background: var(--gray-300); cursor: not-allowed; }

.btn-comment {
  background: var(--kurly-purple);
  color: #fff;
  border: none;
  padding: 5px 10px;
  border-radius: var(--radius-sm);
  cursor: pointer;
  font-size: 0.8rem;
  font-weight: 500;
  transition: all 0.15s ease;
  white-space: nowrap;
}
.btn-comment:hover { background: var(--kurly-purple-light); }

.btn-tree {
  background: var(--kurly-purple);
  color: #fff;
  border: none;
  padding: 5px 10px;
  border-radius: var(--radius-sm);
  cursor: pointer;
  font-size: 0.8rem;
  font-weight: 500;
  transition: all 0.15s ease;
  white-space: nowrap;
}
.btn-tree:hover { background: var(--kurly-purple-light); }

.btn-group {
  display: flex;
  gap: var(--space-xs);
}

/* ---- Select / Filters ---- */
.status-filter {
  appearance: none;
  background: #fff url("data:image/svg+xml;charset=utf-8,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 12 12'%3E%3Cpath fill='%23666' d='M6 8L1 3h10z'/%3E%3C/svg%3E") no-repeat right 10px center;
  border: 1px solid var(--gray-300);
  border-radius: var(--radius-md);
  padding: var(--space-sm) 30px var(--space-sm) var(--space-md);
  font-size: 0.85rem;
  color: var(--gray-800);
  cursor: pointer;
  transition: border-color 0.15s;
  min-width: 120px;
}
.subject-search-input {
  padding: var(--space-sm) var(--space-md);
  border: 1px solid var(--gray-300);
  border-radius: var(--radius-md);
  font-size: 0.85rem;
  color: var(--gray-800);
  min-width: 180px;
  transition: border-color 0.15s, box-shadow 0.15s;
}
.subject-search-input:focus {
  outline: none;
  border-color: var(--kurly-purple);
  box-shadow: 0 0 0 3px var(--kurly-purple-pale);
}
.subject-search-input::placeholder { color: var(--gray-400); }

.status-filter:hover { border-color: var(--kurly-purple); }
.status-filter:focus { outline: none; border-color: var(--kurly-purple); box-shadow: 0 0 0 3px var(--kurly-purple-pale); }

/* ---- Multi-Select Dropdown ---- */
.multi-select-wrapper {
  position: relative;
  min-width: 160px;
}
.multi-select-trigger {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--space-sm);
  width: 100%;
  background: #fff;
  border: 1px solid var(--gray-300);
  border-radius: var(--radius-md);
  padding: var(--space-sm) var(--space-md);
  font-size: 0.85rem;
  color: var(--gray-800);
  cursor: pointer;
  transition: border-color 0.15s;
  white-space: nowrap;
}
.multi-select-trigger:hover { border-color: var(--kurly-purple); }
.multi-select-arrow {
  font-size: 0.75rem;
  transition: transform 0.2s;
}
.multi-select-arrow.open { transform: rotate(180deg); }
.multi-select-dropdown {
  position: absolute;
  top: calc(100% + 4px);
  left: 0;
  min-width: 100%;
  max-height: 280px;
  overflow-y: auto;
  background: #fff;
  border: 1px solid var(--gray-300);
  border-radius: var(--radius-md);
  box-shadow: 0 4px 12px rgba(0,0,0,0.1);
  z-index: 100;
  padding: var(--space-xs) 0;
}
.multi-select-option {
  display: flex;
  align-items: center;
  gap: var(--space-sm);
  padding: var(--space-sm) var(--space-md);
  font-size: 0.85rem;
  color: var(--gray-800);
  cursor: pointer;
  transition: background 0.1s;
  white-space: nowrap;
}
.multi-select-option:hover { background: var(--kurly-purple-pale, #f3e8ff); }
.multi-select-option input[type="checkbox"] {
  accent-color: var(--kurly-purple);
  pointer-events: none;
  width: 15px;
  height: 15px;
}

/* ---- Summary Bar ---- */
.summary-bar {
  padding: var(--space-md) var(--space-2xl);
  background: #fff;
  margin: var(--space-lg) var(--space-2xl) 0;
  border-radius: var(--radius-lg);
  box-shadow: var(--shadow-sm);
  display: flex;
  align-items: center;
  gap: var(--space-lg);
}

.summary-info {
  font-size: 0.85rem;
  color: var(--gray-600);
  white-space: nowrap;
}
.summary-info strong { color: var(--gray-900); }

.progress-track {
  flex: 1;
  height: 8px;
  background: var(--gray-200);
  border-radius: 4px;
  overflow: hidden;
}

.progress-fill {
  height: 100%;
  background: linear-gradient(90deg, var(--kurly-purple), var(--kurly-purple-light));
  border-radius: 4px;
  transition: width 0.6s cubic-bezier(0.4, 0, 0.2, 1);
}

.percent-tag {
  font-size: 0.85rem;
  font-weight: 700;
  color: var(--kurly-purple);
  white-space: nowrap;
}

/* ---- Table ---- */
.content-body {
  flex: 1;
  overflow-y: auto;
  padding: var(--space-lg) var(--space-2xl) var(--space-2xl);
}

.jira-table {
  width: 100%;
  border-collapse: separate;
  border-spacing: 0;
  background: #fff;
  border-radius: var(--radius-lg);
  overflow: hidden;
  box-shadow: var(--shadow-md);
}

.jira-table th {
  background: var(--gray-50);
  color: var(--gray-600);
  font-weight: 600;
  text-transform: uppercase;
  font-size: 0.7rem;
  letter-spacing: 0.5px;
  padding: var(--space-md) var(--space-md);
  border-bottom: 1px solid var(--gray-200);
  text-align: left;
}

.jira-table td {
  padding: var(--space-md);
  border-bottom: 1px solid var(--gray-100);
  font-size: 0.85rem;
  vertical-align: middle;
}

.jira-table tbody tr:last-child td {
  border-bottom: none;
}

.clickable-row {
  cursor: pointer;
  transition: background-color 0.1s ease;
}
.clickable-row:hover {
  background-color: var(--kurly-purple-pale);
}

.td-key {
  color: var(--kurly-purple);
  font-weight: 600;
  font-size: 0.82rem;
}

.td-team {
  white-space: nowrap;
}

.team-tag {
  display: inline-block;
  padding: 3px 10px;
  background: var(--kurly-purple-pale);
  color: var(--kurly-purple);
  border-radius: 12px;
  font-size: 0.78rem;
  font-weight: 600;
}

.td-summary {
  max-width: 350px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  color: var(--gray-800);
}

.td-actions {
  white-space: nowrap;
}

.td-user {
  white-space: nowrap;
}

.user-pill {
  display: inline-block;
  padding: 3px 10px;
  background: var(--gray-100);
  border-radius: 12px;
  font-size: 0.78rem;
  color: var(--gray-700);
}

/* ---- Status Badges ---- */
.badge, .badge-small {
  display: inline-block;
  padding: 3px 10px;
  border-radius: var(--radius-sm);
  font-size: 0.75rem;
  font-weight: 600;
  white-space: nowrap;
}
.badge-small {
  padding: 2px 8px;
  font-size: 0.7rem;
}

.status-todo {
  background: var(--gray-200);
  color: var(--gray-600);
}
.status-inprogress {
  background: var(--blue-50);
  color: var(--blue-600);
}
.status-done {
  background: var(--green-50);
  color: var(--green-700);
}

.empty-state {
  padding-top: 100px;
  text-align: center;
  color: var(--gray-500);
}

/* ---- Modal (shared) ---- */
.modal-overlay {
  position: fixed;
  top: 0; left: 0; right: 0; bottom: 0;
  background: rgba(0,0,0,0.45);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 1000;
  backdrop-filter: blur(2px);
}

.modal-content {
  background: #fff;
  width: 700px;
  max-height: 85vh;
  border-radius: var(--radius-xl);
  display: flex;
  flex-direction: column;
  box-shadow: var(--shadow-xl);
  overflow: hidden;
}

.modal-header {
  padding: var(--space-lg) var(--space-xl);
  background: var(--kurly-purple);
  color: #fff;
  display: flex;
  justify-content: space-between;
  align-items: center;
  flex-shrink: 0;
}
.modal-header h3 {
  margin: 0;
  font-size: 1rem;
  font-weight: 600;
}

.close-btn {
  background: none;
  border: none;
  color: rgba(255,255,255,0.8);
  font-size: 1.5rem;
  cursor: pointer;
  padding: 0;
  line-height: 1;
  transition: color 0.15s;
}
.close-btn:hover { color: #fff; }

.modal-search {
  padding: var(--space-md) var(--space-xl);
  background: #fff;
  border-bottom: 1px solid var(--gray-200);
  flex-shrink: 0;
}

.search-input {
  width: 100%;
  padding: var(--space-sm) var(--space-md);
  border: 1px solid var(--gray-300);
  border-radius: var(--radius-md);
  font-size: 0.85rem;
  box-sizing: border-box;
  transition: border-color 0.15s;
}
.search-input:focus {
  outline: none;
  border-color: var(--kurly-purple);
  box-shadow: 0 0 0 3px var(--kurly-purple-pale);
}

.modal-body {
  flex: 1;
  overflow-y: auto;
  padding: var(--space-lg) var(--space-xl);
  background: var(--gray-50);
  scrollbar-width: thin;
  scrollbar-color: var(--gray-400) transparent;
}
.modal-body::-webkit-scrollbar { width: 6px; }
.modal-body::-webkit-scrollbar-thumb { background-color: var(--gray-400); border-radius: 3px; }
.modal-body::-webkit-scrollbar-track { background: transparent; }

.loading-spinner {
  text-align: center;
  padding: var(--space-2xl);
  color: var(--gray-500);
  font-size: 0.9rem;
}

/* ---- Comments ---- */
.comment-item {
  padding: var(--space-md);
  margin-bottom: var(--space-sm);
  background: #fff;
  border-radius: var(--radius-md);
  border: 1px solid var(--gray-200);
}
.comment-item:last-child { margin-bottom: 0; }

.comment-meta {
  display: flex;
  align-items: center;
  gap: var(--space-sm);
  margin-bottom: var(--space-xs);
  flex-wrap: wrap;
}

.comment-author {
  font-weight: 600;
  color: var(--kurly-purple);
  font-size: 0.85rem;
}

.comment-issue {
  background: var(--kurly-purple-pale);
  color: var(--kurly-purple);
  padding: 2px 8px;
  border-radius: var(--radius-sm);
  font-size: 0.75rem;
  font-weight: 600;
}

.comment-date {
  font-size: 0.75rem;
  color: var(--gray-500);
  margin-left: auto;
}

.comment-text {
  margin-top: var(--space-xs);
  line-height: 1.6;
  color: var(--gray-700);
  font-size: 0.85rem;
}

.clickable-ticket {
  background: var(--kurly-purple-pale);
  color: var(--kurly-purple);
  padding: 2px 8px;
  border-radius: var(--radius-sm);
  font-size: 0.75rem;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.15s ease;
}
.clickable-ticket:hover {
  background: var(--kurly-purple);
  color: #fff;
}

.highlight {
  background: #fff59d;
  padding: 0 2px;
  border-radius: 2px;
}

/* ---- Tree Modal ---- */
.tree-modal-overlay .modal-content {
  width: 1000px;
}

.header-title-group {
  display: flex;
  align-items: center;
  gap: var(--space-xl);
}

.filter-toggle {
  font-size: 0.82rem;
  font-weight: 500;
  cursor: pointer;
  display: flex;
  align-items: center;
  gap: var(--space-xs);
  color: rgba(255,255,255,0.8);
}
.filter-toggle input { cursor: pointer; }

.tree-container {
  display: flex;
  flex-direction: column;
  gap: var(--space-sm);
}

.tree-group {
  margin-bottom: var(--space-sm);
}

.tree-node {
  padding: var(--space-md);
  border-radius: var(--radius-md);
  cursor: pointer;
  display: flex;
  align-items: center;
  gap: var(--space-sm);
  transition: background-color 0.1s ease;
}

.parent-node {
  background: #fff;
  border: 1px solid var(--gray-200);
  user-select: none;
}
.parent-node:hover {
  background: var(--kurly-purple-pale);
  border-color: var(--kurly-purple-pale);
}

.fold-icon {
  width: 18px;
  font-size: 0.65rem;
  color: var(--gray-500);
  flex-shrink: 0;
}

.node-key {
  font-weight: 600;
  color: var(--kurly-purple);
  font-size: 0.85rem;
  flex-shrink: 0;
}

.node-summary {
  flex: 1;
  font-size: 0.85rem;
  color: var(--gray-800);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.node-meta {
  display: flex;
  align-items: center;
  gap: var(--space-md);
  margin-left: auto;
  flex-shrink: 0;
}

.meta-item {
  font-size: 0.72rem;
  color: var(--gray-500);
  white-space: nowrap;
}

.tree-branch {
  padding-left: var(--space-xl);
  border-left: 2px solid var(--gray-200);
  margin-left: var(--space-xl);
  margin-top: var(--space-xs);
}

.child-node {
  position: relative;
  background: #fff;
  border: 1px solid var(--gray-100);
  margin-bottom: var(--space-xs);
}
.child-node:hover {
  background: var(--kurly-purple-pale);
}

.connector-line {
  display: none;
}

.node-key-sub {
  font-weight: 600;
  color: var(--blue-600);
  font-size: 0.8rem;
  flex-shrink: 0;
}

.node-summary-sub {
  flex: 1;
  font-size: 0.82rem;
  color: var(--gray-700);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.assignee-tag {
  font-size: 0.72rem;
  background: var(--gray-100);
  padding: 2px 8px;
  border-radius: 12px;
  color: var(--gray-700);
}

.empty-child {
  padding: var(--space-md) var(--space-lg);
  font-size: 0.8rem;
  color: var(--gray-400);
  font-style: italic;
}

.node-type {
  font-size: 0.72rem;
  color: var(--gray-500);
  min-width: 50px;
}

/* ---- Setup Modal ---- */
.setup-overlay {
  z-index: 2000;
}
.setup-modal {
  background: #fff;
  width: 480px;
  border-radius: var(--radius-xl);
  overflow: hidden;
  box-shadow: var(--shadow-xl);
}
.setup-body {
  padding: var(--space-xl);
}
.setup-desc {
  margin: 0 0 var(--space-xl);
  font-size: 0.9rem;
  color: var(--gray-600);
  line-height: 1.5;
}
.setup-field {
  margin-bottom: var(--space-lg);
}
.setup-field label {
  display: block;
  font-size: 0.82rem;
  font-weight: 600;
  color: var(--gray-800);
  margin-bottom: 6px;
}
.setup-input {
  width: 100%;
  padding: 10px var(--space-md);
  border: 1px solid var(--gray-300);
  border-radius: var(--radius-md);
  font-size: 0.9rem;
  box-sizing: border-box;
  transition: border-color 0.15s, box-shadow 0.15s;
}
.setup-input:focus {
  outline: none;
  border-color: var(--kurly-purple);
  box-shadow: 0 0 0 3px var(--kurly-purple-pale);
}
.setup-guide {
  background: var(--kurly-purple-bg);
  border: 1px solid var(--kurly-purple-pale);
  border-radius: var(--radius-md);
  padding: var(--space-lg);
  margin-bottom: var(--space-xl);
  font-size: 0.82rem;
  color: var(--gray-700);
  line-height: 1.5;
}
.setup-guide p { margin: 0 0 var(--space-sm); font-weight: 600; }
.setup-guide ol { margin: 0; padding-left: 18px; }
.setup-guide li { margin-bottom: var(--space-xs); }
.setup-guide a { color: var(--kurly-purple); font-weight: 600; text-decoration: none; }
.setup-guide a:hover { text-decoration: underline; }

.btn-setup-save {
  width: 100%;
  padding: var(--space-md);
  background: var(--kurly-purple);
  color: #fff;
  border: none;
  border-radius: var(--radius-md);
  font-size: 0.95rem;
  font-weight: 700;
  cursor: pointer;
  transition: background 0.15s;
}
.btn-setup-save:hover { background: var(--kurly-purple-light); }
.btn-setup-save:disabled { background: var(--gray-300); cursor: not-allowed; }

/* ---- Setting Tab ---- */
.setting-body {
  flex: 1;
  padding: var(--space-lg) var(--space-2xl) var(--space-2xl);
  overflow-y: auto;
}
.setting-card {
  background: #fff;
  border-radius: var(--radius-lg);
  padding: var(--space-xl);
  margin-bottom: var(--space-lg);
  box-shadow: var(--shadow-sm);
}
.setting-section-title {
  margin: 0 0 var(--space-lg);
  font-size: 0.95rem;
  font-weight: 700;
  color: var(--kurly-purple);
  border-bottom: 1px solid var(--gray-200);
  padding-bottom: var(--space-md);
}
.setting-row {
  display: flex;
  align-items: center;
  padding: var(--space-md) 0;
  border-bottom: 1px solid var(--gray-100);
}
.setting-row:last-child { border-bottom: none; }
.setting-label {
  width: 100px;
  font-size: 0.82rem;
  font-weight: 600;
  color: var(--gray-600);
  flex-shrink: 0;
}
.setting-value {
  font-size: 0.85rem;
  color: var(--gray-800);
}
.setting-token {
  font-family: 'SF Mono', 'Menlo', monospace;
  font-size: 0.78rem;
  color: var(--gray-500);
}
.setting-actions {
  margin-top: var(--space-lg);
  padding-top: var(--space-lg);
  border-top: 1px solid var(--gray-200);
}
.btn-reset {
  padding: var(--space-sm) var(--space-lg);
  background: var(--red-500);
  color: #fff;
  border: none;
  border-radius: var(--radius-md);
  font-size: 0.82rem;
  font-weight: 600;
  cursor: pointer;
  transition: background 0.15s;
}
.btn-reset:hover { background: var(--red-600); }

/* ---- Log Tab ---- */
.log-container { }
.log-body {
  flex: 1;
  padding: var(--space-lg) var(--space-2xl) var(--space-2xl);
  overflow: hidden;
  display: flex;
}
.log-textarea {
  flex: 1;
  font-family: 'SF Mono', 'Menlo', 'Monaco', 'Fira Code', monospace;
  font-size: 0.82rem;
  line-height: 1.65;
  padding: var(--space-lg);
  border: none;
  border-radius: var(--radius-lg);
  background: var(--gray-900);
  color: #d4d4d4;
  resize: none;
  white-space: pre;
  overflow: auto;
  box-shadow: var(--shadow-md);
}
.log-textarea:focus {
  outline: 2px solid var(--kurly-purple);
  outline-offset: -2px;
}

/* ---- Scrollbar (global) ---- */
.content-body::-webkit-scrollbar,
.setting-body::-webkit-scrollbar {
  width: 6px;
}
.content-body::-webkit-scrollbar-thumb,
.setting-body::-webkit-scrollbar-thumb {
  background-color: var(--gray-300);
  border-radius: 3px;
}
.content-body::-webkit-scrollbar-track,
.setting-body::-webkit-scrollbar-track {
  background: transparent;
}
</style>