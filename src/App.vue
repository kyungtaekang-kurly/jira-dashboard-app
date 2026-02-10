<script setup lang="ts">
import { ref, computed, onMounted } from 'vue';
import { fetch } from '@tauri-apps/plugin-http';
import { open } from '@tauri-apps/plugin-shell';
import { checkForUpdates } from './update-checker.js';

// --- 1. 상태 관리 ---
const currentTab = ref<'epic' | 'idea'>('idea');
const tickets = ref<any[]>([]);
const epicInfo = ref<any>(null);
const isLoading = ref(false);

// 필터 상태 (함수 밖으로 이동)
const selectedStatus = ref<string>('all');
const selectedTeam = ref<string>('전체 조직');

// 모달 상태
const isCommentModalOpen = ref(false);
const allComments = ref<any[]>([]);
const isCommentsLoading = ref(false);
const selectedTicketKey = ref('');

// --- 2. 설정 정보 ---
const JIRA_DOMAIN = 'kurly0521.atlassian.net';
const EMAIL = 'kyungtae.kang@kurlycorp.com';
const API_TOKEN = 'ATATT3xFfGF0uau1DjgfL7syTIzmBWZ_TnyMHRHG_MUw1qaEPLTOqL_1Wl7tWCngv4JrP2-Nsa6WpK2YRS3gZAXqFamzC_jqS-CqG1WordzHRg85zBz7zb0sPXy5JTbcwFNO87bCSmkHeq2mEX25cCHSaYTvEyYYa1r2scBe7DXJ13E04lCSDTE=8D988A7E';
const EPIC_KEY = 'FPP-72';
const authHeader = btoa(`${EMAIL}:${API_TOKEN}`);
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
    const statusMatch = selectedStatus.value === 'all' || t.fields?.status?.name === selectedStatus.value;
    // 조직 매칭
    const orgVal = t.fields?.[ORG_FIELD];
    const teamName = Array.isArray(orgVal) ? orgVal[0]?.value : (orgVal?.value || orgVal);
    const teamMatch = selectedTeam.value === '전체 조직' || teamName === selectedTeam.value;

    return statusMatch && teamMatch;
  });
});

// --- 4. 데이터 로드 로직 ---
const loadData = async () => {
  isLoading.value = true;
  tickets.value = [];

  try {
    const targetTeams = ["재고", "입고", "발주", "상품"];
    let allIssues: any[] = [];
    const fields = `summary,status,issuetype,assignee,priority,${ORG_FIELD},${ASSIGNEE_FIELD}`;

    for (const teamName of targetTeams) {
      // 1. JQL 문법 수정: cf[ID] 대신 customfield_ID 사용
      // 2. 검색 연산자: '~'(포함)은 인덱싱 지연이 있을 수 있으니 'IN' 또는 '=' 시도
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
          'Authorization': `Basic ${authHeader}`,
          'Accept': 'application/json'
        }
      });

      if (response.ok) {
        const data: any = await response.json();
        const issues = data.issues || [];
        console.log(`[확인] ${teamName} 조직 결과: ${issues.length}건`);
        allIssues = [...allIssues, ...issues];
      }
    }

    // 만약 조직별 데이터가 하나도 없다면, 안전장치로 전체 프로젝트 100개 로드
    if (allIssues.length === 0) {
      console.warn("조직별 데이터를 찾지 못해 전체 데이터를 로드합니다.");
      const fallbackUrl = `https://${JIRA_DOMAIN}/rest/api/3/search/jql?jql=project=FPP ORDER BY created DESC&maxResults=300&fields=${fields}`;
      const res = await fetch(fallbackUrl, {
        method: 'GET',
        headers: { 'Authorization': `Basic ${authHeader}` }
      });
      if (res.ok) {
        const data: any = await res.json();
        allIssues = data.issues || [];
      }
    }

    // 중복 제거 후 할당
    tickets.value = Array.from(
        new Map(allIssues.map(issue => [issue.key, issue])).values()
    );

    // 에픽 정보 처리 (생략되지 않도록 유지)
    if (currentTab.value === 'epic') {
      const epicRes = await fetch(`https://${JIRA_DOMAIN}/rest/api/3/issue/${EPIC_KEY}`, {
        method: 'GET',
        headers: { 'Authorization': `Basic ${authHeader}` }
      });
      epicInfo.value = await epicRes.json();
    } else {
      epicInfo.value = { fields: { summary: 'Jira Idea Explorer' } };
    }

  } catch (error) {
    console.error('데이터 로드 중 치명적 오류:', error);
  } finally {
    isLoading.value = false;
  }
};

const openJiraIssue = async (key: string) => {
  const url = `https://${JIRA_DOMAIN}/browse/${key}`;
  await open(url);
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
        headers: { 'Authorization': `Basic ${authHeader}`, 'Accept': 'application/json' }
      });

      if (searchRes.ok) {
        const searchData: any = await searchRes.json();
        const subKeys = (searchData.issues || []).map((i: any) => i.key);
        issueKeys = [...issueKeys, ...subKeys];
      }
    } catch (e) {
      console.warn("하위 태스크 검색 실패 (무시하고 진행):", e);
    }

    // 2. 댓글 병렬 로드
    const commentPromises = issueKeys.map(async (key) => {
      try {
        const res = await fetch(`https://${JIRA_DOMAIN}/rest/api/3/issue/${key}/comment`, {
          method: 'GET',
          headers: { 'Authorization': `Basic ${authHeader}` }
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
    console.error('댓글 로드 중 치명적 오류:', error);
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
      headers: { 'Authorization': `Basic ${authHeader}` }
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
    console.error("이슈 링크 로드 실패:", e);
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
      headers: { 'Authorization': `Basic ${authHeader}`, 'Accept': 'application/json' }
    });

    if (searchRes.ok) {
      const searchData: any = await searchRes.json();
      // COOP-4712를 포함한 모든 하위 티켓 키 수집
      (searchData.issues || []).forEach((i: any) => allRelatedKeys.add(i.key));
    }

    // 4. 수집된 모든 티켓(FPP-72, COOP-4331, COOP-4712 등)의 댓글 병렬 로드
    const finalKeys = Array.from(allRelatedKeys);
    console.log("댓글 수집 대상(COOP-4712 포함 여부 확인):", finalKeys);

    const results = await Promise.all(finalKeys.map(async (key) => {
      const res = await fetch(`https://${JIRA_DOMAIN}/rest/api/3/issue/${key}/comment`, {
        method: 'GET',
        headers: { 'Authorization': `Basic ${authHeader}` }
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
    console.error('하위 댓글 통합 로드 실패:', error);
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
  console.log("트리 로드 시작: ", rootTicket.key);
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
      headers: { 'Authorization': `Basic ${authHeader}`, 'Accept': 'application/json' }
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
    console.error('트리 로드 실패:', error);
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
  loadData();
  checkForUpdates();
});
</script>

<template>
  <div class="app-layout">
    <aside class="sidebar">
      <div class="sidebar-brand">컬리지라(Kurly Jira)</div>
      <nav class="nav-menu">
        <div class="nav-item" :class="{ active: currentTab === 'epic' }" @click="switchTab('epic')">📋 Epic Explorer</div>
        <div class="nav-item" :class="{ active: currentTab === 'idea' }" @click="switchTab('idea')">💡 Idea Explorer</div>
      </nav>
    </aside>

    <main class="main-container">
      <header class="main-header">
        <div class="header-left">
          <h2 class="title-text">{{ epicInfo?.fields?.summary || 'Loading...' }}</h2>
        </div>
        <div class="header-actions">
          <select v-model="selectedTeam" class="status-filter">
            <option v-for="team in availableTeams" :key="team" :value="team">{{ team }}</option>
          </select>
          <select v-model="selectedStatus" class="status-filter">
            <option value="all">모든 상태 ({{ tickets.length }})</option>
            <option v-for="status in availableStatuses.filter(s => s !== 'all')" :key="status" :value="status">{{ status }}</option>
          </select>
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
            <th style="width: 140px;">수행조직</th> <th>SUMMARY</th>
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
            <td class="td-summary">{{ ticket.fields?.summary }}</td>
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
  </div>

  <div v-if="isCommentModalOpen" class="modal-overlay" @click="isCommentModalOpen = false">
    <div class="modal-content" @click.stop>
      <header class="modal-header">
        <h3>최신 댓글 통합 보기</h3>
        <button @click="isCommentModalOpen = false" class="close-btn">&times;</button>
      </header>

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

</template>

<style>
:root {
  --sidebar-width: 240px;
  /* 컬리 공식 브랜드 컬러 */
  --kurly-purple: #5f0080;
  --kurly-purple-light: #8900b3;
  --kurly-purple-bg: #f7f0fa;
  --primary-text: #333333;
  --white: #ffffff;
}
body {
  margin: 0;
  font-family: 'Pretendard', -apple-system, BlinkMacSystemFont, system-ui, Roboto, sans-serif;
  overflow: hidden;
  background-color: var(--white);
  color: var(--primary-text);
}

.app-layout {
  display: flex;
  width: 100vw;
  height: 100vh;
}

/* 사이드바: 컬리 보라색 적용 */
.sidebar {
  width: var(--sidebar-width);
  background: var(--kurly-purple);
  color: var(--white);
  display: flex;
  flex-direction: column;
  flex-shrink: 0;
  box-shadow: 2px 0 10px rgba(0, 0, 0, 0.1);
}
.sidebar-brand {
  padding: 30px 24px;
  font-size: 1.2rem;
  font-weight: 700;
  letter-spacing: -0.5px;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
}
.nav-menu {
  padding: 20px 0;
}
.nav-item {
  padding: 14px 24px;
  margin: 4px 12px;
  border-radius: 8px;
  cursor: pointer;
  font-size: 0.95rem;
  transition: all 0.2s ease;
  display: flex;
  align-items: center;
  gap: 10px;
}
nav-item:hover {
  background: rgba(255, 255, 255, 0.1);
}

.nav-item.active {
  background: var(--white);
  color: var(--kurly-purple);
  font-weight: 700;
}

/* 메인 컨텐츠 영역 */
.main-container {
  flex-grow: 1;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  background: var(--kurly-purple-bg); /* 연한 보라색 배경 */
}

main-header {
  padding: 24px 40px;
  background: var(--white);
  display: flex;
  align-items: center;
  justify-content: space-between;
  border-bottom: 1px solid #e2e2e2;
}
.title-text {
  margin: 0;
  font-size: 1.4rem;
  font-weight: 700;
  color: var(--kurly-purple);
}

/* 새로고침 버튼 */
.btn-refresh {
  background: var(--kurly-purple);
  color: var(--white);
  border: none;
  padding: 10px 20px;
  border-radius: 6px;
  cursor: pointer;
  font-weight: 600;
  transition: background 0.2s;
}

.btn-refresh:hover {
  background: var(--kurly-purple-light);
}

.btn-refresh:disabled {
  background: #ccc;
}

/* 요약 바 & 진행률 */
.summary-bar {
  padding: 15px 40px;
  background: var(--white);
  margin: 20px 40px 0;
  border-radius: 12px;
  box-shadow: 0 2px 8px rgba(0,0,0,0.05);
  display: flex;
  align-items: center;
  gap: 20px;
}

.progress-track {
  flex: 1;
  height: 10px;
  background: #eee;
  border-radius: 5px;
  overflow: hidden;
}

.progress-fill {
  height: 100%;
  background: var(--kurly-purple); /* 진행바도 컬리 퍼플 */
  transition: width 0.6s cubic-bezier(0.4, 0, 0.2, 1);
}

/* 테이블 디자인 */
.content-body {
  flex: 1;
  overflow-y: auto;
  padding: 20px 40px 40px;
}

.jira-table {
  width: 100%;
  border-collapse: separate;
  border-spacing: 0;
  background: var(--white);
  border-radius: 12px;
  overflow: hidden;
  box-shadow: 0 4px 12px rgba(0,0,0,0.05);
}

.jira-table th {
  background: #fdfdfd;
  color: #666;
  font-weight: 400;
  text-transform: uppercase;
  font-size: 0.75rem;
  padding: 10px;
  border-bottom: 1px solid #eee;
  text-align: left;
}

.jira-table td {
  padding: 10px;
  border-bottom: 1px solid #f9f9f9;
  font-size: 0.9rem;
}

.td-summary {
  max-width: 400px;         /* 적절한 최대 너비를 설정하세요 */
  white-space: nowrap;      /* 줄바꿈 금지 */
  overflow: hidden;         /* 넘치는 부분 숨김 */
  text-overflow: ellipsis;  /* 말줄임표(...) 표시 */
}

.clickable-row:hover {
  background-color: #fcf8ff; /* 마우스 오버 시 아주 연한 보라색 */
}

/* 상태 배지 */
.badge {
  padding: 4px 10px;
  border-radius: 4px;
  font-size: 0.8rem;
  font-weight: 600;
}

.status-todo { background: #eee; color: #666; }
.status-inprogress { background: #e8f0fe; color: #1a73e8; }
.status-done { background: #e3fcef; color: #006644; }

.td-key {
  color: var(--kurly-purple);
  font-weight: 400;
}
.btn-refresh { color: white; border: none; padding: 8px 16px; border-radius: 4px; cursor: pointer; font-weight: 600; }
.user-pill { display: inline-block; padding: 2px 8px; background: #f4f5f7; border-radius: 12px; font-size: 0.8rem; }
.empty-state { padding-top: 100px; text-align: center; color: #6b778c; }

/* 모달 스타일 */

.modal-overlay {
  position: fixed; top: 0; left: 0; width: 100%; height: 100%;
  background: rgba(0,0,0,0.5); display: flex; align-items: center; justify-content: center; z-index: 1000;
}
.modal-content {
  background: white; width: 600px; max-height: 80vh; border-radius: 12px; overflow: hidden;
  display: flex; flex-direction: column;
}
.modal-header {
  padding: 16px; background: var(--kurly-purple); color: white;
  display: flex; justify-content: space-between; align-items: center;
}
.comment-item {
  padding: 12px; border-bottom: 1px solid #eee;
}
.modal-content {
  background: white;
  width: 700px;
  max-height: 85vh; /* 화면 높이의 85%까지만 커짐 */
  border-radius: 16px;
  display: flex;
  flex-direction: column; /* 헤더와 바디를 세로로 배치 */
  box-shadow: 0 10px 30px rgba(0,0,0,0.3);
  overflow: hidden; /* 내부 요소가 모달 테두리를 넘지 않게 함 */
}

/* 2. 댓글이 담기는 바디 영역: 이곳에 스크롤 생성 */
.modal-body {
  flex: 1; /* 남은 공간을 모두 차지 */
  overflow-y: auto; /* 내용이 많아지면 세로 스크롤 생성 */
  padding: 20px;
  background: #f9f9f9;

  /* 스크롤바 디자인 (선택 사항: 컬리 보라색 느낌) */
  scrollbar-width: thin;
  scrollbar-color: var(--kurly-purple) #f1f1f1;
}

/* 크롬, 사파리용 스크롤바 커스텀 */
.modal-body::-webkit-scrollbar {
  width: 6px;
}
.modal-body::-webkit-scrollbar-thumb {
  background-color: var(--kurly-purple);
  border-radius: 10px;
}
.modal-body::-webkit-scrollbar-track {
  background: #f1f1f1;
}
.comment-author { font-weight: bold; color: var(--kurly-purple); margin-right: 8px; }
.comment-issue { background: #f0f0f0; padding: 2px 6px; border-radius: 4px; font-size: 0.8rem; margin-right: 8px; }
.comment-text { margin-top: 4px; line-height: 1.5; color: #444; }

.btn-tree {
  background: #666;
  color: white;
  border: none;
  padding: 6px 12px;
  border-radius: 4px;
  cursor: pointer;
  font-size: 0.85rem;
}
.btn-tree:hover { background: #444; }

.tree-node {
  padding: 10px;
  border-radius: 8px;
  cursor: pointer;
  display: flex;
  align-items: center;
}
.tree-node:hover { background-color: #f7f0fa; }
.parent-node {
  background: #fdfbff;
  border: 1px solid #efe4f5;
  margin-top: 10px;
}
.node-type {
  font-size: 0.75rem;
  color: #888;
  min-width: 60px;
}

.header-title-group { display: flex; align-items: center; gap: 20px; }
.filter-toggle { font-size: 0.85rem; font-weight: normal; cursor: pointer; display: flex; align-items: center; gap: 5px; }

.fold-icon { width: 20px; font-size: 0.7rem; color: #888; transition: transform 0.2s; }
.node-meta { display: flex; align-items: center; gap: 12px; margin-left: auto; }
.meta-item { font-size: 0.75rem; color: #888; white-space: nowrap; }

.parent-node { cursor: pointer; user-select: none; }
.parent-node:hover { background: #f3ebf7; }

.tree-branch { transition: all 0.3s ease; }
.empty-child { padding: 10px 40px; font-size: 0.8rem; color: #bbb; font-style: italic; }

.assignee-tag { font-size: 0.75rem; background: #eee; padding: 2px 8px; border-radius: 12px; }

clickable-ticket {
  background: var(--kurly-purple-bg); /* 연한 보라색 배경 */
  color: var(--kurly-purple); /* 컬리 보라색 텍스트 */
  padding: 2px 8px;
  border-radius: 4px;
  font-size: 0.8rem;
  font-weight: 600;
  cursor: pointer; /* 마우스 커서 변경 */
  transition: all 0.2s ease;
  border: 1px solid transparent;
}

.clickable-ticket:hover {
  background: var(--kurly-purple); /* 호버 시 진한 보라색 */
  color: white; /* 호버 시 흰색 글씨 */
  text-decoration: underline;
}
</style>